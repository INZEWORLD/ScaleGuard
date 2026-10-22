// End-to-end harness for the Windows VPN path.
//
// It answers the question static analysis cannot: does the application really
// get traffic through the core after the user presses "connect"?
//
//   dart run tool/e2e_tunnel.dart [--keep-log]
//
// The harness stands up three local pieces and then drives the *real*
// [WindowsVpnEngine] against them:
//
//   1. a SOCKS5 server that forwards TCP — the "VPN node" the core will dial;
//   2. an HTTP server that mocks the few website API endpoints the connect flow
//      touches (`/api/auth/config`, `/api/auth/login`, `/api/profile`, …);
//   3. a subscription endpoint that advertises that node as a base64 share-link,
//      which is what Remnawave returns for clients it does not recognise.
//
// A successful run proves the whole chain: subscription download -> real parser
// -> profile generation -> core startup -> node selection -> system proxy switch
// -> bytes flowing through the core -> traffic counters moving -> clean restore.
//
// Everything binds to loopback on ephemeral ports, so the harness never touches
// the network and never conflicts with a running VPN client.
import 'dart:convert';
import 'dart:io';

import 'package:scaleguard_mobile/core/engines/windows_vpn_engine.dart';
import 'package:scaleguard_mobile/core/vpn_engine.dart';
import 'package:scaleguard_mobile/core/windows_system_proxy.dart';

import 'test_doubles.dart';

int _failed = 0;

/// Target used to prove that bytes really traverse the tunnel.
///
/// The node rewrites this host to the local mock server, so the assertion is
/// fully offline: it proves that a request entered the core, left it through the
/// selected proxy, and came back — without depending on the machine being able
/// to reach the public internet (which it often cannot while another VPN client
/// owns the tunnel).
const String _probeHost = 'tunnel-probe.scaleguard.test';
const int _probeStatus = 204;

Future<void> main(List<String> args) async {
  final keepLog = args.contains('--keep-log');

  _section('End-to-end tunnel test');

  final node = await Socks5Node.start();
  print('node:      127.0.0.1:${node.port} (SOCKS5, both auth modes accepted)');

  final api = await MockApi.start(node.port);
  print('mock api:  ${api.baseUrl}');
  print('subscribe: ${api.subscriptionUrl}');

  // The probe host only exists inside this test: the node forwards it to the
  // mock server, which answers 204. The rewrite is keyed by `host:port`, which is
  // what the node sees in the SOCKS5 CONNECT request.
  final probeUrl = 'http://$_probeHost/probe';
  node.rewriteRules['$_probeHost:80'] = '127.0.0.1:${api.port}';
  print('probe:     $probeUrl -> 127.0.0.1:${api.port}');

  final proxy = WindowsSystemProxy();
  final proxyBefore = await proxy.readState();
  print('proxy before: enabled=${proxyBefore.enabled} server=${proxyBefore.server}');

  final engine = WindowsVpnEngine(systemProxy: proxy);
  final states = <String>[];
  final statesSubscription =
      engine.changes.listen((snapshot) => states.add(snapshot.state.name));

  try {
    // The profile the application would receive from the website API.
    final servers = await api.fetchServers();
    print('parsed from subscription: ${servers.length}');
    for (final server in servers) {
      print('  ${server.protocol} ${server.endpoint} ${server.remark}');
    }
    _check('subscription parsed into a usable node', servers.isNotEmpty);
    if (servers.isEmpty) return;

    await engine.initialize().timeout(const Duration(seconds: 30));
    await engine
        .start(
          EngineStartOptions(
            servers: servers,
            mode: VpnTunnelMode.systemProxy,
            logLevel: keepLog ? 'debug' : 'warning',
            autoSelectIntervalSeconds: 10,
          ),
        )
        .timeout(const Duration(seconds: 60));
    _check('core reported running', engine.snapshot.state == CoreState.running);
    print('core version: ${engine.snapshot.coreVersion}');
    print('mixed port:   ${engine.snapshot.mixedPort}');

    final health = await engine.measureAllServers();
    print('latency sweep: ${health.map((e) => "${e.name}=${e.delayMs}ms").join(", ")}');
    _check(
      'node answers the latency probe through the core',
      health.any((entry) => entry.isReachable),
    );

    final active = await engine.activeProxy();
    print('active proxy: $active');
    _check('core selected a node', active != null && active.isNotEmpty);

    final mixedPort = engine.snapshot.mixedPort!;
    final fetched = await _fetchThroughProxy(mixedPort, probeUrl, _probeStatus);
    _check('probe endpoint reached through the tunnel', fetched != null);
    _check('the node forwarded a connection', node.forwarded > 0);
    print('node destinations: ${node.destinations.join(", ")}');
    _check(
      'the request arrived at the node for the requested host',
      node.destinations.any((entry) => entry.startsWith(_probeHost)),
    );

    // Let the one-second counter poll observe the transfer.
    await Future<void>.delayed(const Duration(seconds: 3));
    final traffic = engine.traffic;
    print(
      'counters: down=${traffic.downloadBps}B/s up=${traffic.uploadBps}B/s '
      'total=${traffic.downloadTotalBytes + traffic.uploadTotalBytes}B '
      'connections=${traffic.activeConnections}',
    );
    _check(
      'traffic counters moved',
      traffic.downloadTotalBytes + traffic.uploadTotalBytes > 0,
    );

    final proxyDuring = await proxy.readState();
    print('proxy during: enabled=${proxyDuring.enabled} server=${proxyDuring.server}');
    _check(
      'system proxy points at the core',
      proxyDuring.enabled && proxyDuring.server.contains('$mixedPort'),
    );

    final firstName = servers.first.proxy['name'] as String;
    await engine.selectProxy(firstName);
    _check('manual selection applied', await engine.activeProxy() == firstName);

    await engine.stop();
    _check('engine stopped', engine.snapshot.state == CoreState.idle);
  } catch (error, stack) {
    _failed++;
    print('EXCEPTION: $error');
    print(stack);
  } finally {
    await statesSubscription.cancel();

    // The core's log is the only place that explains a refused connection, so its
    // tail is printed whenever the run was asked to keep it or something failed.
    if (keepLog || _failed > 0) {
      final log = engine.coreLog;
      if (log.isNotEmpty) {
        _section('core log (tail)');
        for (final line in log.length > 30 ? log.sublist(log.length - 30) : log) {
          print('  $line');
        }
      }
    }

    await engine.dispose();
    await api.stop();
    await node.stop();

    final proxyAfter = await proxy.readState();
    print('proxy after:  enabled=${proxyAfter.enabled} server=${proxyAfter.server}');
    _check(
      'system proxy restored to its original value',
      proxyAfter.enabled == proxyBefore.enabled &&
          proxyAfter.server == proxyBefore.server,
    );
    print('state transitions: ${states.toSet().join(" -> ")}');
  }

  _section(_failed == 0 ? 'PASSED' : 'FAILED ($_failed)');
  // An accepted socket may keep the VM alive after `main` returns; this is a
  // script, so it exits explicitly.
  exit(_failed == 0 ? 0 : 1);
}

void _check(String what, bool ok) {
  print('${ok ? "  ok  " : " FAIL "} $what');
  if (!ok) _failed++;
}

void _section(String title) => print('\n=== $title ===');

/// Fetches a URL through the core's mixed HTTP/SOCKS port.
///
/// Returns the response body when the status matches [expectedStatus] and `null`
/// otherwise. An empty body is a valid answer (`generate_204`), so callers check
/// for `null` rather than for emptiness.
Future<String?> _fetchThroughProxy(
  int mixedPort,
  String url,
  int expectedStatus,
) async {
  final client = HttpClient();
  // `findProxy` sends the request to the local core, exactly as a browser
  // configured with the Windows system proxy does.
  client.findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';
  client.connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 20));
    final body = await response.transform(utf8.decoder).join();
    return response.statusCode == expectedStatus ? body : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
