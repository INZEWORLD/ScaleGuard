// Development harness: exercises the pieces of the VPN core that must work on
// the host before the full application is built.
//
//   dart run tool/smoke_core.dart
//
// It never touches the user's subscription: the sample profile below is a
// synthetic VLESS-Reality-Vision node used only to validate config generation
// and the Windows system-proxy switch.
import 'dart:convert';
import 'dart:io';

import 'package:scaleguard_mobile/core/engines/windows_vpn_engine.dart';
import 'package:scaleguard_mobile/core/mihomo_config.dart';
import 'package:scaleguard_mobile/core/subscription_parser.dart';
import 'package:scaleguard_mobile/core/vpn_engine.dart';
import 'package:scaleguard_mobile/core/windows_system_proxy.dart';

Future<void> main(List<String> args) async {
  _section('1. Subscription parser');
  _checkParser();

  _section('2. mihomo config generation');
  final servers = _sampleServers();
  final config = MihomoConfigBuilder().build(
    MihomoConfigOptions(
      servers: servers,
      mixedPort: 17890,
      controllerPort: 19090,
      secret: 'smoke-secret',
      mode: VpnTunnelMode.tun,
      cacheDir: Directory.systemTemp.path,
    ),
  );
  print(config);
  if (!config.contains('reality-opts')) {
    throw StateError('Reality options missing from the generated profile');
  }

  _section('3. Windows system proxy');
  if (!Platform.isWindows) {
    print('skipped (not Windows)');
    return;
  }
  final proxy = WindowsSystemProxy();
  final before = await proxy.capture();
  print('captured: $before');
  if (before == null) {
    print('capture failed: ${proxy.lastError}');
  }
  final state = await proxy.readState();
  print('current state: enabled=${state.enabled} server=${state.server}');

  if (args.contains('--apply-proxy')) {
    await proxy.apply(port: 17890);
    final applied = await proxy.readState();
    print('after apply: enabled=${applied.enabled} server=${applied.server}');
    await proxy.restore();
    final restored = await proxy.readState();
    print('after restore: enabled=${restored.enabled} server=${restored.server}');
  } else {
    print('(pass --apply-proxy to exercise the actual switch)');
  }

  _section('4. mihomo controller round-trip');
  await _controllerRoundTrip();

  _section('5. Windows engine end-to-end');
  if (args.contains('--engine')) {
    await _engineRoundTrip();
  } else {
    print('(pass --engine to exercise the real WindowsVpnEngine)');
  }
}

/// Drives the real [WindowsVpnEngine] the way the UI does: start the bundled
/// core, ask for the API version, sweep latencies, read counters, switch
/// selection, then stop and confirm the system proxy was restored.
Future<void> _engineRoundTrip() async {
  final engine = WindowsVpnEngine();
  final states = <String>[];
  final subscription = engine.changes.listen(
    (snapshot) => states.add('${snapshot.state.name}:${snapshot.message ?? ""}'),
  );

  final servers = _sampleServers();
  // A synthetic node never answers, so latency is expected to be "dead"; the
  // point of the run is to prove the plumbing, not the network.
  try {
    await engine.initialize();
    print('platform: ${engine.platformName}');
    print('supports TUN: ${engine.supportsTunMode}');
    await engine.start(
      EngineStartOptions(
        servers: servers,
        mode: VpnTunnelMode.systemProxy,
        autoSelectIntervalSeconds: 0,
      ),
    );
    print('state: ${engine.snapshot.state.name}');
    print('core version: ${engine.snapshot.coreVersion}');
    print('mixed port: ${engine.snapshot.mixedPort}');

    final health = await engine.measureAllServers();
    print('latency sweep -> ${health.map((h) => "${h.name}=${h.delayMs}").join(", ")}');

    await Future<void>.delayed(const Duration(seconds: 3));
    final traffic = engine.traffic;
    print(
      'traffic: down=${traffic.downloadBps}B/s up=${traffic.uploadBps}B/s '
      'total=${traffic.downloadTotalBytes + traffic.uploadTotalBytes}B '
      'connections=${traffic.activeConnections}',
    );

    final active = await engine.activeProxy();
    print('active proxy: $active');
    await engine.selectProxy(servers.first.proxy['name'] as String);
    print('after manual select: ${await engine.activeProxy()}');

    await engine.stop();
    print('after stop: ${engine.snapshot.state.name}');
    print('state transitions: ${states.join(" -> ")}');
  } finally {
    await subscription.cancel();
    await engine.dispose();
  }
}

List<ParsedVpnServer> _sampleServers() {
  // A synthetic Reality node: same field set Remnawave emits for
  // VLESS-Reality-Vision, with placeholder credentials.
  const link =
      'vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443'
      '?security=reality&sni=www.microsoft.com&fp=chrome'
      '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      '&sid=0123456789abcdef&type=tcp&flow=xtls-rprx-vision'
      '#%F0%9F%87%A9%F0%9F%87%AA%20Germany%20%7C%20Test';
  return parseSubscriptionBody(link);
}

void _checkParser() {
  // base64 of two share links, as Remnawave returns for unknown clients
  const links = '''
vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?security=reality&sni=www.microsoft.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&type=tcp&flow=xtls-rprx-vision#DE%20Node
trojan://secret@203.0.113.11:8443?sni=example.com&type=ws&path=%2Fws#NL%20Node
ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@203.0.113.12:8388#SS%20Node
''';
  final base64Body = base64.encode(utf8.encode(links));
  final parsed = parseSubscriptionBody(base64Body);
  print('base64 links -> ${parsed.length} servers');
  for (final server in parsed) {
    print(
      '  ${server.protocol.padRight(8)} ${server.endpoint.padRight(22)} '
      'country=${server.countryCode ?? "-"} remark=${server.remark}',
    );
  }
  if (parsed.length != 3) {
    throw StateError('expected 3 servers from base64 links, got ${parsed.length}');
  }

  const yaml = '''
proxies:
  - name: "JP Node"
    type: vless
    server: 203.0.113.20
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.microsoft.com
    client-fingerprint: chrome
    reality-opts:
      public-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      short-id: 0123456789abcdef
  - name: "US Node"
    type: trojan
    server: 203.0.113.21
    port: 8443
    password: secret
    sni: example.com
    skip-cert-verify: true
proxy-groups:
  - name: AUTO
    type: url-test
    proxies: ["JP Node", "US Node"]
rules:
  - MATCH,AUTO
''';
  final fromYaml = parseSubscriptionBody(yaml);
  print('mihomo yaml -> ${fromYaml.length} servers (body ${yaml.length} chars)');
  for (final server in fromYaml) {
    print('  ${server.protocol.padRight(8)} ${server.endpoint} '
        'reality=${server.proxy['reality-opts'] != null}');
  }
  if (fromYaml.length != 2) {
    throw StateError('expected 2 servers from YAML, got ${fromYaml.length}');
  }
  if (fromYaml.first.proxy['reality-opts'] == null) {
    throw StateError('reality-opts were not carried over from YAML');
  }

  const xrayJson = '''
{"outbounds":[
 {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"203.0.113.30","port":443,"users":[{"id":"11111111-2222-3333-4444-555555555555","flow":"xtls-rprx-vision","encryption":"none"}]}]},
  "streamSettings":{"network":"raw","security":"reality","realitySettings":{"serverNames":["www.microsoft.com"],"publicKey":"AAAA","shortIds":["0123456789abcdef"],"fingerprint":"chrome"}}},
 {"tag":"direct","protocol":"freedom","settings":{}}
]}''';
  final fromJson = parseSubscriptionBody(xrayJson);
  print('xray json -> ${fromJson.length} servers');
  for (final server in fromJson) {
    print('  ${server.protocol.padRight(8)} ${server.endpoint} '
        'network=${server.proxy['network']} flow=${server.proxy['flow']} '
        'reality=${server.proxy['reality-opts']}');
  }
  if (fromJson.length != 1) {
    throw StateError('expected 1 server from Xray JSON, got ${fromJson.length}');
  }
  if (fromJson.first.proxy['network'] != 'tcp') {
    throw StateError('Xray "raw" transport must map to mihomo "tcp"');
  }
}

Future<void> _controllerRoundTrip() async {
  final exe = File('windows/runner/mihomo.exe');
  if (!exe.existsSync()) {
    print('mihomo.exe not found at ${exe.path}; skipping');
    return;
  }
  final workDir = Directory.systemTemp.createTempSync('sg-core-smoke');
  final configFile = File('${workDir.path}/config.yaml');
  configFile.writeAsStringSync(
    MihomoConfigBuilder().build(
      MihomoConfigOptions(
        servers: _sampleServers(),
        mixedPort: 17891,
        controllerPort: 19091,
        secret: 'smoke-secret',
        mode: VpnTunnelMode.systemProxy,
      ),
    ),
  );

  final process = await Process.start(exe.absolute.path, [
    '-config',
    configFile.path,
    '-controller',
    '127.0.0.1:19091',
    '-secret',
    'smoke-secret',
    '-log-level',
    'info',
  ], workingDirectory: Directory.current.path);

  final logs = <String>[];
  process.stdout.transform(utf8.decoder).listen(logs.add);
  process.stderr.transform(utf8.decoder).listen(logs.add);

  // The Dart client lives in the app; this harness speaks the same protocol
  // directly so a failure here cannot be caused by app-level plumbing.
  final client = HttpClient();
  Future<String?> get(String path) async {
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:19091$path'),
      );
      request.headers.set('Authorization', 'Bearer smoke-secret');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return response.statusCode == 200 ? body : null;
    } catch (_) {
      return null;
    }
  }

  try {
    String? version;
    for (var attempt = 0; attempt < 40; attempt++) {
      version = await get('/version');
      if (version != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    print('controller /version -> $version');

    final proxies = await get('/proxies');
    if (proxies != null) {
      final decoded = jsonDecode(proxies) as Map<String, dynamic>;
      final names = (decoded['proxies'] as Map).keys.take(8).join(', ');
      print('proxies -> $names');
    }

    final connections = await get('/connections');
    print(
      'connections -> ${connections == null ? "unavailable" : connections.substring(0, connections.length.clamp(0, 120))}',
    );
  } finally {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    try {
      workDir.deleteSync(recursive: true);
    } catch (_) {}
    print('core log tail: ${logs.takeLast(3).join(" | ")}');
  }
}

void _section(String title) {
  print('\n=== $title ===');
}

extension<T> on Iterable<T> {
  Iterable<T> takeLast(int count) {
    final list = toList();
    return list.length <= count ? list : list.sublist(list.length - count);
  }
}
