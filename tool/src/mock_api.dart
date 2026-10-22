import 'dart:convert';
import 'dart:io';

import 'package:scaleguard_mobile/core/subscription_parser.dart';

import 'socks5_node.dart';

/// Mocks the website API surface the connect flow uses.
///
/// Only the endpoints the application actually calls before and during a
/// connection are implemented; anything else answers 404 so a missing mock shows
/// up as a clear failure instead of a silent empty response.
class MockApi {
  MockApi._(this._server, this.nodePort);

  final HttpServer _server;
  final int nodePort;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  String get subscriptionUrl => '$baseUrl/sub';

  /// Port the mock listens on, so a test node can forward a probe host to it.
  int get port => _server.port;

  static Future<MockApi> start(int nodePort) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = MockApi._(server, nodePort);
    server.listen(api._handle);
    return api;
  }

  /// The base64 share-link payload Remnawave serves to unknown clients.
  String get _subscriptionBody {
    final links = <String>[
      'socks5://127.0.0.1:$nodePort#ScaleGuard%20Test%20Node',
    ];
    return base64.encode(utf8.encode(links.join('\n')));
  }

  /// Downloads and parses the subscription with the application's own parser.
  Future<List<ParsedVpnServer>> fetchServers() async {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(subscriptionUrl));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();
    return parseSubscriptionBody(body);
  }

  Future<void> _handle(HttpRequest request) async {
    void json(Object body, [int status = 200]) {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      request.response.close();
    }

    switch (request.uri.path) {
      case '/sub':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.text
          ..headers.set(
            'subscription-userinfo',
            'upload=0; download=1048576; total=0; expire='
                '${DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000}',
          )
          ..write(_subscriptionBody);
        await request.response.close();
      case '/api/auth/config':
        json({
          'hcaptchaEnabled': false,
          'emailCodeTtlSeconds': 300,
          'loginCaptchaThreshold': 3,
          'telegramEnabled': false,
          'yandexEnabled': false,
          'hcaptchaSiteKey': '',
          'telegramBotName': 'ScaleGuard_bot',
        });
      case '/api/auth/login':
        json({'token': 'e2e-mock-token', 'user': _user});
      case '/api/profile':
        json({
          'user': _user,
          'tunnel': {
            'status': 'ACTIVE',
            'subscriptionUrl': subscriptionUrl,
            'expireAt': DateTime.now()
                .add(const Duration(days: 30))
                .toUtc()
                .toIso8601String(),
            'trafficLimitBytes': 0,
            'userTraffic': {'usedTrafficBytes': 1048576},
            'username': 'e2e',
            'uuid': '00000000-0000-0000-0000-000000000001',
          },
          'trial': {'enabled': false, 'eligible': false, 'durationDays': 0},
          'remnawaveSyncPending': false,
        });
      case '/api/plans':
        json([]);
      case '/api/payment/providers':
        json({'yookassa': false, 'platega': false});
      case '/probe':
        // The end-to-end harness routes a fake host through the tunnel and onto
        // this endpoint; an empty 204 is the smallest possible success signal.
        request.response
          ..statusCode = 204
          ..headers.contentType = ContentType.text;
        await request.response.close();
      default:
        json({'error': 'not found'}, 404);
    }
  }

  static const Map<String, Object> _user = {
    'id': 1,
    'email': 'e2e@scaleguard.test',
    'name': 'E2E',
    'balance': 1000,
    'role': 'user',
    'has_tg': false,
    'has_yandex': false,
  };

  Future<void> stop() => _server.close(force: true);
}

/// Re-exported so callers can refer to the node's credentials without importing
/// two files.
const String socks5Username = Socks5Node.username;
const String socks5Password = Socks5Node.password;
