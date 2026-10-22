// Regenerates the integrity manifest that ships next to the core.
//
//   dart run tool/write_core_manifest.dart
//
// Run this after replacing `windows/runner/mihomo.exe` (or `wintun.dll`) and
// commit the refreshed `SHA256SUMS` together with the binary: the client checks
// the digests before it starts the core with an administrator token, so a stale
// manifest turns into a blocking error.
import 'dart:io';

import 'package:scaleguard_mobile/core/binary_integrity.dart';

Future<void> main() async {
  final scriptDirectory = File(Platform.script.toFilePath()).parent;
  final runnerDirectory = Directory(
    '${scriptDirectory.parent.path}${Platform.pathSeparator}windows'
    '${Platform.pathSeparator}runner',
  );

  final separators = Platform.pathSeparator;
  final files = <File>[
    File('${runnerDirectory.path}${separators}mihomo.exe'),
    File('${runnerDirectory.path}${separators}wintun.dll'),
  ];

  final manifest = await BinaryIntegrity.buildManifest(files);
  if (manifest.isEmpty) {
    stderr.writeln('Нечего проверять: бинарники не найдены в '
        '${runnerDirectory.path}');
    exitCode = 1;
    return;
  }

  final target = File(
    '${runnerDirectory.path}${separators}${BinaryIntegrity.manifestName}',
  );
  await target.writeAsString('$manifest\n', flush: true);
  stdout.writeln('Записано: ${target.path}');
  stdout.writeln(manifest);
}
