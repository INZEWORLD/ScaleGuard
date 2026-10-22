// Parse-checks the PowerShell the kill switch runs.
//
// The switch cannot be exercised for real from here — engaging it changes the
// machine's default outbound action, and releasing it again is a firewall
// operation this session has no rights for. What *can* be checked is that the
// scripts are valid PowerShell, which is the failure that would matter most: a
// syntax error in the enable script means a user turns the feature on and the
// machine is left blocked by a half-applied script, and a syntax error in the
// failsafe script means the safety net silently does nothing.
//
// Windows ships a real parser that can be asked without a single command being
// run:  [Language.Parser]::ParseFile().
//
//   dart run tool/verify_kill_switch.dart
import 'dart:convert';
import 'dart:io';

import 'package:scaleguard_mobile/core/windows_kill_switch.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('Windows only.');
    return;
  }

  final temp = await Directory.systemTemp.createTemp('sg-killswitch-verify');
  try {
    final scripts = <String, String>{
      'enable':
          WindowsKillSwitch.enableScript(
        corePath: r'C:\Moryx VPN\ScaleGuard Mobile App\core\mihomo.exe',
        clientPath:
            r'C:\Moryx VPN\ScaleGuard Mobile App\ScaleGuard.exe',
        backupFilePath: '${temp.path}\\kill-switch.json',
      ),
      'tunnel': WindowsKillSwitch.tunnelScript(adapterName: 'ScaleGuard'),
      'verify': WindowsKillSwitch.verifyScript(),
      'disable': WindowsKillSwitch.disableScript(const <String, String>{
        'Domain': 'Allow',
        'Private': 'NotConfigured',
        'Public': 'Allow',
      }),
      'failsafe': WindowsKillSwitch.releaseScript(
        backupFilePath: '${temp.path}\\kill-switch.json',
      ),
    };

    var failures = 0;
    for (final entry in scripts.entries) {
      final file = File('${temp.path}\\${entry.key}.ps1');
      await file.writeAsBytes(<int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(entry.value),
      ]);
      final ok = await _parses(file.path);
      if (!ok) failures++;
      stdout.writeln('${ok ? 'parses ' : 'BROKEN '} ${entry.key}.ps1');
    }

    stdout.writeln('\n--- enable ---\n${scripts['enable']}');
    stdout.writeln('\n--- failsafe ---\n${scripts['failsafe']}');

    // Read-only, and the one part that can be exercised for real: it is the same
    // call the client makes to decide whether a failed enable left the machine
    // blocked.
    final killSwitch = WindowsKillSwitch();
    stdout.writeln(
      '\nfirewall blocking: ${await killSwitch.isBlocking()} '
      '(false is the expected answer on an idle machine)',
    );
    stdout.writeln('switch engaged: ${killSwitch.isActive}');

    if (failures > 0) {
      stderr.writeln('\n$failures script(s) do not parse.');
      exitCode = 1;
    } else {
      stdout.writeln('\nAll kill-switch scripts parse.');
    }
  } finally {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Asks PowerShell to parse a file, without running any of it.
Future<bool> _parses(String path) async {
  final checker = File('${File(path).parent.path}\\check.ps1');
  await checker.writeAsBytes(<int>[
    0xEF,
    0xBB,
    0xBF,
    ...utf8.encode('''
\$tokens = \$null
\$errors = \$null
[System.Management.Automation.Language.Parser]::ParseFile(
  '$path', [ref]\$tokens, [ref]\$errors) | Out-Null
if (\$errors.Count -gt 0) {
  foreach (\$error in \$errors) { 'ERROR: ' + \$error.Message }
  exit 1
}
'ok'
'''),
  ]);
  final result = await Process.run('powershell.exe', <String>[
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    checker.path,
  ]);
  final output = '${result.stdout}\n${result.stderr}'.trim();
  if (result.exitCode != 0 || !output.contains('ok')) {
    stderr.writeln('  $output');
    return false;
  }
  return true;
}
