import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'notification_backend.dart';

/// Notification backend for Android and iOS.
///
/// This is the only file that references `flutter_local_notifications`, which
/// keeps the plugin out of desktop builds: its Windows implementation needs the
/// ATL headers from a Visual Studio workload the client deliberately does not
/// require. See `notification_backend_stub.dart` for the desktop behaviour.
class MobileNotificationBackend implements NotificationBackend {
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _channelId = 'scaleguard_subscription';
  static const _channelName = 'Подписка ScaleGuard';

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _local.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (_) {},
    );
    // Android 13+ requires an explicit runtime permission for notifications.
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _initialized = true;
  }

  @override
  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _local.cancelAll();
  }

  @override
  Future<void> schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
  }) async {
    if (!_initialized) return;
    final tzWhen = tz.TZDateTime.from(when, tz.local);
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _local.zonedSchedule(
      id,
      title,
      body,
      tzWhen,
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }
}

/// Creates the mobile backend.
NotificationBackend createNotificationBackend() => MobileNotificationBackend();
