import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/core/qr_link.dart';
import 'package:scaleguard_mobile/services/api_client.dart';
import 'package:scaleguard_mobile/services/auth_service.dart';

/// The QR sign-in contract, checked against a panel that behaves like ours.
///
/// The client and the panel are deployed separately, so the one thing that has
/// to be nailed down is the shape of the conversation between them: the paths,
/// the verbs, the field names and the link a code encodes. A typo in any of
/// those is invisible here until a real phone is pointed at a real screen, which
/// is exactly the kind of failure this test exists to move earlier.
///
/// The fake panel mirrors the routes added to `scaleguardweb`; when the panel
/// changes, this test is where the client finds out.
void main() {
  late HttpServer server;
  late AuthService auth;
  late _FakePanel panel;

  setUp(() async {
    panel = _FakePanel();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(panel.handle);
    auth = AuthService(
      ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')),
      ),
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('a fresh session carries the link the parser accepts', () async {
    final session = await auth.startQrLoginSession();

    expect(session.sessionId, isNotEmpty);
    expect(session.expiresAt.isAfter(DateTime.now()), isTrue);
    // The panel's link and the scanner's parser are two halves of one format.
    expect(qrSessionIdFromLink(session.link), session.sessionId);
  });

  test('a claimed session is reported as claimed', () async {
    final session = await auth.startQrLoginSession();
    expect((await auth.pollQrLoginSession(session.sessionId)).status, 'pending');

    await auth.claimQrLoginSession(session.sessionId);
    expect((await auth.pollQrLoginSession(session.sessionId)).status, 'claimed');
  });

  test('an approved session hands over the token and the user', () async {
    final session = await auth.startQrLoginSession();
    await auth.claimQrLoginSession(session.sessionId);
    await auth.approveQrLoginSession(session.sessionId);

    final result = await auth.pollQrLoginSession(session.sessionId);
    expect(result.status, 'approved');
    expect(result.token, 'signed.jwt.token');
    expect(result.user?.email, 'someone@example.com');
    expect(result.user?.id, 42);
  });

  test('the verify endpoints are called as the panel expects', () async {
    final session = await auth.startQrLoginSession();
    await auth.claimQrLoginSession(session.sessionId);
    await auth.approveQrLoginSession(session.sessionId);

    expect(panel.calls, <String>[
      'POST /api/auth/qr/session',
      'POST /api/auth/qr/session/${session.sessionId}/claim',
      'POST /api/auth/qr/session/${session.sessionId}/approve',
    ]);
  });
}

/// A stand-in for the panel's QR routes, with the same states and fields.
class _FakePanel {
  final Map<String, String> _status = <String, String>{};
  final List<String> calls = <String>[];
  int _counter = 0;

  Future<void> handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    calls.add('${request.method} ${request.uri.path}');

    // /api/auth/qr/session
    if (segments.length == 4 && segments.last == 'session') {
      _counter++;
      final id = 'session-${_counter.toString().padLeft(24, '0')}';
      _status[id] = 'pending';
      return _json(request, <String, dynamic>{
        'sessionId': id,
        'link': 'scaleguard://qr?session=$id',
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 3))
            .toUtc()
            .toIso8601String(),
        'pollIntervalMs': 1500,
      });
    }

    // /api/auth/qr/session/:id[/claim|/approve]
    if (segments.length >= 5 && segments[3] == 'session') {
      final id = segments[4];
      final action = segments.length > 5 ? segments[5] : '';
      if (!_status.containsKey(id)) {
        return _json(request, <String, dynamic>{'status': 'missing'}, 404);
      }
      switch (action) {
        case 'claim':
          if (_status[id] == 'pending') _status[id] = 'claimed';
          return _json(request, <String, dynamic>{'status': _status[id]});
        case 'approve':
          _status[id] = 'approved';
          return _json(request, <String, dynamic>{'status': 'approved'});
        default:
          if (_status[id] == 'approved') {
            return _json(request, <String, dynamic>{
              'status': 'approved',
              'token': 'signed.jwt.token',
              'user': <String, dynamic>{
                'id': 42,
                'email': 'someone@example.com',
                'name': 'Someone',
                'balance': 0,
                'role': 'user',
                'has_tg': false,
                'has_yandex': false,
              },
            });
          }
          return _json(request, <String, dynamic>{'status': _status[id]});
      }
    }

    return _json(request, <String, dynamic>{'error': 'not found'}, 404);
  }

  void _json(HttpRequest request, Map<String, dynamic> body, [int status = 200]) {
    unawaited(() async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    }());
  }
}
