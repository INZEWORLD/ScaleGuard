import 'dart:async';
import 'dart:io';

import 'package:scaleguard_mobile/core/windows_deep_link.dart';

/// Verifies the Windows single-instance handshake without opening any window:
/// run as `primary`, it claims port 45973, spawns itself as `secondary` with a
/// fake `scaleguard://` URL and expects the URL to arrive on
/// [WindowsSingleInstanceGate.incomingLinks]. Run as `secondary`, it must
/// fail to claim the port and forward the URL instead.
Future<void> main(List<String> args) async {
  final mode = args.first;
  if (mode == 'primary') {
    final claimed = await WindowsSingleInstanceGate.start(const []);
    if (!claimed) {
      stderr.writeln('PORT_BUSY (is the real application running?)');
      exit(2);
    }
    final sub = WindowsSingleInstanceGate.incomingLinks.listen((raw) {
      stdout.writeln('RECEIVED:$raw');
      exit(0);
    });
    final secondary = await Process.run(
      Platform.executable,
      [
        'run',
        'tool/single_instance_smoke.dart',
        'secondary',
        'scaleguard://oauth?oauth_token=TESTTOKEN',
      ],
    );
    stdout.writeln('secondary exit: ${secondary.exitCode}');
    stdout.writeln('secondary out: ${(secondary.stdout as String).trim()}');
    await Future<void>.delayed(const Duration(seconds: 5));
    stderr.writeln('TIMEOUT: no link arrived');
    sub.cancel();
    exit(3);
  }
  final claimed = await WindowsSingleInstanceGate.start([
    if (args.length > 1) args[1],
  ]);
  stdout.writeln(claimed ? 'UNEXPECTED_PRIMARY' : 'FORWARDED_AND_EXITING');
  exit(claimed ? 1 : 0);
}
