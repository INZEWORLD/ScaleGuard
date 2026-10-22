/// Platform-specific part of the local reminder feature.
///
/// Android and iOS schedule real notifications; desktop platforms use a no-op
/// implementation. The two are selected by conditional import in
/// `notification_service.dart`, so the plugin that needs an extra Visual Studio
/// workload never enters a Windows build.
abstract class NotificationBackend {
  /// Whether this platform can actually show scheduled reminders.
  bool get isSupported;

  /// Prepares the platform plugin and requests permissions where required.
  Future<void> initialize();

  /// Removes every scheduled reminder previously created by this application.
  Future<void> cancelAll();

  /// Schedules one reminder.
  Future<void> schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
  });
}
