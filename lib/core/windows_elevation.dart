import 'dart:convert';
import 'dart:io';

/// Windows administrator (elevation) helpers.
///
/// TUN mode creates a virtual adapter, which Windows only allows for a process
/// holding an elevated token. Both the launcher (`main.dart`) and the UI need to
/// ask the same question — "am I allowed to do this right now?" — and the answer
/// has to come from the same place so the switch in the settings screen, the
/// dialog on the home screen and the engine's own permission check never
/// disagree.

/// Whether the current process already runs with an elevated (administrator)
/// token.
///
/// Returns `true` on platforms that have no concept of elevation, so callers can
/// treat "no elevation needed" and "already elevated" identically.
Future<bool> isProcessElevated() async {
  if (!Platform.isWindows) return true;
  final file = await _writeScript('sg-elev-check.ps1', r'''
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) { '1' } else { '0' }
''');
  if (file == null) return false;
  try {
    final result = await _runPowerShell(file);
    return result.stdout.toString().trim() == '1';
  } finally {
    await _deleteQuietly(file);
  }
}

/// The argument a copy started with administrator rights carries.
///
/// A replacement is identified by its elevated token, which is supposed to be
/// enough. The marker covers the case where Windows reports a successful
/// elevation, starts nothing, and the launcher — believing the answer — tries
/// again: with the marker present the replacement never relaunches itself, so a
/// launch can never turn into a loop of processes that all exit immediately.
const String kElevatedArgument = '--elevated';

/// Starts an elevated copy of this executable and returns whether Windows
/// accepted the request.
///
/// Windows shows its own UAC prompt; a `false` result means the user declined it
/// (or the shell could not start the process), and the caller should carry on
/// unelevated rather than pretend the restart happened.
Future<bool> relaunchElevated({List<String> arguments = const []}) async {
  if (!Platform.isWindows) return false;
  final executable = _psQuote(Platform.resolvedExecutable);
  final argumentList = arguments.isEmpty
      ? ''
      : ' -ArgumentList @(${arguments.map(_psQuote).join(', ')})';
  // The replacement is given the same working directory as this instance. An
  // elevated process started without one is started in `system32`, and a client
  // whose idea of "here" changes with how it was launched is a bug waiting for
  // the first relative path.
  final directory =
      _psQuote(File(Platform.resolvedExecutable).parent.path);
  final script = "\$ErrorActionPreference = 'Stop'\n"
      "Start-Process -FilePath $executable$argumentList -WorkingDirectory "
      "$directory -Verb RunAs\n"
      "Write-Output 'started'\n";
  final file = await _writeScript('sg-elev-run.ps1', script);
  if (file == null) return false;
  try {
    final result = await _runPowerShell(file);
    return result.exitCode == 0 &&
        result.stdout.toString().contains('started');
  } finally {
    await _deleteQuietly(file);
  }
}

/// Starts an unelevated copy of this executable.
///
/// Windows hands a child its parent's token, so restarting from an elevated
/// window produces an elevated window — which is why turning "run as
/// administrator" off used to change nothing at all. Explorer runs with the
/// logged-in user's standard token, so asking it to open the executable is the
/// same path the Start menu takes.
Future<bool> relaunchAsStandardUser() async {
  if (!Platform.isWindows) return false;
  try {
    await Process.start(
      'explorer.exe',
      [Platform.resolvedExecutable],
      mode: ProcessStartMode.detached,
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// Restarts this executable as administrator and terminates the current
/// process, so exactly one instance (the elevated one) survives.
///
/// The caller is responsible for releasing the single-instance handshake port
/// first: otherwise the elevated copy would find the port taken, treat itself as
/// a duplicate and exit immediately.
Future<bool> restartAsAdministrator({List<String> arguments = const []}) async {
  if (!await relaunchElevated(arguments: arguments)) return false;
  exit(0);
}

Future<File?> _writeScript(String name, String script) async {
  try {
    final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}$name');
    // A UTF-8 BOM keeps Windows PowerShell from mangling the output of scripts
    // that contain non-ASCII characters.
    await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
    return file;
  } catch (_) {
    return null;
  }
}

Future<ProcessResult> _runPowerShell(File script) => Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
    ]);

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } catch (_) {
    // A leftover script in %TEMP% is harmless.
  }
}

/// Single-quotes a value for PowerShell, doubling any embedded quote.
String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";
