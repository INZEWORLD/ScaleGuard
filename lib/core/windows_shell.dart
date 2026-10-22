import 'dart:io';

import 'package:flutter/services.dart';

/// Thin wrapper over the native window channel implemented by the Windows
/// runner (`windows/runner/flutter_window.cpp`).
///
/// Kept separate from the widgets so the runner contract lives in one place:
/// the runner owns the caption colours and the tray icon, and Dart only steers
/// them — and answers the tray menu when the user picks an entry from it.
class WindowsShell {
  WindowsShell._();

  static const MethodChannel _channel = MethodChannel('scaleguard/window');

  bool get isSupported => Platform.isWindows;

  /// Tells the runner what the close button means.
  ///
  /// `true` hides the window and leaves the tray icon running — the behaviour a
  /// VPN client needs, because closing the window must not drop the tunnel.
  /// `false` restores the ordinary "close quits" behaviour.
  static Future<void> setCloseToTray(bool hide) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('setCloseToTray', hide);
    } catch (_) {
      // A runner without the method (an older build) keeps quitting on close,
      // which is safe; nothing in the UI depends on the answer.
    }
  }

  /// Reports the tunnel state to the tray icon, so its tooltip and menu show
  /// what the client is actually doing while the window is hidden.
  static Future<void> setTrayState({
    required bool connected,
    String? location,
  }) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('setTrayState', <String, Object?>{
        'connected': connected,
        'location': location,
      });
    } catch (_) {}
  }

  /// Brings the window back from the tray.
  ///
  /// Used when something needs the user's attention — the administrator prompt,
  /// the TUN driver offer, an error — while the window is hidden, because an
  /// action that silently does nothing looks broken.
  static Future<void> showWindow() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('showWindow');
    } catch (_) {}
  }

  /// Lifts (or restores) the job object's protection for processes created from
  /// now on.
  ///
  /// The runner keeps every child of the client — the VPN core above all — from
  /// outliving it, which also means a replacement started *by this process* dies
  /// with the window that started it. Starting the elevated copy is exactly such
  /// a hand-over, and unlike the tray's restart it cannot be decided in advance:
  /// whether a replacement is wanted is only known once Windows answers. So the
  /// launcher lifts the protection, launches, and puts it back when nothing
  /// arrived — leaving the client as covered as it was.
  static Future<void> setChildrenMayOutliveUs(bool allow) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('setChildrenMayOutliveUs', allow);
    } catch (_) {
      // A runner without the method (an older build) cannot be told; the
      // launcher still tries, and the wait for the replacement decides.
    }
  }

  /// Ends the process through the runner instead of `exit()`.
  ///
  /// The runner takes the tray icon down and destroys its window, which lets the
  /// message loop end and every child process be reaped (the core included)
  /// rather than being killed out from under a `WM_CLOSE` that is never seen.
  static Future<void> quitApplication() async {
    if (!Platform.isWindows) {
      exit(0);
    }
    try {
      await _channel.invokeMethod<void>('quitApplication');
    } catch (_) {
      // A runner without the method cannot be asked nicely, so the process ends
      // anyway: leaving the client half-alive would be worse.
      exit(0);
    }
  }

  /// Starts a fresh copy of the client and ends this one.
  ///
  /// The runner performs both steps — spawning the replacement and closing its
  /// window — because the replacement must not end up inside the job object that
  /// kills everything when this process goes away, and only the runner can lift
  /// that. Dart has already taken the tunnel down by the time this is called.
  static Future<void> restartApplication() async {
    if (!Platform.isWindows) {
      exit(0);
    }
    try {
      await _channel.invokeMethod<void>('restartApplication');
    } catch (_) {
      exit(0);
    }
  }

  /// Handles the three entries of the notification-area menu.
  ///
  /// The popup itself lives in the runner, but none of these actions can be
  /// performed there: restarting, taking the tunnel down and quitting all have
  /// to go through the application state, which owns the tunnel, the system
  /// proxy, the kill switch and the saved session. The runner asks, Dart does.
  static void handleTrayActions({
    required Future<void> Function() restart,
    required Future<void> Function() toggle,
    required Future<void> Function() quit,
  }) {
    if (!Platform.isWindows) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'trayRestart':
          await restart();
        case 'trayToggle':
          await toggle();
        case 'trayQuit':
          await quit();
      }
      return null;
    });
  }
}
