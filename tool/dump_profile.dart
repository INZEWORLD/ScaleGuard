// Dumps the generated profile for a live subscription.
//
//   dart run tool/dump_profile.dart <subscription-url> [line]
//
// When the core rejects a profile, the only useful artefact is the profile
// itself next to the parser's complaint, so this tool writes it out and prints
// the neighbourhood of the offending line.
import 'dart:io';

import 'package:scaleguard_mobile/core/device_identity.dart';
import 'package:scaleguard_mobile/core/mihomo_config.dart';
import 'package:scaleguard_mobile/core/subscription_parser.dart';
import 'package:scaleguard_mobile/core/vpn_engine.dart';

import 'src/subscription_client.dart';

Future<void> main(List<String> args) async {
  final url = args.firstWhere((arg) => arg.startsWith('http'), orElse: () => '');
  if (url.isEmpty) {
    stderr.writeln('usage: dart run tool/dump_profile.dart <url> [line]');
    exit(2);
  }
  final focusLine = args
      .map(int.tryParse)
      .firstWhere((value) => value != null, orElse: () => null);

  final device = await resolveDeviceIdentity(
    readStored: () async => null,
    writeStored: (_) async {},
  );
  final download = await fetchSubscription(url, device: device);
  final servers = parseSubscriptionBody(download.body);

  final config = MihomoConfigBuilder().build(
    MihomoConfigOptions(
      servers: servers,
      mixedPort: 17890,
      controllerPort: 19090,
      secret: 'dump',
      mode: VpnTunnelMode.systemProxy,
    ),
  );

  final file = File('build/live-profile.yaml');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(config);
  print('written: ${file.absolute.path} (${config.length} bytes, '
      '${servers.length} servers)');

  final lines = config.split('\n');
  if (focusLine != null) {
    final start = (focusLine - 8).clamp(0, lines.length - 1);
    final end = (focusLine + 8).clamp(0, lines.length - 1);
    print('\n--- lines ${start + 1}..${end + 1} ---');
    for (var i = start; i <= end; i++) {
      print('${(i + 1).toString().padLeft(4)} | ${lines[i]}');
    }
  } else {
    print('\n--- full profile ---');
    for (var i = 0; i < lines.length; i++) {
      print('${(i + 1).toString().padLeft(4)} | ${lines[i]}');
    }
  }
  exit(0);
}
