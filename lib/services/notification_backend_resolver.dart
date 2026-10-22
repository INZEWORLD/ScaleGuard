import 'dart:io' show Platform;

import 'notification_backend.dart';
import 'notification_backend_mobile.dart';
import 'notification_backend_stub.dart' as stub;

/// Picks the notification backend for the platform this binary runs on.
///
/// The choice is made at runtime rather than with a conditional import so that
/// both backends stay reachable and analysable, while only the mobile one
/// actually touches the `flutter_local_notifications` plugin. On Windows the
/// native side of that plugin is not built at all (it needs ATL headers), so
/// calling into it would fail; the no-op backend keeps the feature optional
/// instead of forcing an extra Visual Studio workload on every user.
NotificationBackend createNotificationBackend() {
  if (Platform.isAndroid || Platform.isIOS) {
    return MobileNotificationBackend();
  }
  return const stub.NoopNotificationBackend();
}
