// Live subscription probe.
//
//   dart run tool/live_subscription.dart <subscription-url>
//
// It exercises the application's subscription code path — the same strategies,
// the same parser, the same HWID headers — against a deployed panel, which is
// the only way to catch a mismatch between what Remnawave serves and what the
// client expects.
//
// The most important thing it demonstrates: a panel with the device limit
// enabled answers **200 with an empty body** unless `x-hwid` is sent, so the
// comparison between the two runs below is the difference between "no servers"
// and a working subscription.
import 'dart:io';

import 'package:scaleguard_mobile/core/device_identity.dart';
import 'package:scaleguard_mobile/core/mihomo_config.dart';
import 'package:scaleguard_mobile/core/subscription_parser.dart';
import 'package:scaleguard_mobile/core/vpn_engine.dart';

import 'src/subscription_client.dart';

Future<void> main(List<String> args) async {
  final url = args.firstWhere((arg) => arg.startsWith('http'), orElse: () => '');
  if (url.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/live_subscription.dart <subscription-url>',
    );
    exit(2);
  }

  print('subscription: $url');
  print('mihomo form:  ${deriveMihomoSubscriptionUrl(url)}');

  final device = await resolveDeviceIdentity(
    readStored: () async => null,
    writeStored: (_) async {},
  );
  print('device:       $device');
  print('hwid headers: ${device.headers.keys.join(", ")}');

  var failures = 0;
  for (final withHwid in [false, true]) {
    print('\n=== ${withHwid ? "with x-hwid" : "without x-hwid"} ===');
    try {
      final download = await fetchSubscription(
        url,
        device: withHwid ? device : null,
      );
      print('  strategy: ${download.strategy}');
      print('  bytes:    ${download.body.length}');
      print('  userinfo: ${download.userInfo ?? "-"}');
      print('  title:    ${download.title ?? "-"}');

      final servers = parseSubscriptionBody(download.body);
      print('  servers:  ${servers.length}');
      for (final server in servers) {
        print('    ${server.protocol.padRight(9)} ${server.endpoint.padRight(24)} '
            '${server.remark}');
      }

      // The generated profile is what the core is handed, so a successful parse
      // is only half the evidence.
      final config = MihomoConfigBuilder().build(
        MihomoConfigOptions(
          servers: servers,
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'live-probe',
          mode: VpnTunnelMode.systemProxy,
        ),
      );
      print('  profile:  ${config.length} bytes, ${servers.length} proxies');
    } catch (error) {
      failures++;
      print('  FAILED: $error');
    }
  }

  print('\n${failures == 0 ? "PASSED" : "FAILED ($failures)"}');
  exit(failures == 0 ? 0 : 1);
}
