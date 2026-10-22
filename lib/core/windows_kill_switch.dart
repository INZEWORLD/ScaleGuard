import 'dart:convert';
import 'dart:io';

import '../services/log_service.dart';
import 'powershell.dart';
import 'windows_tun.dart';

/// Cuts every route out of the machine except the tunnel.
///
/// The mechanism is the Windows Firewall's *default outbound action*, not a
/// blanket block rule. That distinction is the whole design: an explicit block
/// rule outranks every allow rule, so "block everything, allow the core" built
/// from block rules does not work — it blocks the core as well. Microsoft
/// documents the opposite precedence for the default action ("explicitly defined
/// allow rules take precedence over the default block setting"), which is what
/// the allow list below relies on.
///
/// What the allow list leaves a way out for, and why:
///
/// * the core — its own sockets to the remote servers *are* the tunnel;
/// * the client — the panel API, the subscription and the update check;
/// * loopback — the local mixed port every proxy-aware application talks to;
/// * the local subnet — the router, DHCP and the DNS resolver sitting on it;
/// * the tunnel adapter — the packets applications hand to the tunnel, which the
///   firewall otherwise sees as ordinary outbound traffic.
///
/// Everything else — a browser that ignores the proxy, a torrent client, an
/// updater — is out of luck exactly while the tunnel is not up, which is the
/// point.
///
/// Four safeguards keep that from becoming a machine with no internet:
///
/// 1. The previous profile actions are written to disk *before* the setting is
///    changed, so a crash leaves a record of how to get back.
/// 2. The allow rules are created *before* the default action is flipped, and a
///    failure while creating them aborts the whole operation.
/// 3. A release is only believed once the firewall reports the old state back.
///    An unelevated release fails with "access denied", and reporting success
///    there would delete the only record of what to restore.
/// 4. A scheduled task, awake every minute while the switch is engaged, restores
///    the previous state if the client disappears without releasing it — a
///    force-close from the task manager being the obvious way in. It leaves the
///    machine alone while the client is running, and deletes itself once it has
///    done its job.
///
/// The three scripts are built by static methods rather than inline, so they can
/// be inspected and parse-checked without a machine's firewall being touched —
/// see `test/kill_switch_test.dart` and `tool/verify_kill_switch.dart`.
class WindowsKillSwitch {
  WindowsKillSwitch({String? baseDirectory})
      : _baseDirectory = Directory(baseDirectory ?? _defaultBasePath());

  /// Root of the files that have to outlive the process.
  ///
  /// Deliberately *not* the core's data directory: that one is ACL-hardened to
  /// the current user alone, and the failsafe task runs as `SYSTEM`, which would
  /// then be unable to read the script or the backup.
  final Directory _baseDirectory;

  static String _defaultBasePath() {
    final appData = Platform.environment['APPDATA'];
    final root =
        (appData == null || appData.isEmpty) ? Directory.current.path : appData;
    return '$root${Platform.pathSeparator}ScaleGuard';
  }

  /// All rules this class owns. The prefix is what makes them findable and
  /// removable as a group, so an interrupted run cannot leave a stray rule
  /// behind.
  static const String _rulePrefix = 'ScaleGuard: ';

  /// Name of the failsafe task.
  static const String _taskName = 'ScaleGuard kill switch release';

  /// Name of the client process. The failsafe uses it to tell "the client died"
  /// from "the client is running and looking after the switch itself".
  static const String _clientProcessName = 'ScaleGuard';

  /// Cadence of the failsafe task while the switch is engaged.
  ///
  /// Every minute, and it costs almost nothing: the task's first act is to look
  /// for the client and leave again when it is running. What the cadence buys is
  /// the other case — a client killed from the task manager leaves the machine
  /// with no internet, and this is how long that lasts.
  static const String _failsafeCadence = '1';

  /// Tokens the scripts print when they finish, which is how a run is judged.
  ///
  /// Not the exit code: PowerShell exits zero when it ran, not when the firewall
  /// agreed. Anything else on the output stream — a warning, a partial write —
  /// then cannot be mistaken for success, so the tokens are deliberately words
  /// that do not appear in any Windows message.
  static const String _armedToken = 'sg-armed';

  static const String _releasedToken = 'sg-released';

  static const String _tunnelToken = 'sg-tunnel';

  /// Tokens for the read-only check behind [isBlocking].
  static const String _blockingToken = 'sg-blocking';

  static const String _openToken = 'sg-open';

  /// Last failure, for the settings screen. `null` while everything works.
  String? lastError;

  bool get isSupported => Platform.isWindows;

  String get backupFilePath =>
      '${_baseDirectory.path}${Platform.pathSeparator}kill-switch.json';

  String get releaseScriptPath =>
      '${_baseDirectory.path}${Platform.pathSeparator}kill-switch-release.ps1';

  /// True when a backup is on disk, which means the switch is (or should be)
  /// engaged.
  bool get isActive => File(backupFilePath).existsSync();

  // ---------------------------------------------------------------------------
  // Scripts
  // ---------------------------------------------------------------------------

  /// The PowerShell that [enable] runs.
  ///
  /// Order matters and is the reason this is readable as text: every allow rule
  /// exists before the default action changes, so a run that is refused halfway
  /// through leaves the machine exactly as it was.
  static String enableScript({
    required String corePath,
    required String clientPath,
    required String backupFilePath,
  }) {
    final rules = <String>[
      'core|-Program ${_psQuote(corePath)}',
      'client|-Program ${_psQuote(clientPath)}',
      'loopback|-RemoteAddress 127.0.0.0/8,::1',
      'lan|-RemoteAddress LocalSubnet',
    ];
    final script = StringBuffer()
      ..writeln("\$ErrorActionPreference = 'Stop'")
      // The profile actions are read first and stored, so restoring them later
      // does not depend on the app still being alive to remember them.
      ..writeln(r'$previous = @{}')
      ..writeln("foreach (\$profile in @('Domain', 'Private', 'Public')) {")
      ..writeln('  \$previous[\$profile] = '
          '(Get-NetFirewallProfile -Profile \$profile)'
          '.DefaultOutboundAction.ToString()')
      ..writeln('}')
      ..writeln('\$state = Get-Content -Raw -Path ${_psQuote(backupFilePath)} '
          '| ConvertFrom-Json')
      ..writeln("\$state | Add-Member -NotePropertyName 'previous' "
          '-NotePropertyValue \$previous -Force')
      ..writeln('\$state | ConvertTo-Json -Depth 6 | '
          'Set-Content -Path ${_psQuote(backupFilePath)} -Encoding UTF8')
      // Any stray rule from an interrupted earlier run goes first, so the set is
      // exactly the one described here.
      ..writeln("Get-NetFirewallRule -DisplayName '$_rulePrefix*' "
          '-ErrorAction SilentlyContinue | Remove-NetFirewallRule '
          '-ErrorAction SilentlyContinue');
    for (final rule in rules) {
      final parts = rule.split('|');
      script.writeln(
        'New-NetFirewallRule -DisplayName ${_psQuote('$_rulePrefix${parts[0]}')} '
        '-Direction Outbound -Action Allow -Profile Any -Enabled True '
        '${parts[1]} | Out-Null',
      );
    }
    script
      ..writeln('Set-NetFirewallProfile -Profile Domain,Private,Public '
          '-DefaultOutboundAction Block')
      ..writeln("'$_armedToken'");
    return script.toString();
  }

  /// The PowerShell that [allowTunnelInterface] runs.
  ///
  /// Its own step because it names an interface, and the adapter only comes into
  /// being while the tunnel is coming up. Everything that can be allowed before
  /// that already is, and the default action is already blocking, so the moment
  /// in between is the opposite of a leak: at that point nothing at all gets out.
  static String tunnelScript({
    required String adapterName,
  }) {
    final name = '${_rulePrefix}tunnel';
    return (StringBuffer()
          ..writeln("\$ErrorActionPreference = 'Stop'")
          // Idempotent: a reconnect rebuilds the adapter, and a leftover rule
          // could end up attached to an alias that is no longer the one meant.
          ..writeln('Get-NetFirewallRule -DisplayName ${_psQuote(name)} '
              '-ErrorAction SilentlyContinue | Remove-NetFirewallRule '
              '-ErrorAction SilentlyContinue')
          ..writeln('New-NetFirewallRule -DisplayName ${_psQuote(name)} '
              '-Direction Outbound -Action Allow -Profile Any -Enabled True '
              '-InterfaceAlias ${_psQuote(adapterName)} | Out-Null')
          ..writeln("'$_tunnelToken'"))
        .toString();
  }

  /// The PowerShell that restores the machine, built from the actions the
  /// backup recorded.
  static String disableScript(Map<String, String> previous) {
    final script = StringBuffer()
      // Not `Stop`: one profile refusing the change must not skip the other two.
      ..writeln(r"$ErrorActionPreference = 'SilentlyContinue'");
    // Unblocked first: the allow rules are about to disappear, and leaving the
    // default action in place even for a moment is what would cut a machine off.
    for (final entry in previous.entries) {
      script.writeln('Set-NetFirewallProfile -Profile ${entry.key} '
          '-DefaultOutboundAction ${entry.value}');
    }
    script
      ..writeln("Get-NetFirewallRule -DisplayName '$_rulePrefix*' "
          '| Remove-NetFirewallRule')
      // The actions are then read back, so "did it work" is answered by the
      // firewall instead of by the absence of an error message.
      ..writeln(r'$expected = @{');
    for (final entry in previous.entries) {
      script.writeln("  '${entry.key}' = '${entry.value}'");
    }
    script
      ..writeln('}')
      ..writeln(r'$mismatch = $false')
      ..writeln("foreach (\$name in @('Domain', 'Private', 'Public')) {")
      ..writeln('  \$actual = (Get-NetFirewallProfile -Profile \$name)'
          '.DefaultOutboundAction.ToString()')
      ..writeln('  if (\$actual -ne \$expected[\$name]) { \$mismatch = \$true }')
      ..writeln('}')
      ..writeln("if (\$mismatch) { 'mismatch' } else { '$_releasedToken' }");
    return script.toString();
  }

  /// The PowerShell that answers "is the machine blocking?" — a read, so it works
  /// from an unelevated session too.
  ///
  /// This exists because an enable cannot always be judged from its own output.
  /// PowerShell writes non-ASCII text in the console code page, so an error
  /// message can arrive undecodable, and a failed decode must not be mistaken for
  /// a failed enable: the machine would be left blocking with the record of how
  /// to undo it deleted. Asking the firewall is the only answer that matters.
  static String verifyScript() {
    return (StringBuffer()
          ..writeln(r"$ErrorActionPreference = 'SilentlyContinue'")
          ..writeln(r'$blocking = $true')
          ..writeln("foreach (\$name in @('Domain', 'Private', 'Public')) {")
          ..writeln('  \$action = (Get-NetFirewallProfile -Profile \$name)'
              '.DefaultOutboundAction.ToString()')
          ..writeln("  if (\$action -ne 'Block') { \$blocking = \$false }")
          ..writeln('}')
          ..writeln("if (\$blocking) { '$_blockingToken' } "
              "else { '$_openToken' }"))
        .toString();
  }

  // ---------------------------------------------------------------------------
  // Operations
  // ---------------------------------------------------------------------------

  /// Whether the machine's outbound default is blocking on all three profiles,
  /// which is the state [enable] leaves behind.
  Future<bool> isBlocking() async {
    if (!isSupported) return false;
    final result = await runPowerShell(
      verifyScript(),
      timeout: const Duration(seconds: 30),
    );
    return result.ok && result.stdout.contains(_blockingToken);
  }

  /// Engages the parts of the switch that can be put in place before a tunnel
  /// exists: the program rules, the address rules, and then the change of the
  /// default action.
  ///
  /// Returns whether the firewall accepted it.
  Future<bool> enable({
    required String corePath,
    required String clientPath,
  }) async {
    if (!isSupported) return false;
    lastError = null;

    await _baseDirectory.create(recursive: true);
    // Written before anything changes, so the failsafe task and a later launch
    // both find a record of how the machine was configured.
    final backup = <String, Object?>{
      'active': true,
      'createdAt': DateTime.now().toIso8601String(),
      'rules': _ruleNames(),
    };
    await File(backupFilePath).writeAsString(jsonEncode(backup), flush: true);
    await _writeReleaseScript();

    final result = await runPowerShell(
      enableScript(
        corePath: corePath,
        clientPath: clientPath,
        backupFilePath: backupFilePath,
      ),
      timeout: const Duration(seconds: 60),
    );
    if (result.ok && result.stdout.contains(_armedToken)) {
      await armFailsafe();
      LogService.instance.log('killswitch', 'engaged');
      return true;
    }
    // No token: either the script refused, or it did the job and its output could
    // not be read back. The two are told apart by asking the firewall, because
    // guessing wrong in one direction leaves a machine with no internet, and in
    // the other one with no protection while the UI says otherwise.
    if (await isBlocking()) {
      await armFailsafe();
      LogService.instance
          .log('killswitch', 'engaged (the script output was unreadable)');
      return true;
    }
    lastError = _enableFailure(result);
    LogService.instance
        .log('killswitch', 'enable refused: ${result.diagnostic}');
    // Nothing is blocking, so the backup goes: keeping it would make the next
    // launch try to "restore" a firewall state that was never changed.
    await _removeRules();
    await _deleteQuietly(File(backupFilePath));
    return false;
  }

  /// A reason worth showing a user, with the technical detail left to the log.
  ///
  /// `schtasks` and PowerShell answer in the console code page, so their text
  /// arrives as mojibake; the exit code is not a diagnosis either. What the user
  /// can act on is that Windows refused, and the two usual fixes.
  String _enableFailure(PowerShellResult result) {
    if (result.ok) {
      return 'Брандмауэр не подтвердил включение защиты';
    }
    return 'Windows не дал изменить настройки брандмауэра. '
        'Запустите программу от имени администратора';
  }

  /// Allows what travels through the tunnel adapter, once it exists.
  Future<bool> allowTunnelInterface({
    String adapterName = WindowsTunDriver.adapterName,
  }) async {
    if (!isSupported) return false;
    if (!isActive) return false;
    lastError = null;
    final result = await runPowerShell(
      tunnelScript(adapterName: adapterName),
      timeout: const Duration(seconds: 45),
    );
    if (!result.ok || !result.stdout.contains(_tunnelToken)) {
      lastError = 'Windows не дал разрешить трафик туннеля';
      LogService.instance.log(
        'killswitch',
        'the tunnel interface rule was refused: ${result.diagnostic}',
      );
      return false;
    }
    return true;
  }

  /// Restores the machine's previous firewall configuration.
  ///
  /// Returns whether the machine is verifiably back to the state it was in —
  /// which is not the same question as "did the command succeed". Without the
  /// check an unelevated release would report success, delete the only record of
  /// what to restore, and leave the machine blocked with nobody left to unblock
  /// it.
  Future<bool> disable() async {
    if (!isSupported) return false;
    final previous = await _readPreviousActions();
    final result = await runPowerShell(
      disableScript(previous),
      timeout: const Duration(seconds: 60),
    );
    final verified = result.ok && result.stdout.contains(_releasedToken);
    if (!verified) {
      lastError = 'Не удалось снять блокировку. Брандмауэр не подтвердил '
          'возврат настроек';
      LogService.instance
          .log('killswitch', 'release failed: ${result.diagnostic}');
      // The backup stays: it is the only remaining description of how to get
      // back, and the next launch — elevated, most likely — tries again.
      return false;
    }
    LogService.instance.log('killswitch', 'released');
    await _deleteQuietly(File(backupFilePath));
    await _disarmFailsafe();
    return true;
  }

  /// Releases a switch left behind by a client that was killed before it could
  /// release it itself.
  ///
  /// Runs on every launch, before the tunnel is touched. Without it a machine
  /// whose client was ended in the task manager would have no internet at all
  /// until the user found the firewall setting, which is not something to ask of
  /// anybody.
  Future<bool> repairFromBackup() async {
    if (!isSupported) return false;
    if (!isActive) return false;
    LogService.instance.log(
      'killswitch',
      'a previous session left the switch engaged; releasing',
    );
    return disable();
  }

  /// The rule names this class owns, for the backup record.
  static List<String> _ruleNames() => <String>[
        '${_rulePrefix}core',
        '${_rulePrefix}client',
        '${_rulePrefix}loopback',
        '${_rulePrefix}lan',
        '${_rulePrefix}tunnel',
      ];

  /// Keeps the failsafe armed for as long as the switch is engaged.
  ///
  /// A task that repeats every [_failsafeCadence] minutes and removes itself the
  /// moment it has done its job, so nothing is left behind on the machine once
  /// the switch is released — by the client, or by the task itself.
  Future<void> armFailsafe() async {
    if (!isSupported) return;
    final now = DateTime.now();
    final stamp = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    // `SYSTEM` so the task needs no password and no interactive session: it has
    // to work after a logoff, which is one of the ways the client can disappear.
    final result = await Process.run('schtasks', <String>[
      '/create',
      '/f',
      '/tn',
      _taskName,
      '/sc',
      'MINUTE',
      '/mo',
      _failsafeCadence,
      '/st',
      stamp,
      '/ru',
      'SYSTEM',
      '/rl',
      'HIGHEST',
      '/tr',
      'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass '
          '-File "$releaseScriptPath"',
    ]);
    if (result.exitCode != 0) {
      // Not fatal: the switch still works, and the next launch repairs the state
      // on its own.
      LogService.instance
          .log('killswitch', 'failsafe task refused: ${result.stdout}');
    }
  }

  Future<void> _disarmFailsafe() async {
    await Process.run('schtasks', <String>[
      '/delete',
      '/f',
      '/tn',
      _taskName,
    ]);
  }

  /// The PowerShell the failsafe task runs.
  ///
  /// It restores the recorded profile actions and drops the rules, and it does
  /// nothing at all while the client is still running — the client looks after
  /// the switch itself, and releasing it there would silently turn the feature
  /// off in the middle of a healthy session. That check is what allows the task
  /// to repeat as often as it does.
  ///
  /// Having done its job it deletes the backup and itself: the task exists for
  /// the case where nobody is left to release the switch, and that case is over
  /// once it has run.
  static String releaseScript({required String backupFilePath}) {
    return (StringBuffer()
          ..writeln(r"$ErrorActionPreference = 'SilentlyContinue'")
          ..writeln('if (Get-Process -Name $_clientProcessName '
              '-ErrorAction SilentlyContinue) { exit 0 }')
          ..writeln('\$state = Get-Content -Raw -Path ${_psQuote(backupFilePath)} '
              '| ConvertFrom-Json')
          // Nothing to restore means the switch is no longer engaged, and this
          // task has outlived its purpose.
          ..writeln('if (\$null -eq \$state) { schtasks /delete /f /tn '
              '${_psQuote(_taskName)} | Out-Null; exit 0 }')
          ..writeln("foreach (\$profile in @('Domain', 'Private', 'Public')) {")
          ..writeln('  \$action = \$state.previous.\$profile')
          ..writeln("  if (-not \$action) { \$action = 'NotConfigured' }")
          ..writeln('  Set-NetFirewallProfile -Profile \$profile '
              '-DefaultOutboundAction \$action')
          ..writeln('}')
          ..writeln("Get-NetFirewallRule -DisplayName '$_rulePrefix*' "
              '| Remove-NetFirewallRule')
          ..writeln('Remove-Item -Path ${_psQuote(backupFilePath)} -Force')
          ..writeln('schtasks /delete /f /tn ${_psQuote(_taskName)} | Out-Null'))
        .toString();
  }

  /// Writes [releaseScript] where the task looks for it.
  Future<void> _writeReleaseScript() async {
    await File(releaseScriptPath).writeAsBytes(<int>[
      0xEF,
      0xBB,
      0xBF, // UTF-8 BOM, like every other script this app writes
      ...utf8.encode(releaseScript(backupFilePath: backupFilePath)),
    ], flush: true);
  }

  /// The profile actions to restore, from the backup.
  ///
  /// Anything unreadable falls back to `NotConfigured` — the state of a Windows
  /// installation that has never had its outbound policy touched — so a damaged
  /// backup still ends with a machine whose traffic is allowed.
  Future<Map<String, String>> _readPreviousActions() async {
    const fallback = <String, String>{
      'Domain': 'NotConfigured',
      'Private': 'NotConfigured',
      'Public': 'NotConfigured',
    };
    try {
      final file = File(backupFilePath);
      if (!file.existsSync()) return fallback;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return fallback;
      final previous = decoded['previous'];
      if (previous is! Map) return fallback;
      final actions = <String, String>{};
      for (final profile in <String>['Domain', 'Private', 'Public']) {
        final value = previous[profile]?.toString();
        // Only the three states the cmdlet accepts are passed through; anything
        // else is treated as "not configured", which is where a machine starts
        // before the switch is ever engaged.
        actions[profile] = value == 'Allow' || value == 'Block' ||
                value == 'NotConfigured'
            ? value!
            : 'NotConfigured';
      }
      return actions;
    } catch (_) {
      return fallback;
    }
  }

  /// Removes every rule this class owns, without touching the profile actions.
  ///
  /// Used when an enable fails after the rules existed but before the default
  /// action changed: stray rules in somebody's firewall are not acceptable
  /// housekeeping, even when they are harmless in themselves.
  Future<void> _removeRules() async {
    if (!isSupported) return;
    await runPowerShell(
      "Get-NetFirewallRule -DisplayName '$_rulePrefix*' "
      '| Remove-NetFirewallRule',
      timeout: const Duration(seconds: 30),
    );
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }
}

/// Single-quotes a value for PowerShell, doubling any embedded quote.
String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";
