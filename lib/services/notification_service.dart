import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'api_client.dart';
import 'notification_backend.dart';
import 'notification_backend_resolver.dart';

/// Локальные напоминания о подписке + регистрация FCM-токена на сервере.
///
/// Reminders are scheduled through [NotificationBackend], which is a real
/// implementation on Android/iOS and a no-op on desktop.
class NotificationService {
  NotificationService(this._api, {NotificationBackend? backendOverride})
      : _backend = backendOverride ?? createNotificationBackend();

  final ApiClient _api;
  final NotificationBackend _backend;
  bool _initialized = false;

  /// Whether this platform can show local reminders at all.
  bool get supportsLocalReminders => _backend.isSupported;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      await _backend.initialize();
      _initialized = true;
    } catch (error) {
      debugPrint('Local notifications init skipped: $error');
    }
  }

  Future<void> registerFcmTokenIfAvailable(String? token) async {
    final trimmed = token?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    try {
      await _api.post('/api/mobile/push/register', data: {
        'token': trimmed,
        'platform': defaultTargetPlatform.name,
      });
    } catch (error) {
      debugPrint('FCM register skipped: $error');
    }
  }

  Future<void> syncSubscriptionReminders(TunnelInfo? tunnel) async {
    if (!_initialized || !_backend.isSupported) return;
    await _backend.cancelAll();

    final expRaw = tunnel?.expireAt;
    if (expRaw == null || expRaw.isEmpty) return;
    final expiresAt = DateTime.tryParse(expRaw);
    if (expiresAt == null || !expiresAt.isAfter(DateTime.now())) return;

    final threeDays = expiresAt.subtract(const Duration(days: 3));
    if (threeDays.isAfter(DateTime.now())) {
      await _backend.schedule(
        id: 1001,
        when: threeDays,
        title: 'ScaleGuard: подписка скоро закончится',
        body: 'Осталось ~3 дня. Продлите тариф в приложении.',
      );
    }

    final sixHours = expiresAt.subtract(const Duration(hours: 6));
    if (sixHours.isAfter(DateTime.now())) {
      await _backend.schedule(
        id: 1002,
        when: sixHours,
        title: 'ScaleGuard: подписка заканчивается сегодня',
        body: 'Продлите доступ, чтобы соединение не оборвалось.',
      );
    }
  }
}
