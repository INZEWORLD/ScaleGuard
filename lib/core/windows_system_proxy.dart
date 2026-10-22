import 'dart:convert';
import 'dart:io';

import '../services/log_service.dart';

/// Reads and writes the per-user WinINet proxy configuration.
///
/// Windows desktop VPN clients have two ways to capture traffic: a virtual
/// adapter (TUN, needs elevation) or the WinINet proxy setting, which every
/// browser and most desktop applications honour. This class implements the
/// second one, including the `InternetSetOption` notifications without which
/// the registry change is not picked up until the next sign-in.
///
/// The previous configuration is always captured first so it can be restored
/// exactly, even if the application is killed while the tunnel is up.
class WindowsSystemProxy {
  WindowsSystemProxy();

  static const String _key =
      r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  Map<String, dynamic>? _previous;
  bool _applied = false;

  /// File the captured settings are mirrored to.
  ///
  /// The copy in memory covers every orderly shutdown. This one covers the
  /// disorderly ones — the client is a process the user can end in the task
  /// manager, log off or crash — after which the machine would otherwise be left
  /// pointing at a port that no longer listens. That state is not merely
  /// broken, it is *sticky*: the next launch would capture it as "the
  /// configuration to restore" and put it back after every session.
  String? backupFilePath;

  bool get isSupported => Platform.isWindows;
  bool get isApplied => _applied;

  /// Captures the current settings so [restore] can put them back.
  Future<Map<String, dynamic>?> capture() async {
    if (!isSupported) return null;
    final result = await _runPowerShell('''
\$ErrorActionPreference = 'Stop'
\$key = '$_key'
\$props = Get-ItemProperty -Path \$key
\$out = [ordered]@{
  ProxyEnable   = if (\$null -ne \$props.ProxyEnable) { [int]\$props.ProxyEnable } else { 0 }
  ProxyServer   = if (\$null -ne \$props.ProxyServer) { [string]\$props.ProxyServer } else { '' }
  ProxyOverride = if (\$null -ne \$props.ProxyOverride) { [string]\$props.ProxyOverride } else { '' }
  AutoConfigURL = if (\$null -ne \$props.AutoConfigURL) { [string]\$props.AutoConfigURL } else { '' }
}
\$out | ConvertTo-Json -Compress
''');
    if (result == null) return null;
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map) {
        _previous = decoded.map((key, value) => MapEntry(key.toString(), value));
        await _writeBackup(_previous!);
        return _previous;
      }
    } catch (_) {}
    return null;
  }

  /// Points WinINet at the local core and notifies running applications.
  ///
  /// [bypass] is applied to `ProxyOverride`: local addresses must stay direct
  /// or the application loses its own API and LAN access.
  Future<void> apply({
    required int port,
    String bypass = 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;'
        '172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;'
        '172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>',
  }) async {
    if (!isSupported) return;
    if (_previous == null) await capture();

    // PAC must be cleared before enabling the static proxy: on Windows a PAC
    // script takes precedence and would silently ignore ProxyServer.
    final script = '''
\$ErrorActionPreference = 'Stop'
\$key = '$_key'
Set-ItemProperty -Path \$key -Name ProxyEnable -Value 1 -Type DWord
Set-ItemProperty -Path \$key -Name ProxyServer -Value '127.0.0.1:$port' -Type String
Set-ItemProperty -Path \$key -Name ProxyOverride -Value '$bypass' -Type String
Remove-ItemProperty -Path \$key -Name AutoConfigURL -ErrorAction SilentlyContinue
${_nativeNotifyBlock()}
'ok'
''';
    final result = await _runPowerShell(script);
    _applied = result != null;
    if (!_applied) {
      throw StateError('Не удалось включить системный прокси Windows');
    }
  }

  /// Restores the configuration captured by [capture].
  Future<void> restore() async {
    if (!isSupported) return;
    final previous = _previous;
    _applied = false;
    if (previous == null) {
      // Nothing captured: fall back to switching the proxy off so the machine
      // is never left pointing at a port that no longer exists.
      await _runPowerShell('''
\$ErrorActionPreference = 'Stop'
Set-ItemProperty -Path '$_key' -Name ProxyEnable -Value 0 -Type DWord
${_nativeNotifyBlock()}
'ok'
''');
      await _deleteBackup();
      return;
    }

    await _runPowerShell(_restoreScript(previous));
    _previous = null;
    await _deleteBackup();
  }

  /// Puts the machine back the way it was after the client was killed before it
  /// could restore it itself.
  ///
  /// Called on every launch, before anything else touches the proxy. A machine
  /// left pointing at a core that no longer runs has no working internet at all,
  /// and the user has no obvious way to find the setting that caused it.
  ///
  /// Returns `true` when a stale configuration was found and undone.
  Future<bool> recoverFromBackup() async {
    if (!isSupported) return false;
    final path = backupFilePath;
    if (path == null) return false;
    final file = File(path);
    if (!file.existsSync()) return false;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('unexpected proxy backup');
      }
      final previous =
          decoded.map((key, value) => MapEntry(key.toString(), value));
      final result = await _runPowerShell(_restoreScript(previous));
      await _deleteBackup();
      if (result == null) return false;
      LogService.instance
          .log('engine', 'recovered the system proxy from an unclean exit');
      return true;
    } catch (error) {
      // A damaged backup must not block the launch, and leaving it in place
      // would make every future start fail the same way.
      LogService.instance.log('engine', 'proxy backup unusable: $error');
      await _deleteBackup();
      return false;
    }
  }

  String _restoreScript(Map<String, dynamic> previous) {
    final enable = (previous['ProxyEnable'] as num?)?.toInt() ?? 0;
    final server = _psQuote(previous['ProxyServer']?.toString() ?? '');
    final override = _psQuote(previous['ProxyOverride']?.toString() ?? '');
    final autoConfig = previous['AutoConfigURL']?.toString() ?? '';
    return '''
\$ErrorActionPreference = 'Stop'
\$key = '$_key'
Set-ItemProperty -Path \$key -Name ProxyEnable -Value $enable -Type DWord
if ('$server' -ne '') { Set-ItemProperty -Path \$key -Name ProxyServer -Value '$server' -Type String } else { Remove-ItemProperty -Path \$key -Name ProxyServer -ErrorAction SilentlyContinue }
if ('$override' -ne '') { Set-ItemProperty -Path \$key -Name ProxyOverride -Value '$override' -Type String } else { Remove-ItemProperty -Path \$key -Name ProxyOverride -ErrorAction SilentlyContinue }
${autoConfig.isEmpty ? "Remove-ItemProperty -Path \$key -Name AutoConfigURL -ErrorAction SilentlyContinue" : "Set-ItemProperty -Path \$key -Name AutoConfigURL -Value '$autoConfig' -Type String"}
${_nativeNotifyBlock()}
'ok'
''';
  }

  Future<void> _writeBackup(Map<String, dynamic> state) async {
    final path = backupFilePath;
    if (path == null) return;
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(state), flush: true);
    } catch (error) {
      // Losing the backup only removes the recovery from a forced exit; it must
      // never stop the tunnel from being applied.
      LogService.instance.log('engine', 'cannot write the proxy backup: $error');
    }
  }

  Future<void> _deleteBackup() async {
    final path = backupFilePath;
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  /// Reads back `ProxyEnable`/`ProxyServer`, which is how the UI detects that
  /// something else (another VPN client, a browser extension) changed them.
  Future<({bool enabled, String server})> readState() async {
    if (!isSupported) return (enabled: false, server: '');
    final result = await _runPowerShell('''
\$props = Get-ItemProperty -Path '$_key' -ErrorAction SilentlyContinue
\$enable = if (\$null -ne \$props.ProxyEnable) { [int]\$props.ProxyEnable } else { 0 }
\$server = if (\$null -ne \$props.ProxyServer) { [string]\$props.ProxyServer } else { '' }
"\$enable|\$server"
''');
    if (result == null) return (enabled: false, server: '');
    final parts = result.split('|');
    return (
      enabled: parts.isNotEmpty && parts.first.trim() == '1',
      server: parts.length > 1 ? parts[1].trim() : '',
    );
  }

  /// P/Invoke helper: WinINet only re-reads its configuration after these two
  /// notifications from the process that changed it.
  String _nativeNotifyBlock() => r'''
if (-not ('ScaleGuard.WinInet' -as [type])) {
  Add-Type -Namespace ScaleGuard -Name WinInet -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern bool InternetSetOption(System.IntPtr hInternet, int dwOption, System.IntPtr lpBuffer, int dwBufferLength);
'@
}
[void][ScaleGuard.WinInet]::InternetSetOption([System.IntPtr]::Zero, 39, [System.IntPtr]::Zero, 0)
[void][ScaleGuard.WinInet]::InternetSetOption([System.IntPtr]::Zero, 37, [System.IntPtr]::Zero, 0)
''';

  String _psQuote(String value) => value.replaceAll("'", "''");

  Future<String?> _runPowerShell(String script) async {
    File? scriptFile;
    try {
      // The script is written to a UTF-8 file with a BOM instead of being
      // passed through `-EncodedCommand`: PowerShell decodes `-EncodedCommand`
      // as UTF-16LE, so ordinary UTF-8 text (which is what Dart produces)
      // arrives corrupted. The BOM makes PowerShell read the file as UTF-8,
      // which matters because a user's existing proxy bypass list and PAC URL
      // may contain non-ASCII characters that must survive the round trip.
      final directory = await Directory.systemTemp.createTemp('scaleguard-proxy');
      scriptFile = File('${directory.path}/proxy.ps1');
      await scriptFile.writeAsBytes([
        0xEF, 0xBB, 0xBF, // UTF-8 BOM
        ...utf8.encode(script),
      ]);

      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptFile.path,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) {
        lastError = 'powershell exit ${result.exitCode}: '
            '${(result.stderr as String).trim()}';
        return null;
      }
      lastError = null;
      return (result.stdout as String).trim();
    } catch (error) {
      lastError = error.toString();
      return null;
    } finally {
      try {
        scriptFile?.parent.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// Diagnostic detail from the most recent failed invocation.
  String? lastError;
}
