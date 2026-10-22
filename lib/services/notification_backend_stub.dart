import 'notification_backend.dart';

/// Notification backend used on platforms where the client does not ship the
/// local-notifications plugin.
///
/// Reminder scheduling is a convenience, never a requirement, so on desktop the
/// service degrades to "no local reminders" instead of forcing an extra Visual
/// Studio workload (ATL) onto every user who wants the VPN. The account itself
/// still receives server-side notifications through the website and the bot.
class NoopNotificationBackend implements NotificationBackend {
  const NoopNotificationBackend();

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
  }) async {}
}

/// Creates the desktop backend.
NotificationBackend createNotificationBackend() =>
    const NoopNotificationBackend();
