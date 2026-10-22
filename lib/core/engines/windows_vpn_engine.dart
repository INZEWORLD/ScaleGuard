import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../services/log_service.dart';
import '../powershell.dart';
import '../vpn_engine.dart';
import '../windows_elevation.dart';
import '../windows_system_proxy.dart';
import '../windows_tun.dart';
import 'mihomo_engine_base.dart';

/// Windows engine: the bundled mihomo core runs as a child process.
///
/// Keeping the core out of process has three practical benefits on Windows:
/// the core can be restarted or updated without touching the UI, a core crash
/// never takes the window down, and the application itself contains no
/// GPL-3.0 derived code (mihomo is distributed separately under its own
/// licence — see `windows/runner/NOTICE.txt`).
///
/// The engine deliberately imports no Flutter library: it touches only the file
/// system, processes and the PowerShell-based system-proxy helper. That is what
/// lets `tool/e2e_tunnel.dart` drive the real engine with plain `dart run`
/// instead of having to stand up a Flutter binding.
class WindowsVpnEngine extends MihomoEngineBase {
  WindowsVpnEngine({
    WindowsSystemProxy? systemProxy,
    Directory? dataDirectory,
    String? coreExecutable,
  })  : _systemProxy = systemProxy ?? WindowsSystemProxy(),
        _dataDirOverride = dataDirectory,
        _corePathOverride = coreExecutable;

  final WindowsSystemProxy _systemProxy;

  /// Per-user directory for the generated profile, the core's cache and its logs.
  /// Supplied by the application (which resolves it through `path_provider`);
  /// the fallback covers command-line use and tests.
  final Directory? _dataDirOverride;

  /// Explicit path to `mihomo.exe`, used by tests and by installations that
  /// place the core elsewhere.
  final String? _corePathOverride;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final List<String> _coreLog = [];

  /// Adapter the generated profile asks the core to create.
  ///
  /// Taken from the start options so a renamed device is cleaned up correctly;
  /// falls back to the shared default before a start has been requested.
  String get _tunAdapterName =>
      startOptions?.tunDeviceName ?? WindowsTunDriver.adapterName;

  Directory? _dataDir;
  String? _corePath;
  bool _tunMode = false;
  Timer? _proxyWatchdog;
  int? _proxyPort;
  String? _proxyBypass;

  List<String> get coreLog => List.unmodifiable(_coreLog);

  /// The core prints its reason and exits when it rejects the profile, for
  /// example a field the running build reads differently. Reporting that line
  /// turns a twenty second "controller did not answer" into the actual cause.
  @override
  String? get coreStartupFailure {
    if (_process != null) return null;
    for (var index = _coreLog.length - 1; index >= 0; index--) {
      final line = _coreLog[index].trim();
      if (!line.contains('core failed to start')) continue;
      final reason = line.replaceFirst(RegExp(r'^scaleguard-core:\s*'), '');
      // The core puts the offending file and line on the next entry.
      final detail = index + 1 < _coreLog.length &&
              _coreLog[index + 1].trim().startsWith('line ')
          ? ' ${_coreLog[index + 1].trim()}'
          : '';
      return 'Ядро не запустилось: $reason$detail';
    }
    for (var index = _coreLog.length - 1; index >= 0; index--) {
      final line = _coreLog[index].trim();
      if (!line.startsWith('[core exited with code')) continue;
      return 'Ядро не запустилось: ${line.replaceAll(RegExp(r'[\[\]]'), '')}';
    }
    return null;
  }

  @override
  String get platformName => 'Windows (mihomo, sidecar)';

  /// Resolves the core path eagerly: the integrity check and the TUN driver
  /// installer both need it before a tunnel exists.
  @override
  String? get coreExecutablePath => _corePath;

  /// Both modes are available: the system proxy needs no elevation, TUN covers
  /// every application but requires the process to run as administrator.
  @override
  bool get supportsTunMode => true;

  /// TUN by default: it is the mode that actually covers every application, so
  /// the tunnel behaves the way a user expects without having to discover a
  /// second switch. The system proxy stays one toggle away for machines where
  /// elevation is not wanted.
  @override
  VpnTunnelMode get preferredMode => VpnTunnelMode.tun;

  @override
  Future<void> initialize() async {
    final dataDirectory = _dataDir ??= await _resolveDataDir();
    _corePath ??= await _resolveCorePath();
    // Recovery comes first. A machine whose WinINet proxy still points at a core
    // that no longer runs has no working internet at all, and the setting that
    // caused it is not something a user can be expected to find. Writing the
    // captured configuration next to the generated profile is what makes it
    // recoverable after a forced exit.
    _systemProxy.backupFilePath =
        '${dataDirectory.path}${Platform.pathSeparator}proxy-backup.json';
    await _systemProxy.recoverFromBackup();
    // The job object the runner creates already covers a forced shutdown; this
    // covers a core that was started before it existed — by an older build, for
    // instance — and it is what the log points at when the question is "did the
    // client really leave nothing behind".
    await killStrayCores();
  }

  /// Ends cores left behind by an earlier run of this installation.
  ///
  /// Only processes running exactly the executable this installation launches
  /// are touched. `mihomo.exe` is a common sidecar and killing somebody else's
  /// copy — FlClash's, say — would be a hostile act on a machine this client
  /// does not own.
  Future<int> killStrayCores() async {
    if (!Platform.isWindows) return 0;
    final corePath = _corePath ??= await _resolveCorePath();
    final quoted = corePath.replaceAll("'", "''");
    try {
      final result = await runPowerShell('''
\$target = '$quoted'
\$stray = @(Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" -ErrorAction SilentlyContinue |
  Where-Object { \$_.ExecutablePath -eq \$target })
foreach (\$strayProcess in \$stray) {
  Stop-Process -Id \$strayProcess.ProcessId -Force -ErrorAction SilentlyContinue
}
\$stray.Count
''', timeout: const Duration(seconds: 25));
      if (!result.ok) return 0;
      final count = int.tryParse(result.firstLine) ?? 0;
      if (count > 0) {
        LogService.instance
            .log('engine', 'stopped $count core process(es) left by an earlier run');
      }
      return count;
    } catch (_) {
      // Best effort: a core that cannot be found is not a reason to refuse to
      // start.
      return 0;
    }
  }

  /// Addresses for this machine's tunnel adapter.
  ///
  /// The core's own defaults — `198.18.0.1/30` and `fdfe:dcba:9876::1/126` — are
  /// the defaults of every other Clash-family client as well, and on a machine
  /// running one of them (FlClash, Clash Verge) the second adapter asking for the
  /// same address is refused: `set ipv4 address: The object already exists`.
  /// The core then keeps answering on its controller while the tunnel has no
  /// interface at all, which is exactly the "connected but nothing works" state.
  /// Asking for an address nobody holds removes the whole class of failure.
  ///
  /// The kept-for-last candidate is the familiar one, so a machine without a
  /// second VPN client gets the address its own documentation mentions.
  @override
  Future<TunAddresses?> chooseTunAddresses() async {
    if (!Platform.isWindows) return null;
    try {
      final taken = await _assignedAddresses();
      for (final candidate in _tunAddressCandidates) {
        if (taken.contains(_hostOf(candidate.v4)) ||
            taken.contains(_hostOf(candidate.v6))) {
          continue;
        }
        LogService.instance.log('engine', 'tun adapter addresses: $candidate');
        return candidate;
      }
      LogService.instance.log(
        'engine',
        'every candidate TUN address is in use; falling back to '
        '${_tunAddressCandidates.first}',
      );
    } catch (error) {
      LogService.instance.log('engine', 'could not pick a TUN address: $error');
    }
    return _tunAddressCandidates.first;
  }

  /// Candidate address pairs, most familiar first.
  static const List<TunAddresses> _tunAddressCandidates = [
    TunAddresses(v4: '172.19.0.1/30', v6: 'fdfe:dcba:9876:1::1/126'),
    TunAddresses(v4: '172.30.0.1/30', v6: 'fdfe:dcba:9876:2::1/126'),
    TunAddresses(v4: '172.31.0.1/30', v6: 'fdfe:dcba:9876:3::1/126'),
  ];

  /// Every address currently assigned to an interface of this machine.
  ///
  /// An unanswerable question must not block a tunnel: when the query fails the
  /// returned set is empty and the first candidate is used. The core's own error
  /// line is the better report at that point.
  Future<Set<String>> _assignedAddresses() async {
    final result = await runPowerShell('''
Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { \$_.IPAddress }
''', timeout: const Duration(seconds: 20));
    if (!result.ok) throw StateError('Get-NetIPAddress exit ${result.exitCode}');
    return result.stdout
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();
  }

  /// The address part of a CIDR, which is what the interface list reports.
  static String _hostOf(String cidr) {
    final slash = cidr.indexOf('/');
    return slash == -1 ? cidr : cidr.substring(0, slash);
  }

  @override
  Future<bool> requestTunnelPermission() async {
    // Windows has no per-application VPN consent dialog. TUN mode instead
    // needs an elevated token, which is checked here so the UI can explain the
    // requirement before the core fails to create its adapter.
    if (!_tunMode) return true;
    return isProcessElevated();
  }

  @override
  Future<String> writeConfig(String config) async {
    final directory = _dataDir ??= await _resolveDataDir();
    final file = File('${directory.path}${Platform.pathSeparator}config.yaml');
    await file.writeAsString(config, flush: true);
    return file.path;
  }

  @override
  Future<String> launchCore({
    required String configPath,
    required int controllerPort,
    required String secret,
    required String logLevel,
  }) async {
    final corePath = _corePath ??= await _resolveCorePath();
    final dataDir = _dataDir ??= await _resolveDataDir();
    LogService.instance.log('engine', 'launching core: $corePath');

    // The log is per launch: keeping the previous run's lines would make the TUN
    // verification below fail on an error that has long been dealt with.
    _coreLog.clear();

    // A leftover adapter makes Wintun's create call fail, and the core then
    // reports a TUN setup error while its controller still answers — which is
    // how the client ended up claiming a working tunnel that routed nothing.
    // Clearing it first is what makes this attempt succeed.
    if (startOptions?.mode == VpnTunnelMode.tun) {
      await _clearTunAdapter(reason: 'before start');
    }

    if (!File(corePath).existsSync()) {
      throw StateError(
        'Ядро mihomo не найдено: $corePath. '
        'Соберите его командой из docs/windows.md или переустановите приложение.',
      );
    }

    final process = await Process.start(
      corePath,
      [
        '-config',
        configPath,
        '-d',
        dataDir.path,
        '-controller',
        '127.0.0.1:$controllerPort',
        '-secret',
        secret,
        '-log-level',
        logLevel,
      ],
      workingDirectory: dataDir.path,
      runInShell: false,
      // `x509usefallbackroots=1` makes Go build TLS certificate chains itself
      // instead of calling the Windows chain engine, whose release call crashes
      // with an access violation on some machines. The core is built to hand Go
      // the system roots for that; this is the switch that activates it, and
      // setting it in the child's environment guarantees it is in place before
      // the runtime reads its environment.
      environment: _coreEnvironment(),
    );
    _process = process;

    // The core announces readiness on stdout; capturing the log makes
    // "why did the tunnel not come up" answerable from the UI.
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_recordCoreLog);
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_recordCoreLog);

    unawaited(
      process.exitCode.then((code) async {
        if (_process != process) return;
        _process = null;
        _recordCoreLog('[core exited with code $code]');
        // The core is gone, so any adapter or proxy setting it owned must be
        // released even if the UI never asked for a disconnect.
        await _releaseTunnelResources();
        if (startOptions?.mode == VpnTunnelMode.tun) {
          await _clearTunAdapter(reason: 'core exited');
        }
        _reportCrash(code);
      }),
    );

    return 'http://127.0.0.1:$controllerPort';
  }

  /// Environment for the core process.
  ///
  /// Only `GODEBUG` is added, and the user's own value is preserved: an
  /// explicit `x509usefallbackroots` setting in the environment wins, because
  /// whoever put it there meant it.
  Map<String, String> _coreEnvironment() {
    final existing = Platform.environment['GODEBUG'] ?? '';
    if (existing.contains('x509usefallbackroots=')) {
      return <String, String>{'GODEBUG': existing};
    }
    final merged = existing.isEmpty
        ? 'x509usefallbackroots=1'
        : '$existing,x509usefallbackroots=1';
    return <String, String>{'GODEBUG': merged};
  }

  /// Persists the evidence and hands the failure to the engine base.
  ///
  /// A core crash leaves a stack trace on stderr; that trace is the only thing
  /// that makes the failure diagnosable, so the last lines are written to the
  /// application log before the failure is reported. The log rotates on every
  /// launch, which used to throw this away.
  void _reportCrash(int exitCode) {
    if (exitCode != 0 && _coreLog.isNotEmpty) {
      final tail = _coreLog.length > 40
          ? _coreLog.sublist(_coreLog.length - 40)
          : List<String>.from(_coreLog);
      LogService.instance
          .log('engine', 'core crashed (exit $exitCode); last output:\n'
              '${tail.join('\n')}');
    }
    reportCoreCrash(exitCode);
  }

  @override
  Future<void> onCoreStarted(EngineStartOptions options, int mixedPort) async {
    _tunMode = options.mode == VpnTunnelMode.tun;
    LogService.instance.log(
      'engine',
      _tunMode
          ? 'tunnel up: TUN adapter'
          : 'tunnel up: system proxy on port $mixedPort',
    );
    if (_tunMode) {
      _stopProxyWatchdog();
      await _ensureDataDirOnPath();
      await _verifyTun();
      return;
    }
    _proxyPort = mixedPort;
    _proxyBypass = options.bypassLocalNetworks
        ? _defaultBypass
        : 'localhost;127.*;<local>';
    await _systemProxy.apply(port: mixedPort, bypass: _proxyBypass!);
    _startProxyWatchdog();
  }

  @override
  Future<void> onBeforeCoreStop() async {
    await _releaseTunnelResources();
  }

  @override
  Future<void> shutdownCore() async {
    // A system-proxy change must be undone before the core disappears,
    // otherwise applications keep sending traffic to a closed port.
    await _releaseTunnelResources();
    final process = _process;
    _process = null;
    if (process == null) return;
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;

    // Disconnect has to mean the process is gone, not that it was asked to go:
    // a core that survives keeps its adapter, its routes and whatever else it
    // installed, and the next start then fails on resources that are still in
    // use. Both signals are therefore followed up, and a process that ignores
    // them is taken down by pid — with its children.
    process.kill(ProcessSignal.sigterm);
    var exited = false;
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
      exited = true;
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
        exited = true;
      } on TimeoutException {
        exited = false;
      }
    }
    if (!exited) {
      await _forceKill(process.pid);
    }

    // Wintun leaves the adapter behind on some machines, and the next start
    // would then fail with "already exists" while still looking healthy.
    if (_tunMode) {
      await _clearTunAdapter(reason: 'after stop');
    }
  }

  /// Last resort for a core that refused to die.
  ///
  /// `/t` takes the process tree with it, which is the point: the core is the
  /// only process this client starts, and leaving any descendant behind would
  /// keep the tunnel up in a state nothing can control.
  Future<void> _forceKill(int pid) async {
    LogService.instance
        .log('engine', 'core survived both signals; forcing pid $pid');
    try {
      await Process.run('taskkill', <String>['/pid', '$pid', '/t', '/f']);
    } catch (_) {
      // Nothing else to try; the job object still covers the process when this
      // one exits.
    }
  }

  /// Restores the system proxy configuration.
  ///
  /// Called both on a normal disconnect and after an unexpected core exit, so
  /// the machine is never left pointing at a port that no longer listens.
  Future<void> _releaseTunnelResources() async {
    _stopProxyWatchdog();
    LogService.instance.log('engine', 'releasing tunnel resources');
    try {
      await _systemProxy.restore();
    } catch (_) {}
  }

  /// Removes the adapter the core created, or a leftover from an earlier run.
  ///
  /// Wintun refuses to create an adapter whose name is already taken: the core
  /// then logs `configure tun interface: Cannot create a file when that file
  /// already exists` while its controller keeps answering, and the client used
  /// to read that as a successful connect. The result was a tunnel that carried
  /// nothing — no counters moving, no external address — which is exactly the
  /// state the UI showed as "connected".
  ///
  /// Clearing the adapter before a start is what makes the next attempt work;
  /// clearing it after an exit keeps the machine ready for the next one.
  Future<void> _clearTunAdapter({required String reason}) async {
    if (!Platform.isWindows) return;
    try {
      final result = await runPowerShell('''
\$adapter = Get-NetAdapter -IncludeHidden -Name '$_tunAdapterName' -ErrorAction SilentlyContinue
if (\$null -eq \$adapter) { 'absent' } else {
  Remove-NetAdapter -InputObject \$adapter -Confirm:\$false -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
  if (Get-NetAdapter -IncludeHidden -Name '$_tunAdapterName' -ErrorAction SilentlyContinue) { 'stuck' } else { 'removed' }
}
''');
      if (result.stdout.contains('removed')) {
        _recordCoreLog('[ScaleGuard] removed a leftover TUN adapter ($reason)');
      } else if (result.stdout.contains('stuck')) {
        LogService.instance.log(
          'engine',
          'could not remove the stale TUN adapter ($reason)',
        );
      }
    } catch (error) {
      // Best effort. If the adapter really is in the way, the check that follows
      // the start reports it, and that message is the one the user can act on.
      LogService.instance.log('engine', 'tun adapter cleanup failed: $error');
    }
  }

  /// Confirms the core really created its adapter.
  ///
  /// Two signals are used because either one alone has a blind spot: the core's
  /// own error line proves the setup failed even when an adapter of the same
  /// name is lying around, and the adapter check catches a setup that silently
  /// did nothing. The controller answering is evidence of neither — it comes up
  /// regardless, which is how a tunnel that carried nothing was reported as
  /// connected.
  Future<void> _verifyTun() async {
    final failure = _coreLog.lastWhere(
      (line) => line.contains('Start TUN listening error'),
      orElse: () => '',
    );
    if (failure.isEmpty && await _tunAdapterReady()) return;
    // Three causes need three different words: an address another adapter holds
    // (a second Clash-family client, the failure that used to look like "no
    // adapter"), a leftover adapter of our own, and missing administrator rights.
    final conflict = failure.toLowerCase();
    throw StateError(
      conflict.contains('set ipv4 address') || conflict.contains('set ipv6 address')
          ? 'Адрес виртуального адаптера занят: его удерживает другой клиент '
              'с виртуальным адаптером (например, FlClash или Clash Verge). '
              'Закройте его и подключитесь снова — приложение выберет '
              'свободный адрес само.'
          : conflict.contains('already exists')
          ? 'Виртуальный адаптер уже существует. Переподключитесь — приложение '
              'уберёт старый адаптер и создаст новый.'
          : 'Виртуальный адаптер не поднялся. Проверьте, что приложение запущено '
              'от имени администратора, и повторите подключение.',
    );
  }

  /// Waits briefly for the adapter the core is supposed to create.
  ///
  /// Returns `true` when the adapter is there *or* when the question cannot be
  /// answered, so an unusual environment never blocks a tunnel that works. Only
  /// a definite "there is no adapter" is treated as a failure.
  Future<bool> _tunAdapterReady() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final result = await runPowerShell('''
if (Get-NetAdapter -IncludeHidden -Name '$_tunAdapterName' -ErrorAction SilentlyContinue) { 'present' } else { 'absent' }
''');
      if (!result.ok) return true;
      if (result.stdout.contains('present')) return true;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return false;
  }

  /// Re-applies the WinINet proxy when something else turns it off.
  ///
  /// Other Clash-family clients on the same machine (FlClash, v2rayN and
  /// friends) reset `ProxyEnable` whenever their own tunnel state changes.
  /// Left alone, every proxy-aware application silently returns to the direct
  /// route while this client keeps showing "connected". The watchdog reads the
  /// live registry state and restores ours within seconds.
  void _startProxyWatchdog() {
    _stopProxyWatchdog();
    _proxyWatchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_ensureSystemProxyAlive());
    });
  }

  Future<void> _ensureSystemProxyAlive() async {
    final port = _proxyPort;
    if (port == null || _tunMode || _process == null) return;
    try {
      final state = await _systemProxy.readState();
      if (_process == null || _tunMode) return;
      if (state.enabled && state.server == '127.0.0.1:$port') return;
      await _systemProxy.apply(
        port: port,
        bypass: _proxyBypass ?? _defaultBypass,
      );
      _recordCoreLog(
        '[ScaleGuard] system proxy was disabled by another program; re-applied',
      );
    } catch (_) {
      // A failed re-apply must not tear the tunnel down; the next tick retries.
    }
  }

  void _stopProxyWatchdog() {
    _proxyWatchdog?.cancel();
    _proxyWatchdog = null;
  }

  Future<void> _ensureDataDirOnPath() async {
    // In TUN mode mihomo also creates its adapter and, on some systems, needs
    // to resolve its bundled geo files from the working directory; nothing
    // extra is required here beyond having the directory ready, which
    // `writeConfig` already guarantees.
    final directory = _dataDir;
    if (directory != null && !directory.existsSync()) {
      await directory.create(recursive: true);
    }
  }

  /// Resolves a writable per-user directory for the generated profile, the
  /// core's cache database and its logs.
  Future<Directory> _resolveDataDir() async {
    final override = _dataDirOverride;
    final directory = override ??
        Directory(
          '${Platform.environment['APPDATA'] ?? Directory.current.path}'
          '${Platform.pathSeparator}ScaleGuard'
          '${Platform.pathSeparator}core',
        );
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    // The generated profile contains credentials, so it must not be readable by
    // other users on a shared machine.
    if (Platform.isWindows) {
      await _hardenAcl(directory.path);
    }
    return directory;
  }

  Future<void> _hardenAcl(String path) async {
    try {
      final script = '''
\$ErrorActionPreference = 'SilentlyContinue'
\$acl = Get-Acl -Path '${path.replaceAll("'", "''")}'
\$acl.SetAccessRuleProtection(\$true, \$false)
\$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
  [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
  'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
\$acl.SetAccessRule(\$rule)
Set-Acl -Path '${path.replaceAll("'", "''")}' -AclObject \$acl
'ok'
''';
      final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}sg-acl.ps1');
      await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
      await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        file.path,
      ]);
      await file.delete().catchError((_) => file);
    } catch (_) {
      // Hardening is best effort: a failure must not block the tunnel.
    }
  }

  /// Locates `mihomo.exe`.
  ///
  /// The primary location is a `core` folder next to the executable, because
  /// that is where an installer places it; the build tree path is also checked
  /// so `flutter run` works without an extra copy step.
  Future<String> _resolveCorePath() async {
    final override = _corePathOverride;
    if (override != null && override.isNotEmpty) {
      return File(override).absolute.path;
    }
    final separator = Platform.pathSeparator;
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$executableDir${separator}core${separator}mihomo.exe',
      '$executableDir${separator}mihomo.exe',
      '${Directory.current.path}${separator}windows${separator}runner${separator}mihomo.exe',
      '$executableDir${separator}..${separator}..${separator}..${separator}..${separator}..${separator}windows${separator}runner${separator}mihomo.exe',
    ];
    for (final candidate in candidates) {
      final normalized = File(candidate).absolute.path;
      if (File(normalized).existsSync()) return normalized;
    }
    // Default to the installed layout so the error message is actionable.
    return '$executableDir${separator}core${separator}mihomo.exe';
  }

  void _recordCoreLog(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _coreLog.add(trimmed);
    LogService.instance.log('core', trimmed);
    if (_coreLog.length > 400) {
      _coreLog.removeRange(0, _coreLog.length - 400);
    }
  }

  /// Bypass list for the system proxy.
  ///
  /// Anything on the loopback interface or a private range must stay direct,
  /// otherwise the application loses its own API connection and LAN devices
  /// become unreachable while the tunnel is up.
  static const String _defaultBypass =
      'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;'
      '172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;'
      '172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>';
}
