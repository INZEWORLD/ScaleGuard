/// Dependency-substituted stand-in for `package:flutter_local_notifications`.
///
/// It mirrors the API the application uses and performs no native work, which
/// keeps a Windows build free of the upstream package's C++/ATL requirement.
/// Real reminders on Android and iOS go through
/// `lib/services/notification_backend_mobile.dart`; see
/// `tool/shims/flutter_local_notifications/README.md`.
library;

import 'dart:async';

/// Platform-specific initialisation values.
class AndroidInitializationSettings {
  const AndroidInitializationSettings(this.defaultIcon);

  final String defaultIcon;
}

/// iOS/macOS initialisation values.
class DarwinInitializationSettings {
  const DarwinInitializationSettings({
    this.requestAlertPermission = true,
    this.requestBadgePermission = true,
    this.requestSoundPermission = true,
  });

  final bool requestAlertPermission;
  final bool requestBadgePermission;
  final bool requestSoundPermission;
}

/// Per-platform initialisation bundle.
class InitializationSettings {
  const InitializationSettings({
    this.android,
    this.iOS,
    this.macOS,
    this.linux,
    this.windows,
  });

  final AndroidInitializationSettings? android;
  final DarwinInitializationSettings? iOS;
  final DarwinInitializationSettings? macOS;
  final Object? linux;
  final Object? windows;
}

/// Importance levels for Android notification channels.
enum Importance { min, low, defaultImportance, high, max }

/// Priority levels for Android notifications.
enum Priority { min, low, defaultPriority, high, max }

/// How a scheduled Android notification may be delivered.
enum AndroidScheduleMode {
  exact,
  exactAllowWhileIdle,
  inexact,
  inexactAllowWhileIdle,
  alarmClock,
}

/// Android notification channel details.
class AndroidNotificationDetails {
  const AndroidNotificationDetails(
    this.channelId,
    this.channelName, {
    this.channelDescription,
    this.importance = Importance.defaultImportance,
    this.priority = Priority.defaultPriority,
  });

  final String channelId;
  final String channelName;
  final String? channelDescription;
  final Importance importance;
  final Priority priority;
}

/// iOS/macOS notification details.
class DarwinNotificationDetails {
  const DarwinNotificationDetails({this.presentAlert, this.presentSound});
  final bool? presentAlert;
  final bool? presentSound;
}

/// Per-platform notification details.
class NotificationDetails {
  const NotificationDetails({
    this.android,
    this.iOS,
    this.macOS,
    this.linux,
    this.windows,
  });

  final AndroidNotificationDetails? android;
  final DarwinNotificationDetails? iOS;
  final DarwinNotificationDetails? macOS;
  final Object? linux;
  final Object? windows;
}

/// Callback invoked when the user taps a notification.
typedef DidReceiveNotificationResponseCallback = void Function(
  NotificationResponse response,
);

/// Minimal notification response payload.
class NotificationResponse {
  const NotificationResponse({this.id, this.payload});
  final int? id;
  final String? payload;
}

/// Android-specific operations.
class AndroidFlutterLocalNotificationsPlugin {
  Future<bool?> requestNotificationsPermission() async => null;
  Future<bool?> requestExactAlarmsPermission() async => null;
}

/// iOS/macOS-specific operations.
class IOSFlutterLocalNotificationsPlugin {
  Future<bool?> requestPermissions({
    bool alert = false,
    bool badge = false,
    bool sound = false,
  }) async =>
      null;
}

/// Entry point, API-compatible with the upstream plugin.
///
/// Every method is a no-op: the goal is for the application to keep compiling
/// and running on desktop, not to deliver reminders there.
class FlutterLocalNotificationsPlugin {
  Future<bool?> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async =>
      true;

  Future<void> cancelAll() async {}

  Future<void> cancel(int id, {String? tag}) async {}

  Future<void> show(
    int id,
    String? title,
    String? body,
    NotificationDetails? details, {
    String? payload,
  }) async {}

  Future<void> zonedSchedule(
    int id,
    String? title,
    String? body,
    Object scheduledDate,
    NotificationDetails details, {
    required AndroidScheduleMode androidScheduleMode,
    String? payload,
    Object? matchDateTimeComponents,
  }) async {}

  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async =>
      const [];

  T? resolvePlatformSpecificImplementation<T extends Object>() {
    if (T == AndroidFlutterLocalNotificationsPlugin) {
      return AndroidFlutterLocalNotificationsPlugin() as T;
    }
    if (T == IOSFlutterLocalNotificationsPlugin) {
      return IOSFlutterLocalNotificationsPlugin() as T;
    }
    return null;
  }
}

/// Callback for background notification responses.
typedef DidReceiveBackgroundNotificationResponseCallback = void Function(
  NotificationResponse response,
);

/// A pending scheduled notification.
class PendingNotificationRequest {
  const PendingNotificationRequest(this.id, this.title, this.body, this.payload);

  final int id;
  final String? title;
  final String? body;
  final String? payload;
}
