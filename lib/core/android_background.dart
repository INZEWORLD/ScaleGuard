import 'dart:io';

import 'package:flutter/services.dart';

/// What Android currently allows this application to do while it is not on
/// screen.
///
/// A tunnel is only as good as the process behind it: the foreground service
/// keeps the client alive, the battery optimiser decides whether its threads may
/// run while the screen is off, and the OEM autostart gate decides whether the
/// service comes back at all. None of the latter two have a public API that
/// switches them on, so the client reports the state and opens the screens where
/// the user makes the choice.
class BackgroundStatus {
  const BackgroundStatus({
    required this.batteryExempt,
    required this.notifications,
    required this.manufacturer,
  });

  /// Whether the application is exempt from battery optimisation.
  final bool batteryExempt;

  /// Whether notifications may be posted — the tunnel's foreground service is
  /// only visible (and only unkillable) with them.
  final bool notifications;

  /// The device vendor, which decides whose autostart screen is offered.
  final String manufacturer;

  /// Whether this vendor keeps a separate autostart screen.
  ///
  /// Reported for the shells that are known to kill background services even
  /// with the exemption in place; the button is offered only where it exists, so
  /// the client never sends the user to a screen that is not there.
  bool get hasAutostartScreen {
    final vendor = manufacturer.toLowerCase();
    return vendor.contains('xiaomi') ||
        vendor.contains('redmi') ||
        vendor.contains('huawei') ||
        vendor.contains('honor') ||
        vendor.contains('oppo') ||
        vendor.contains('vivo') ||
        vendor.contains('realme');
  }

  /// Every requirement met, which is what the card's summary line reports.
  bool get ready => batteryExempt && notifications;
}

/// The Android half of "keep the tunnel running".
class AndroidBackground {
  const AndroidBackground._();

  static const MethodChannel _channel =
      MethodChannel('com.scaleguard.app/core');

  /// Current state, or `null` on a platform without these settings.
  static Future<BackgroundStatus?> read() async {
    if (!Platform.isAndroid) return null;
    try {
      final map =
          await _channel.invokeMapMethod<String, dynamic>('backgroundStatus');
      if (map == null) return null;
      return BackgroundStatus(
        batteryExempt: map['batteryExempt'] == true,
        notifications: map['notifications'] == true,
        manufacturer: '${map['manufacturer'] ?? ''}',
      );
    } catch (_) {
      // An old build without the handler: the card simply stays hidden.
      return null;
    }
  }

  /// Opens the system dialog that exempts the app from battery optimisation.
  static Future<bool> requestBatteryExemption() =>
      _call('requestIgnoreBatteryOptimizations');

  /// Opens the per-application battery screen ("Расход заряда батареи").
  ///
  /// This is the second, separate permission: the exemption above stops Doze
  /// from freezing the process, while the restriction level on this screen is
  /// what vendor shells use to kill a background service. The useful value there
  /// is "Без ограничений".
  static Future<bool> openBatteryUsageSettings() =>
      _call('openBatteryUsageSettings');

  /// Asks for the notification permission the foreground service needs.
  static Future<bool> requestNotifications() => _call('requestNotifications');

  /// Opens the vendor's autostart screen (falls back to the app's own page).
  static Future<bool> openAutostartSettings() =>
      _call('openAutostartSettings');

  static Future<bool> _call(String method) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }
}
