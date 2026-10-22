#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windows.h>

#include <memory>
#include <string>

#include "tray_menu.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Styles the native caption so it matches the Flutter theme rather than the
  // system one. The app has a strong dark-violet identity and a grey system
  // title bar was the one visible seam in an otherwise consistent window.
  void ApplyTitleBarTheme(bool dark);

  // Adds the notification-area icon, or removes it again.
  void InstallTrayIcon();
  void RemoveTrayIcon();

  // Redraws the tray tooltip. While the window is hidden this is the only place
  // the tunnel state is visible, so it says what the client is doing and where
  // it exits.
  void UpdateTrayTooltip();

  // Hides the window, leaving the tunnel and the tray icon running.
  void HideToTray();

  // Restores and focuses the window.
  void ShowFromTray();

  // Starts a fresh copy of the client and ends this one. The tunnel is already
  // down by the time this runs — Dart performs the teardown first, because the
  // system proxy, the kill switch and the saved session live there.
  void RestartApplication();

  // Context menu behind a right click on the tray icon. Returns the action the
  // user picked, or does nothing when the menu was dismissed.
  void ShowTrayMenu();

  // Asks the Dart side to run one of the tray actions ("trayRestart",
  // "trayToggle", "trayQuit"). Restarting, disconnecting and quitting all have
  // to run through the application state: the tunnel, the system proxy, the
  // kill switch and the saved session all live there, and a native-only exit
  // would leave them behind.
  void SendToDart(const char* method);

  // Channel shared by the Dart side and the tray: the caption theme, the tray
  // state and the tray actions all travel over it in the two directions.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // True while the close button should hide the window instead of quitting.
  bool close_to_tray_ = false;

  bool tray_installed_ = false;
  bool tray_connected_ = false;
  std::wstring tray_location_;
  NOTIFYICONDATAW tray_icon_ = {};

  // The owner-drawn popup behind a right click on the tray icon.
  TrayMenu tray_menu_;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
