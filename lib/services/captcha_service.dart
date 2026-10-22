import 'dart:math';

import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import 'api_client.dart';

/// Collects an hCaptcha token for the desktop build.
///
/// The application has no embedded browser, and an hCaptcha site key is bound to
/// a domain, so the challenge is solved in the user's own browser: a page on the
/// website renders the widget and posts the token to the API under a one-time
/// `state`, and this client polls for it. A protocol activation
/// (`scaleguard://captcha…`) would be the shorter path and is deliberately not
/// used: a browser-launched link has to pass a second confirmation when the
/// application runs elevated, which is exactly the moment a user waiting for a
/// registration code is least willing to answer one.
class CaptchaService {
  CaptchaService(this._api);

  final ApiClient _api;

  static const Duration _pollInterval = Duration(seconds: 2);

  bool _cancelled = false;

  /// Stops a wait that is in progress; the next call starts fresh.
  void cancel() => _cancelled = true;

  /// Opens the challenge in the browser and waits for the token.
  ///
  /// Returns `null` when the wait was cancelled or timed out — the caller turns
  /// that into a message rather than a silent failure.
  Future<String?> solve({
    required String siteKey,
    Duration timeout = const Duration(minutes: 4),
  }) async {
    _cancelled = false;
    final state = _randomState();
    final url = Uri.parse('${AppConfig.websiteUrl}/captcha.html').replace(
      queryParameters: {
        'sitekey': siteKey,
        'state': state,
        'api': AppConfig.apiUrl,
      },
    );
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw StateError('Не удалось открыть браузер для проверки hCaptcha');
    }

    final deadline = DateTime.now().add(timeout);
    while (!_cancelled && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_pollInterval);
      if (_cancelled) break;
      final res = await _api.post<Map<String, dynamic>>(
        '/api/auth/captcha/claim',
        data: {'state': state},
      );
      final token = res.data?['token'];
      if (token is String && token.trim().isNotEmpty) return token.trim();
    }
    return null;
  }

  /// A state the browser page hands back verbatim.
  ///
  /// It only has to be unguessable: whoever learns it could deliver their own
  /// token for this sign-in, and token itself is checked by the endpoint that
  /// uses it, so the state is a routing label rather than a secret.
  static String _randomState() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(32, (_) => alphabet[random.nextInt(alphabet.length)])
        .join();
  }
}
