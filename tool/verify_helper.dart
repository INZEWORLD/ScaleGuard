// Registers the helper task's own XML and starts it, to prove the definition is
// something Windows accepts.
//
// The task the client registers runs with the *highest* rights, and registering
// that needs the elevation this session does not have — so the run level is
// lowered here and the command is swapped for one that leaves a trace. What is
// being checked is the part that would make the helper silently useless: the XML
// schema, the UTF-16 encoding `schtasks /xml` expects, and the fact that a task
// with no triggers can be started on demand (a *disabled* one cannot, which is
// the trap this design avoids).
//
//   dart run tool/verify_helper.dart
import 'dart:io';

import 'package:scaleguard_mobile/core/windows_helper.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('Windows only.');
    return;
  }

  final dir = await Directory.systemTemp.createTemp('sg-helper-verify');
  final marker = File('${dir.path}\\started.txt');
  final xmlFile = File('${dir.path}\\task.xml');
  var created = false;
  try {
    final userId = await _currentUser();
    stdout.writeln('user: $userId');

    // The real definition, with the two changes this session cannot avoid.
    final xml = WindowsHelper.taskXml(
          userId: userId,
          executable: Platform.resolvedExecutable,
        )
        .replaceAll('<RunLevel>HighestAvailable</RunLevel>',
            '<RunLevel>LeastPrivilege</RunLevel>')
        .replaceAll(
          '<Command>${_xmlEscape(Platform.resolvedExecutable)}</Command>',
          '<Command>cmd.exe</Command>\n'
              '      <Arguments>/c echo helper-ok &gt; "${marker.path}"'
              '</Arguments>',
        );
    await xmlFile.writeAsBytes(_utf16Le(xml), flush: true);

    final create = await Process.run(
      'schtasks',
      <String>['/create', '/f', '/tn', WindowsHelper.taskName, '/xml', xmlFile.path],
    );
    created = create.exitCode == 0;
    stdout.writeln('register: ${created ? 'accepted' : 'REFUSED'}');
    if (!created) {
      stderr.writeln('${create.stdout}\n${create.stderr}');
    }

    final run = await Process.run(
      'schtasks',
      <String>['/run', '/tn', WindowsHelper.taskName],
    );
    stdout.writeln('start:   ${run.exitCode == 0 ? 'accepted' : 'REFUSED'}');
    if (run.exitCode != 0) stderr.writeln('${run.stdout}\n${run.stderr}');

    await Future<void>.delayed(const Duration(seconds: 3));
    final ran = marker.existsSync();
    stdout.writeln('ran:     $ran');
    if (ran) stdout.writeln('         ${marker.readAsStringSync().trim()}');

    stdout.writeln(created && run.exitCode == 0 && ran
        ? '\nHelper task definition works.'
        : '\nHelper task definition does NOT work.');
    if (!(created && run.exitCode == 0 && ran)) exitCode = 1;
  } finally {
    if (created) {
      await Process.run(
        'schtasks',
        <String>['/delete', '/f', '/tn', WindowsHelper.taskName],
      );
    }
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Future<String> _currentUser() async {
  final result = await Process.run('powershell.exe', <String>[
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    r'[System.Security.Principal.WindowsIdentity]::GetCurrent().Name',
  ]);
  return '${result.stdout}'.trim();
}

List<int> _utf16Le(String text) {
  final bytes = <int>[0xFF, 0xFE];
  for (final unit in text.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add((unit >> 8) & 0xFF);
  }
  return bytes;
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
