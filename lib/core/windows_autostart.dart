import 'dart:io';

import 'powershell.dart';

/// Adds and removes the application from the per-user Windows startup list.
///
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` is used rather than a
/// scheduled task or a shortcut in the Startup folder: it needs no elevation,
/// it is trivially reversible, and the user can also see and undo it from Task
/// Manager's startup tab — which matters for a client that asks for
/// administrator rights.
class WindowsAutostart {
  WindowsAutostart();

  static const String _runKey =
      r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';

  /// Value name; also what Task Manager shows in its startup list.
  static const String entryName = 'ScaleGuard';

  String? _lastError;

  /// Diagnostic detail from the most recent failed call.
  String? get lastError => _lastError;

  bool get isSupported => Platform.isWindows;

  /// Whether the entry exists. A registered entry pointing at another copy of
  /// the executable is still reported as enabled, because the user did turn
  /// autostart on — [registeredCommand] exposes the target when it matters.
  Future<bool> isEnabled() async {
    if (!isSupported) return false;
    final result = await runPowerShell('''
\$value = (Get-ItemProperty -Path '$_runKey' -Name '$entryName' -ErrorAction SilentlyContinue).'$entryName'
if ([string]::IsNullOrWhiteSpace(\$value)) { 'absent' } else { "present|\$value" }
''');
    if (!result.ok) {
      _lastError = result.diagnostic;
      return false;
    }
    _lastError = null;
    return result.stdout.contains('present|');
  }

  /// The command line currently registered, if any.
  Future<String?> registeredCommand() async {
    if (!isSupported) return null;
    final result = await runPowerShell('''
\$value = (Get-ItemProperty -Path '$_runKey' -Name '$entryName' -ErrorAction SilentlyContinue).'$entryName'
if ([string]::IsNullOrWhiteSpace(\$value)) { '' } else { \$value }
''');
    if (!result.ok) {
      _lastError = result.diagnostic;
      return null;
    }
    final value = result.firstLine;
    return value.isEmpty ? null : value;
  }

  /// Registers [executablePath] to start with the session.
  Future<bool> enable({required String executablePath}) async {
    if (!isSupported) return false;
    if (!File(executablePath).existsSync()) {
      _lastError = 'Не найден исполняемый файл: $executablePath';
      return false;
    }
    // The path is quoted because a user profile directory routinely contains
    // spaces, and `Run` values are parsed as command lines.
    final command = '"${_psQuote(executablePath)}"';
    final result = await runPowerShell('''
Set-ItemProperty -Path '$_runKey' -Name '$entryName' -Value '$command' -Type String
'ok'
''');
    if (!result.ok || !result.stdout.contains('ok')) {
      _lastError = result.diagnostic;
      return false;
    }
    _lastError = null;
    return true;
  }

  /// Removes the entry. Succeeds when there was nothing to remove.
  Future<bool> disable() async {
    if (!isSupported) return false;
    final result = await runPowerShell('''
Remove-ItemProperty -Path '$_runKey' -Name '$entryName' -ErrorAction SilentlyContinue
'ok'
''');
    if (!result.ok) {
      _lastError = result.diagnostic;
      return false;
    }
    _lastError = null;
    return true;
  }

  String _psQuote(String value) => value.replaceAll("'", "''");
}
