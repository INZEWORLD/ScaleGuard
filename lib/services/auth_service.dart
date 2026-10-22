import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../models/models.dart';
import 'api_client.dart';

class AuthService {
  AuthService(this._api);

  final ApiClient _api;

  Future<AuthConfig> fetchAuthConfig() async {
    final res = await _api.get<Map<String, dynamic>>('/api/auth/config');
    return AuthConfig.fromJson(res.data ?? {});
  }

  Future<({bool exists, bool hasPassword})> lookupEmail(String email) async {
    try {
      final res = await _api.post<Map<String, dynamic>>('/api/auth/email-lookup', data: {
        'email': email,
      });
      final data = res.data ?? {};
      return (
        exists: data['exists'] == true,
        hasPassword: data['hasPassword'] == true,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return (exists: false, hasPassword: false);
      }
      rethrow;
    }
  }

  Future<void> requestEmailCode({
    required String email,
    required String mode,
    String captchaToken = '',
  }) async {
    await _api.post('/api/auth/request-email-code', data: {
      'email': email,
      'mode': mode,
      'captchaToken': captchaToken,
    });
  }

  Future<({String token, PublicUser user})> login({
    required String email,
    required String password,
    String captchaToken = '',
  }) async {
    final res = await _api.post<Map<String, dynamic>>('/api/auth/login', data: {
      'email': email,
      'password': password,
      'captchaToken': captchaToken,
    });
    final data = res.data!;
    return (
      token: data['token'] as String,
      user: PublicUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<({String token, PublicUser user})> register({
    required String email,
    required String password,
    required String verificationCode,
    String? name,
  }) async {
    final res = await _api.post<Map<String, dynamic>>('/api/auth/register', data: {
      'email': email,
      'password': password,
      'verificationCode': verificationCode,
      if (name != null && name.isNotEmpty) 'name': name,
    });
    final data = res.data!;
    return (
      token: data['token'] as String,
      user: PublicUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<void> requestPasswordResetCode(String email, {String captchaToken = ''}) async {
    await _api.post('/api/auth/reset-password/request-code', data: {
      'email': email,
      'captchaToken': captchaToken,
    });
  }

  Future<({String token, PublicUser user})> confirmPasswordReset({
    required String email,
    required String verificationCode,
    required String newPassword,
    String captchaToken = '',
  }) async {
    final res = await _api.post<Map<String, dynamic>>('/api/auth/reset-password/confirm', data: {
      'email': email,
      'verificationCode': verificationCode,
      'newPassword': newPassword,
      'captchaToken': captchaToken,
    });
    final data = res.data!;
    return (
      token: data['token'] as String,
      user: PublicUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<String> startYandexOAuth() async {
    final res = await _api.post<Map<String, dynamic>>('/api/auth/yandex/start', data: {
      'mode': 'login',
      'returnOrigin': AppConfig.mobileReturnOrigin,
    });
    return (res.data?['authUrl'] as String?) ?? '';
  }

  Future<({
    String sessionToken,
    String botUrl,
    int pollIntervalMs,
  })> startTelegramSession() async {
    final res = await _api.post<Map<String, dynamic>>('/api/auth/telegram/session', data: {
      'mode': 'login',
    });
    final data = res.data!;
    return (
      sessionToken: data['sessionToken'] as String,
      botUrl: data['botUrl'] as String,
      pollIntervalMs: (data['pollIntervalMs'] as num?)?.toInt() ?? 2000,
    );
  }

  Future<({String status, String? token, PublicUser? user})> pollTelegramSession(
    String sessionToken,
  ) async {
    final res = await _api.get<Map<String, dynamic>>(
      '/api/auth/telegram/session/$sessionToken',
    );
    final data = res.data!;
    final status = data['status'] as String? ?? 'pending';
    if (status == 'approved') {
      return (
        status: status,
        token: data['token'] as String?,
        user: data['user'] != null
            ? PublicUser.fromJson(data['user'] as Map<String, dynamic>)
            : null,
      );
    }
    return (status: status, token: null, user: null);
  }

  /// Asks the panel for a fresh QR sign-in session.
  Future<QrLoginSession> startQrLoginSession() async {
    final res = await _api.post<Map<String, dynamic>>('/api/auth/qr/session');
    return QrLoginSession.fromJson(res.data ?? const <String, dynamic>{});
  }

  /// Polls a QR session; only an approved one carries a token.
  Future<({String status, String? token, PublicUser? user})> pollQrLoginSession(
    String sessionId,
  ) async {
    final res = await _api.get<Map<String, dynamic>>(
      '/api/auth/qr/session/$sessionId',
    );
    final data = res.data ?? const <String, dynamic>{};
    final status = data['status'] as String? ?? 'pending';
    if (status == 'approved' && data['token'] is String) {
      return (
        status: status,
        token: data['token'] as String,
        user: data['user'] != null
            ? PublicUser.fromJson(data['user'] as Map<String, dynamic>)
            : null,
      );
    }
    return (status: status, token: null, user: null);
  }

  /// Announces that this device has scanned [sessionId] and is waiting.
  Future<void> claimQrLoginSession(String sessionId) async {
    await _api.post('/api/auth/qr/session/$sessionId/claim');
  }

  /// Lets the device that showed [sessionId] in, using this account.
  Future<void> approveQrLoginSession(String sessionId) async {
    await _api.post('/api/auth/qr/session/$sessionId/approve');
  }

  Future<ProfileSnapshot> fetchProfile() async {
    final res = await _api.get<Map<String, dynamic>>('/api/profile');
    return ProfileSnapshot.fromJson(res.data!);
  }

  Future<ProfileSnapshot> activateTrial() async {
    final res = await _api.post<Map<String, dynamic>>('/api/trial/activate');
    return ProfileSnapshot.fromJson(res.data!);
  }
}
