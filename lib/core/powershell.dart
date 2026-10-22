import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Outcome of a PowerShell invocation.
class PowerShellResult {
  const PowerShellResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.error,
  });

  const PowerShellResult.failed(String message)
      : exitCode = -1,
        stdout = '',
        stderr = '',
        error = message;

  final int exitCode;
  final String stdout;
  final String stderr;

  /// Set when the process could not be started at all.
  final String? error;

  bool get ok => error == null && exitCode == 0;

  /// First non-empty line of the output, which is how the callers hand back a
  /// single token.
  String get firstLine {
    for (final line in stdout.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }

  String get diagnostic => error ?? (stderr.trim().isNotEmpty
      ? stderr.trim()
      : 'powershell exit $exitCode');
}

/// Runs a PowerShell script and returns its output.
///
/// `-EncodedCommand` is deliberately avoided: PowerShell decodes it as UTF-16LE
/// while Dart produces UTF-8, so any non-ASCII text in the script arrives
/// corrupted. Writing a BOM-prefixed UTF-8 file and running it with `-File`
/// keeps the round trip lossless, which matters because these scripts quote
/// user-facing strings and registry values.
Future<PowerShellResult> runPowerShell(
  String script, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (!Platform.isWindows) {
    return const PowerShellResult.failed('PowerShell доступен только в Windows');
  }
  Directory? directory;
  try {
    directory = await Directory.systemTemp.createTemp('scaleguard-ps');
    final file = File('${directory.path}${Platform.pathSeparator}script.ps1');
    await file.writeAsBytes(<int>[
      0xEF, 0xBB, 0xBF, // UTF-8 BOM
      ...utf8.encode(script),
    ]);

    final result = await Process.run(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        file.path,
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);

    return PowerShellResult(
      exitCode: result.exitCode,
      stdout: (result.stdout as String?) ?? '',
      stderr: (result.stderr as String?) ?? '',
    );
  } on TimeoutException {
    return PowerShellResult.failed('PowerShell не ответил за ${timeout.inSeconds} с');
  } catch (error) {
    return PowerShellResult.failed(error.toString());
  } finally {
    try {
      directory?.deleteSync(recursive: true);
    } catch (_) {
      // A leftover temp directory is not worth failing the call over.
    }
  }
}
