// Live tunnel test against a deployed Remnawave panel.
//
//   dart run tool/live_tunnel.dart <subscription-url> [--connect]
//
// It downloads the real subscription with the application's own code (including
// the HWID headers the panel requires), then drives the real [WindowsVpnEngine]
// with those servers: the core starts, every node is probed through the core's
// own stack, the fastest one is selected, and — with `--connect` — the Windows
// system proxy is switched to the core so a real HTTP request traverses a real
// server.
//
// Without `--connect` nothing on the machine is modified: it only reports what
// the panel serves and how each node performs, which is the safe default when
// pointing the tool at a production subscription.
import 'dart:convert';
import 'dart:io';

import 'package:scaleguard_mobile/core/device_identity.dart';
import 'package:scaleguard_mobile/core/engines/windows_vpn_engine.dart';
import 'package:scaleguard_mobile/core/mihomo_config.dart';
import 'package:scaleguard_mobile/core/subscription_parser.dart';
import 'package:scaleguard_mobile/core/vpn_engine.dart';
import 'package:scaleguard_mobile/core/windows_system_proxy.dart';

import 'src/subscription_client.dart';

int _failed = 0;

Future<void> main(List<String> args) async {
  final url = args.firstWhere(
    (arg) => arg.startsWith('http'),
    orElse: () => '',
  );
  if (url.isEmpty) {
    stderr.writeln('usage: dart run tool/live_tunnel.dart <url> [--connect]');
    exit(2);
  }
  final connect = args.contains('--connect');

  _section('Live subscription');
  final device = await resolveDeviceIdentity(
    readStored: () async => null,
    writeStored: (_) async {},
  );
  print('device: $device');

  final download = await fetchSubscription(url, device: device);
  print('strategy: ${download.strategy}');
  print('bytes:    ${download.body.length}');
  final servers = parseSubscriptionBody(download.body);
  print('servers:  ${servers.length}');
  for (final server in servers) {
    print('  ${server.protocol.padRight(9)} ${server.endpoint.padRight(24)} '
        '${server.remark}');
  }
  if (servers.isEmpty) {
    _section('FAILED: no servers in the subscription');
    exit(1);
  }

  _section('Core with the live profile');
  final proxy = WindowsSystemProxy();
  final proxyBefore = await proxy.readState();
  final engine = WindowsVpnEngine(systemProxy: proxy);
  final states = <String>[];
  final statesSubscription =
      engine.changes.listen((snapshot) => states.add(snapshot.state.name));

  try {
    await engine.initialize();
    await engine
        .start(
          EngineStartOptions(
            servers: servers,
            mode: VpnTunnelMode.systemProxy,
            logLevel: 'info',
            autoSelectIntervalSeconds: 30,
          ),
        )
        .timeout(const Duration(seconds: 60));
    _check('core started', engine.snapshot.state == CoreState.running);

    // Every node is probed through the core's own stack, which is what the app
    // shows in its server list.
    final health = await engine.measureAllServers();
    print('latency:');
    for (final entry in health) {
      final verdict = entry.isReachable ? '${entry.delayMs} ms' : 'unreachable';
      print('  ${entry.name.padRight(34)} $verdict');
    }
    final alive = health.where((entry) => entry.isReachable).toList();
    _check('at least one node is reachable', alive.isNotEmpty);
    if (alive.isNotEmpty) {
      alive.sort((a, b) => a.delayMs.compareTo(b.delayMs));
      print('fastest: ${alive.first.name} (${alive.first.delayMs} ms)');
    }

    if (connect && alive.isNotEmpty) {
      _section('Live traffic through the tunnel');
      final fastest = alive.first.name;
      await engine.selectProxy(fastest);
      _check('selected the fastest node', await engine.activeProxy() == fastest);

      final mixedPort = engine.snapshot.mixedPort!;
      final before = await proxy.readState();
      print('proxy during: enabled=${before.enabled} server=${before.server}');
      _check(
        'system proxy points at the core',
        before.enabled && before.server.contains('$mixedPort'),
      );

      // `identity` reflects the exit address, so a change proves the traffic left
      // through the VPN server rather than the local connection.
      final viaTunnel = await _httpGetThroughProxy(
        mixedPort,
        'https://api.ipify.org?format=json',
      );
      print('exit address via tunnel: ${viaTunnel ?? "unavailable"}');
      _check('a real request completed through the tunnel', viaTunnel != null);

      await Future<void>.delayed(const Duration(seconds: 3));
      final traffic = engine.traffic;
      print(
        'counters: total=${traffic.downloadTotalBytes + traffic.uploadTotalBytes}B '
        'down=${traffic.downloadBps}B/s up=${traffic.uploadBps}B/s',
      );
      _check(
        'traffic counters moved',
        traffic.downloadTotalBytes + traffic.uploadTotalBytes > 0,
      );
    } else if (!connect) {
      print('\n(pass --connect to also route real traffic through the tunnel)');
    }

    await engine.stop();
  } catch (error, stack) {
    _failed++;
    print('EXCEPTION: $error');
    print(stack);
  } finally {
    await statesSubscription.cancel();
    if (_failed > 0) {
      _section('core log (tail)');
      final log = engine.coreLog;
      for (final line in log.length > 25 ? log.sublist(log.length - 25) : log) {
        print('  $line');
      }
    }
    await engine.dispose();

    final proxyAfter = await proxy.readState();
    _check(
      'system proxy restored',
      proxyAfter.enabled == proxyBefore.enabled &&
          proxyAfter.server == proxyBefore.server,
    );
    print('state transitions: ${states.toSet().join(" -> ")}');
  }

  _section(_failed == 0 ? 'PASSED' : 'FAILED ($_failed)');
  exit(_failed == 0 ? 0 : 1);
}

void _check(String what, bool ok) {
  print('${ok ? "  ok  " : " FAIL "} $what');
  if (!ok) _failed++;
}

void _section(String title) => print('\n=== $title ===');

Future<String?> _httpGetThroughProxy(int mixedPort, String url) async {
  final client = HttpClient();
  client.findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';
  client.connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 25));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) return null;
    final match = RegExp(r'"ip"\s*:\s*"([^"]+)"').firstMatch(body);
    return match?.group(1) ?? body;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
