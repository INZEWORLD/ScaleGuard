#include "flutter_window.h"

#include <dwmapi.h>
#include <string.h>
#include <windows.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "process_guard.h"
#include "resource.h"
#include "tray_menu.h"

namespace {

// Window attribute that enables dark mode window decorations.
// Redefined in case the developer's machine has a Windows SDK older than
// version 10.0.22000.0.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

// Windows 11 caption styling attributes. On Windows 10 the calls fail and the
// immersive dark mode above is still applied, so the runner works on both.
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif

// The caption follows the app palette instead of the system accent: the canvas
// and ink colours from `lib/theme/app_colors.dart`, plus the violet-tinted
// hairline the UI draws between panels.
constexpr COLORREF kDarkCaption = RGB(0x0A, 0x08, 0x1C);
constexpr COLORREF kDarkText = RGB(0xF4, 0xF1, 0xFF);
constexpr COLORREF kDarkBorder = RGB(0x2A, 0x1F, 0x4D);
constexpr COLORREF kLightCaption = RGB(0xF4, 0xF6, 0xFF);
constexpr COLORREF kLightText = RGB(0x17, 0x1A, 0x2B);
constexpr COLORREF kLightBorder = RGB(0xE4, 0xE8, 0xF2);

// Messages the shell sends to the window that owns the tray icon.
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;

// Converts the UTF-8 strings Dart sends into the UTF-16 the Win32 API expects.
std::wstring WideFromUtf8(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                       static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                      wide.data(), size);
  return wide;
}

// Sent by the shell when Explorer restarts, which drops every tray icon.
// Registered lazily because the value is only known at runtime.
UINT TaskbarCreatedMessage() {
  static const UINT message = RegisterWindowMessageW(L"TaskbarCreated");
  return message;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Keep the native caption in sync with the Flutter theme. Dart sends the
  // brightness as soon as the first frame is laid out — and again whenever the
  // theme is switched — so the title bar never looks like a leftover system
  // widget sitting on top of a themed window.
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "scaleguard/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "setTitleBarTheme") {
          bool dark = false;
          if (const auto* value = std::get_if<bool>(call.arguments())) {
            dark = *value;
          }
          ApplyTitleBarTheme(dark);
          result->Success();
          return;
        }
        if (method == "setCloseToTray") {
          bool hide = false;
          if (const auto* value = std::get_if<bool>(call.arguments())) {
            hide = *value;
          }
          // Turning it off also has to take the icon away, otherwise the user
          // is left with a tray entry that opens nothing.
          close_to_tray_ = hide;
          if (hide) {
            InstallTrayIcon();
          } else {
            RemoveTrayIcon();
          }
          result->Success();
          return;
        }
        if (method == "setTrayState") {
          const auto* fields =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (fields != nullptr) {
            const auto connected =
                fields->find(flutter::EncodableValue("connected"));
            if (connected != fields->end()) {
              if (const auto* value = std::get_if<bool>(&connected->second)) {
                tray_connected_ = *value;
              }
            }
            const auto location =
                fields->find(flutter::EncodableValue("location"));
            if (location != fields->end()) {
              if (const auto* value = std::get_if<std::string>(&location->second)) {
                tray_location_ = WideFromUtf8(*value);
              } else {
                tray_location_.clear();
              }
            }
          }
          UpdateTrayTooltip();
          result->Success();
          return;
        }
        if (method == "showWindow") {
          ShowFromTray();
          result->Success();
          return;
        }
        if (method == "quitApplication") {
          // Quitting has to mean quitting: the close interception is turned off
          // first, so the ordinary close path destroys the window, the message
          // loop ends and the process — together with the core in its job
          // object — goes with it.
          close_to_tray_ = false;
          RemoveTrayIcon();
          PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        if (method == "setChildrenMayOutliveUs") {
          // The launcher lifts the job's protection around a hand-over it cannot
          // decide in advance: the elevated copy of "always run as
          // administrator" is a child of this process, and the job would take it
          // down the moment this window closes. A refused launch puts the
          // protection back, so a session that stays keeps the core covered.
          const auto* allow = std::get_if<bool>(call.arguments());
          if (allow != nullptr) {
            ProcessGuard::SetChildrenMayOutliveUs(*allow);
          }
          result->Success();
          return;
        }
        if (method == "restartApplication") {
          RestartApplication();
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ApplyTitleBarTheme(bool dark) {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }

  BOOL dark_mode = dark ? TRUE : FALSE;
  DwmSetWindowAttribute(handle, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_mode,
                        sizeof(dark_mode));

  COLORREF caption = dark ? kDarkCaption : kLightCaption;
  COLORREF text = dark ? kDarkText : kLightText;
  COLORREF border = dark ? kDarkBorder : kLightBorder;
  DwmSetWindowAttribute(handle, DWMWA_CAPTION_COLOR, &caption, sizeof(caption));
  DwmSetWindowAttribute(handle, DWMWA_TEXT_COLOR, &text, sizeof(text));
  DwmSetWindowAttribute(handle, DWMWA_BORDER_COLOR, &border, sizeof(border));

  // Repaint the frame so the change lands immediately instead of on the next
  // resize.
  SetWindowPos(handle, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::InstallTrayIcon() {
  HWND handle = GetHandle();
  if (handle == nullptr || tray_installed_) {
    return;
  }

  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_icon_.hWnd = handle;
  tray_icon_.uID = kTrayIconId;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  tray_icon_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"ScaleGuard");
  if (!Shell_NotifyIconW(NIM_ADD, &tray_icon_)) {
    return;
  }
  tray_installed_ = true;
  UpdateTrayTooltip();
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_installed_) {
    return;
  }
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_installed_ = false;
}

void FlutterWindow::UpdateTrayTooltip() {
  if (!tray_installed_) {
    return;
  }
  // Every string here is a literal of this translation unit. The build passes
  // /utf-8 to the compiler, which is what keeps the em dash and the Cyrillic
  // readable in the shell — without it MSVC reads the file as the system code
  // page and the tooltip turns into "ScaleGuard вћ" ...".
  std::wstring tip = L"ScaleGuard — отключено";
  if (tray_connected_) {
    tip = tray_location_.empty()
              ? L"ScaleGuard — подключено"
              : L"ScaleGuard — подключено (" + tray_location_ + L")";
  }
  wcsncpy_s(tray_icon_.szTip, tip.c_str(), _TRUNCATE);
  tray_icon_.uFlags = NIF_TIP;
  Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
}

void FlutterWindow::HideToTray() {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }
  // The icon is what the user needs to get back, so it is created before the
  // window disappears rather than after.
  InstallTrayIcon();
  ShowWindow(handle, SW_HIDE);
}

void FlutterWindow::ShowFromTray() {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }
  ShowWindow(handle, SW_SHOWNORMAL);
  ShowWindow(handle, SW_RESTORE);
  SetForegroundWindow(handle);
}

void FlutterWindow::RestartApplication() {
  HWND handle = GetHandle();

  // The replacement is spawned by the process that is about to end, so without
  // this it would land inside the kill-on-close job object and the kernel would
  // take it down together with its parent. The job protection is only lifted for
  // the children of a process that is already leaving.
  ProcessGuard::AllowChildrenToOutliveUs();

  wchar_t path[MAX_PATH] = {};
  const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    std::wstring command = L"\"" + std::wstring(path, length) + L"\"";
    STARTUPINFOW startup{};
    startup.cb = sizeof(STARTUPINFOW);
    PROCESS_INFORMATION child{};
    // The child inherits this process's token, so a client that runs elevated
    // comes back elevated and does not ask for rights again.
    if (CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                       CREATE_UNICODE_ENVIRONMENT, nullptr, nullptr, &startup,
                       &child) != 0) {
      CloseHandle(child.hThread);
      CloseHandle(child.hProcess);
    }
  }

  close_to_tray_ = false;
  RemoveTrayIcon();
  PostMessage(handle, WM_CLOSE, 0, 0);
}

void FlutterWindow::ShowTrayMenu() {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }

  // Three entries, exactly as the application is meant to be operated from the
  // tray: restart it, take the tunnel down, or leave completely. The middle one
  // follows the state so the menu never offers "Отключить" on a client that is
  // already down.
  std::vector<TrayMenu::Item> items;
  items.push_back({L"Перезапустить приложение", false});
  items.push_back({tray_connected_ ? L"Отключить" : L"Подключить", false});
  items.push_back({L"Закрыть (выйти из приложения)", true});

  const std::wstring state = tray_connected_ ? L"Подключено" : L"Отключено";
  std::wstring detail = L"Соединение не установлено";
  if (tray_connected_) {
    detail = tray_location_.empty() ? L"Локация не выбрана" : tray_location_;
  }

  const int choice =
      tray_menu_.Show(handle, tray_connected_, state, detail, items);
  switch (choice) {
    case 0:
      SendToDart("trayRestart");
      break;
    case 1:
      SendToDart("trayToggle");
      break;
    case 2:
      SendToDart("trayQuit");
      break;
    default:
      break;
  }
}

void FlutterWindow::SendToDart(const char* method) {
  if (window_channel_ != nullptr) {
    window_channel_->InvokeMethod(method,
                                  std::make_unique<flutter::EncodableValue>());
    return;
  }
  // The engine is gone, so there is nobody left to run the action. Quitting is
  // the only safe answer: staying resident with an icon that cannot do anything
  // is exactly the "working in the background" state the tunnel must never end
  // up in.
  if (strcmp(method, "trayQuit") == 0) {
    close_to_tray_ = false;
    RemoveTrayIcon();
    PostMessage(GetHandle(), WM_CLOSE, 0, 0);
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // Closing a VPN client must not drop the tunnel, so the close button hides the
  // window while the tray icon keeps the client reachable. Quitting happens from
  // the tray menu, or by turning the setting off.
  if (message == WM_CLOSE && close_to_tray_) {
    HideToTray();
    return 0;
  }

  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowFromTray();
        return 0;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowTrayMenu();
        return 0;
      default:
        return 0;
    }
  }

  // Explorer restarted and dropped the icon; put it back.
  const UINT taskbar_created = TaskbarCreatedMessage();
  if (taskbar_created != 0 && message == taskbar_created) {
    if (close_to_tray_) {
      tray_installed_ = false;
      InstallTrayIcon();
    }
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
