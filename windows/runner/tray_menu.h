#ifndef RUNNER_TRAY_MENU_H_
#define RUNNER_TRAY_MENU_H_

#include <windows.h>

#include <string>
#include <vector>

// Owner-drawn notification-area menu.
//
// The Win32 menu API is deliberately not used here. A `MENUINFO`-styled popup
// keeps the system font and its selection colour cannot be changed at all, so a
// themed application ends up with a grey system menu glued to it. Drawing the
// popup directly gives it the palette of `lib/theme/app_colors.dart`, and it
// also removes the encoding trap of the previous version: those labels were
// narrow/wide string literals compiled with the system code page, which is why
// the tooltip read "ScaleGuard вћ" ..." instead of "ScaleGuard — подключено".
class TrayMenu {
 public:
  struct Item {
    std::wstring label;

    // Drawn in the warning colour; used for the item that ends the session.
    bool danger = false;
  };

  TrayMenu();
  ~TrayMenu();

  TrayMenu(const TrayMenu&) = delete;
  TrayMenu& operator=(const TrayMenu&) = delete;

  // Shows the popup next to the cursor and returns the index of the item the
  // user picked, or -1 when the menu was dismissed without a choice. Blocks
  // until the menu closes, exactly like `TrackPopupMenu` does.
  int Show(HWND owner,
           bool connected,
           const std::wstring& state,
           const std::wstring& detail,
           const std::vector<Item>& items);

 private:
  static void EnsureWindowClass();
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  LRESULT HandleMessage(HWND window, UINT message, WPARAM wparam,
                        LPARAM lparam);

  void Layout(int scale);
  void Paint(HWND window, int width, int height);
  int ItemAt(int x, int y) const;

  HWND window_ = nullptr;
  bool connected_ = false;
  std::wstring state_;
  std::wstring detail_;
  std::vector<Item> items_;

  // Lay-out results, filled by `Layout` and only read while painting so the
  // drawing code cannot disagree with the hit testing.
  int scale_ = 100;
  int width_ = 0;
  int height_ = 0;
  RECT dot_rect_ = {};
  RECT state_rect_ = {};
  RECT detail_rect_ = {};
  std::vector<RECT> item_rects_;
  std::vector<int> divider_ys_;

  int hover_ = -1;
  int result_ = -1;
  bool finished_ = false;
  bool activated_ = false;
};

#endif  // RUNNER_TRAY_MENU_H_
