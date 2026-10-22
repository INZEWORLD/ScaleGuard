import 'dart:async';
import 'dart:io';

import 'powershell.dart';

/// Whether this machine can actually create a TUN adapter.
enum TunDriverStatus {
  /// The Wintun driver is installed, so an adapter can be created.
  ready,

  /// No Wintun driver. No adapter can be created until it is installed.
  driverMissing,

  /// The question could not be answered (PowerShell unavailable, unusual
  /// environment). Callers treat this as "try anyway".
  unknown,
}

/// Pre-flight check and repair for the Windows TUN driver.
///
/// The tunnel needs a Wintun adapter, and Wintun needs a kernel driver that it
/// installs on first use. When that installation never happened — a fresh
/// machine, a blocked installer, an antivirus that quarantined the driver —
/// the connect dies deep inside the core with a message the user cannot act on.
/// Asking first turns that into a question the client can answer itself and,
/// when the answer is no, into one button that fixes it.
class WindowsTunDriver {
  WindowsTunDriver();

  /// Service the Wintun driver registers. Its presence is the cheapest reliable
  /// answer to "is the driver installed?" — an adapter, by contrast, only exists
  /// after a tunnel has been created at least once.
  static const String serviceName = 'Wintun';

  /// Adapter the application creates for the real tunnel.
  static const String adapterName = 'ScaleGuard';

  /// Adapter used by [install]. Deliberately different from [adapterName] so a
  /// repair can run while a tunnel is already up.
  static const String scratchAdapterName = 'ScaleGuardSetup';

  /// Diagnostic detail from the most recent failed call.
  String? get lastError => _lastError;
  String? _lastError;

  /// Reads the driver state. Cheap enough to run before every connect.
  Future<TunDriverStatus> check() async {
    if (!Platform.isWindows) return TunDriverStatus.unknown;
    final result = await runPowerShell('''
\$service = Get-Service -Name '$serviceName' -ErrorAction SilentlyContinue
if (\$null -ne \$service) { 'driver-present' } else { 'driver-missing' }
''');
    if (!result.ok) {
      _lastError = result.diagnostic;
      return TunDriverStatus.unknown;
    }
    if (result.stdout.contains('driver-present')) {
      _lastError = null;
      return TunDriverStatus.ready;
    }
    if (result.stdout.contains('driver-missing')) {
      _lastError = null;
      return TunDriverStatus.driverMissing;
    }
    _lastError = 'Неожиданный ответ PowerShell: ${result.stdout.trim()}';
    return TunDriverStatus.unknown;
  }

  /// Installs the driver by letting the bundled core create one throwaway
  /// adapter, then removing it again.
  ///
  /// Wintun performs its own installation on the first adapter creation, so
  /// running the core once with TUN enabled *is* the installation: nothing has
  /// to be downloaded and no separate installer has to be shipped with the
  /// application. The scratch profile uses its own ports and adapter name, so a
  /// repair cannot disturb a tunnel that is already running.
  ///
  /// Requires the caller to hold an elevated token — the same requirement the
  /// real tunnel has, and the reason this is only ever offered from a context
  /// where the application already asked for one.
  Future<bool> install({required String corePath}) async {
    if (!Platform.isWindows) return false;
    if (!File(corePath).existsSync()) {
      _lastError = 'Ядро не найдено: $corePath';
      return false;
    }
    if (!await _isElevated()) {
      _lastError = 'Для установки драйвера нужны права администратора';
      return false;
    }
    if (await check() == TunDriverStatus.ready) return true;

    Directory? work;
    Process? process;
    var exited = false;
    try {
      work = await Directory.systemTemp.createTemp('scaleguard-tun');
      final config = File('${work.path}${Platform.pathSeparator}setup.yaml');
      await config.writeAsString(_scratchProfile, flush: true);

      process = await Process.start(
        corePath,
        <String>['-config', config.path, '-d', work.path],
        workingDirectory: work.path,
        runInShell: false,
      );
      unawaited(process.exitCode.then((_) => exited = true));

      // Adapter creation plus the SetupAPI driver installation behind it: a few
      // seconds on a healthy machine, and the loop stops early as soon as the
      // driver registers its service.
      for (var attempt = 0; attempt < 25; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (await check() == TunDriverStatus.ready) {
          _lastError = null;
          return true;
        }
        if (exited) break;
      }
      _lastError = 'Драйвер не установился: ядро завершилось без создания адаптера';
      return false;
    } catch (error) {
      _lastError = error.toString();
      return false;
    } finally {
      try {
        process?.kill(ProcessSignal.sigkill);
      } catch (_) {}
      await _removeScratchAdapter();
      try {
        work?.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  Future<bool> _isElevated() async {
    final result = await runPowerShell('''
\$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
\$principal = New-Object Security.Principal.WindowsPrincipal(\$identity)
if (\$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'yes' } else { 'no' }
''');
    return result.ok && result.stdout.contains('yes');
  }

  /// Removes the adapter [install] created, so a repair never leaves a stray
  /// interface behind.
  Future<void> _removeScratchAdapter() async {
    await runPowerShell('''
Get-NetAdapter -IncludeHidden -Name '$scratchAdapterName' -ErrorAction SilentlyContinue |
  Remove-NetAdapter -Confirm:\$false -ErrorAction SilentlyContinue
''');
  }

  /// Minimal profile whose only job is to make the core create an adapter.
  ///
  /// Ports and the adapter name are distinct from the real tunnel's so this can
  /// run alongside one that is already up.
  static const String _scratchProfile = '''
mixed-port: 17999
allow-lan: false
mode: rule
log-level: warning
ipv6: false
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
tun:
  enable: true
  stack: gvisor
  device: $scratchAdapterName
  auto-route: true
  auto-detect-interface: true
''';
}
