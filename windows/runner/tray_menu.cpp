#include "tray_menu.h"

#include <windowsx.h>

#include <string>
#include <vector>

namespace {

constexpr wchar_t kMenuClassName[] = L"ScaleGuardTrayMenu";

// The palette of `lib/theme/app_colors.dart`, so the popup reads as part of the
// application and not as a system artefact attached to it.
constexpr COLORREF kBackground = RGB(0x0E, 0x0B, 0x20);
constexpr COLORREF kHighlight = RGB(0x25, 0x1E, 0x47);
constexpr COLORREF kDivider = RGB(0x2B, 0x24, 0x50);
constexpr COLORREF kText = RGB(0xF4, 0xF1, 0xFF);
constexpr COLORREF kMuted = RGB(0xB7, 0xB3, 0xD0);
constexpr COLORREF kFaint = RGB(0x8C, 0x87, 0xA8);
constexpr COLORREF kAccent = RGB(0x9B, 0x7C, 0xFF);
constexpr COLORREF kOnline = RGB(0x3D, 0xFF, 0xB0);
constexpr COLORREF kDanger = RGB(0xFF, 0x4D, 0x6A);

// Logical metrics. Every one of them is scaled by the DPI of the display the
// menu opens on, so the popup keeps the same visual weight on a 150% screen.
constexpr int kWidth = 258;
constexpr int kHeaderHeight = 62;
constexpr int kItemHeight = 38;
constexpr int kPadding = 8;
constexpr int kDividerHeight = 11;
constexpr int kCornerRadius = 18;
constexpr int kItemRadius = 11;
constexpr int kDotSize = 8;
constexpr int kBaseDpi = 96;

int Scaled(int value, int scale) {
  return MulDiv(value, scale, 100);
}

// A Segoe UI font at |points|, sized for the given DPI scale percentage.
HFONT CreateUiFont(int scale, int points, bool bold) {
  const int dpi = MulDiv(kBaseDpi, scale, 100);
  return CreateFontW(-MulDiv(points, dpi, 72), 0, 0, 0,
                     bold ? FW_SEMIBOLD : FW_NORMAL, FALSE, FALSE, FALSE,
                     DEFAULT_CHARSET, OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS,
                     CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                     L"Segoe UI");
}

void FillRoundedRect(HDC dc, const RECT& rect, int radius, COLORREF colour) {
  HBRUSH brush = CreateSolidBrush(colour);
  HPEN pen = CreatePen(PS_SOLID, 1, colour);
  if (brush == nullptr || pen == nullptr) {
    if (brush != nullptr) {
      DeleteObject(brush);
    }
    if (pen != nullptr) {
      DeleteObject(pen);
    }
    return;
  }
  HGDIOBJ previous_brush = SelectObject(dc, brush);
  HGDIOBJ previous_pen = SelectObject(dc, pen);
  RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius * 2,
            radius * 2);
  SelectObject(dc, previous_brush);
  SelectObject(dc, previous_pen);
  DeleteObject(brush);
  DeleteObject(pen);
}

void FillEllipse(HDC dc, const RECT& rect, COLORREF colour) {
  HBRUSH brush = CreateSolidBrush(colour);
  HPEN pen = CreatePen(PS_SOLID, 1, colour);
  if (brush == nullptr || pen == nullptr) {
    if (brush != nullptr) {
      DeleteObject(brush);
    }
    if (pen != nullptr) {
      DeleteObject(pen);
    }
    return;
  }
  HGDIOBJ previous_brush = SelectObject(dc, brush);
  HGDIOBJ previous_pen = SelectObject(dc, pen);
  Ellipse(dc, rect.left, rect.top, rect.right, rect.bottom);
  SelectObject(dc, previous_brush);
  SelectObject(dc, previous_pen);
  DeleteObject(brush);
  DeleteObject(pen);
}

// The DPI scale of the primary display, as a percentage. The popup is a
// short-lived window, so following the primary monitor is precise enough and
// avoids depending on per-monitor DPI APIs that older SDKs do not declare.
int PrimaryScalePercent() {
  HDC screen = GetDC(nullptr);
  if (screen == nullptr) {
    return 100;
  }
  const int dpi = GetDeviceCaps(screen, LOGPIXELSY);
  ReleaseDC(nullptr, screen);
  if (dpi <= 0) {
    return 100;
  }
  return MulDiv(dpi, 100, kBaseDpi);
}

}  // namespace

TrayMenu::TrayMenu() = default;
TrayMenu::~TrayMenu() = default;

void TrayMenu::EnsureWindowClass() {
  static bool registered = false;
  if (registered) {
    return;
  }
  WNDCLASSEXW definition{};
  definition.cbSize = sizeof(WNDCLASSEXW);
  definition.style = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
  definition.lpfnWndProc = &TrayMenu::WindowProc;
  definition.hInstance = GetModuleHandleW(nullptr);
  definition.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  definition.lpszClassName = kMenuClassName;
  // No background brush: the popup paints every pixel itself, and letting the
  // system erase first would flash the desktop colour behind the rounded
  // corners.
  if (RegisterClassExW(&definition) != 0) {
    registered = true;
  }
}

LRESULT CALLBACK TrayMenu::WindowProc(HWND window, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  TrayMenu* self = reinterpret_cast<TrayMenu*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    // The instance pointer is handed over through the creation parameters so
    // several menus never share state through a global.
    const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    self = static_cast<TrayMenu*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(self));
  }
  if (self != nullptr) {
    return self->HandleMessage(window, message, wparam, lparam);
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

LRESULT TrayMenu::HandleMessage(HWND window, UINT message, WPARAM wparam,
                                LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      RECT client{};
      GetClientRect(window, &client);
      Paint(window, client.right - client.left, client.bottom - client.top);
      return 0;
    }
    case WM_MOUSEMOVE: {
      const int index = ItemAt(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      if (index != hover_) {
        hover_ = index;
        InvalidateRect(window, nullptr, FALSE);
      }
      TRACKMOUSEEVENT track{};
      track.cbSize = sizeof(TRACKMOUSEEVENT);
      track.dwFlags = TME_LEAVE;
      track.hwndTrack = window;
      TrackMouseEvent(&track);
      return 0;
    }
    case WM_MOUSELEAVE:
      if (hover_ != -1) {
        hover_ = -1;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    case WM_LBUTTONUP: {
      const int index = ItemAt(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      if (index >= 0) {
        result_ = index;
        DestroyWindow(window);
      }
      return 0;
    }
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        DestroyWindow(window);
      }
      return 0;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        // Clicking anywhere else deactivates the popup, which is how every menu
        // closes. Before the first activation the message would be a false
        // positive and would swallow the menu instantly.
        if (activated_) {
          DestroyWindow(window);
        }
      } else {
        activated_ = true;
      }
      return 0;
    case WM_DESTROY:
      window_ = nullptr;
      finished_ = true;
      // Wake up the nested message loop in `Show`.
      PostThreadMessageW(GetCurrentThreadId(), WM_NULL, 0, 0);
      return 0;
    default:
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void TrayMenu::Layout(int scale) {
  scale_ = scale;
  const int padding = Scaled(kPadding, scale_);
  const int item_height = Scaled(kItemHeight, scale_);
  const int dot = Scaled(kDotSize, scale_);
  const int label_left = padding + Scaled(10, scale) + dot + Scaled(12, scale);

  width_ = Scaled(kWidth, scale_);
  const int header_height = Scaled(kHeaderHeight, scale_);

  dot_rect_ = {padding + Scaled(12, scale), Scaled(20, scale),
               padding + Scaled(12, scale) + dot, Scaled(20, scale) + dot};
  state_rect_ = {label_left, Scaled(11, scale), width_ - padding,
                 Scaled(29, scale)};
  detail_rect_ = {label_left, Scaled(30, scale), width_ - padding,
                  Scaled(48, scale)};

  item_rects_.clear();
  divider_ys_.clear();
  int y = header_height;
  for (int index = 0; index < static_cast<int>(items_.size()); ++index) {
    if (items_[static_cast<size_t>(index)].danger && index > 0) {
      divider_ys_.push_back(y + Scaled(kDividerHeight, scale_) / 2);
      y += Scaled(kDividerHeight, scale_);
    }
    item_rects_.push_back(
        {padding, y + Scaled(2, scale_), width_ - padding,
         y + item_height - Scaled(2, scale_)});
    y += item_height;
  }
  height_ = y + padding;
}

void TrayMenu::Paint(HWND window, int width, int height) {
  PAINTSTRUCT paint{};
  HDC dc = BeginPaint(window, &paint);
  if (dc == nullptr) {
    return;
  }

  // Everything is composed off-screen first, so the rounded corners never show
  // a flash of the desktop leaking through them.
  HDC buffer = CreateCompatibleDC(dc);
  HBITMAP bitmap =
      buffer == nullptr ? nullptr : CreateCompatibleBitmap(dc, width, height);
  if (buffer == nullptr || bitmap == nullptr) {
    if (bitmap != nullptr) {
      DeleteObject(bitmap);
    }
    if (buffer != nullptr) {
      DeleteDC(buffer);
    }
    EndPaint(window, &paint);
    return;
  }
  HGDIOBJ previous_bitmap = SelectObject(buffer, bitmap);

  const int radius = Scaled(kCornerRadius, scale_);
  const int padding = Scaled(kPadding, scale_);
  const RECT client{0, 0, width, height};
  FillRoundedRect(buffer, client, radius, kBackground);
  SetBkMode(buffer, TRANSPARENT);

  HFONT state_font = CreateUiFont(scale_, 10, true);
  HFONT detail_font = CreateUiFont(scale_, 8, false);
  HFONT item_font = CreateUiFont(scale_, 10, false);

  // Header ------------------------------------------------------------------
  FillEllipse(buffer, dot_rect_, connected_ ? kOnline : kFaint);
  HGDIOBJ previous_font =
      state_font == nullptr ? nullptr : SelectObject(buffer, state_font);
  SetTextColor(buffer, connected_ ? kOnline : kMuted);
  DrawTextW(buffer, state_.c_str(), -1, &state_rect_,
            DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);
  if (detail_font != nullptr) {
    SelectObject(buffer, detail_font);
  }
  SetTextColor(buffer, kFaint);
  DrawTextW(buffer, detail_.c_str(), -1, &detail_rect_,
            DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);

  // Divider above the closing item -----------------------------------------
  HPEN divider_pen = CreatePen(PS_SOLID, 1, kDivider);
  HGDIOBJ previous_pen = SelectObject(buffer, divider_pen);
  for (const int divider_y : divider_ys_) {
    MoveToEx(buffer, padding + Scaled(6, scale_), divider_y, nullptr);
    LineTo(buffer, width - padding - Scaled(6, scale_), divider_y);
  }
  SelectObject(buffer, previous_pen);
  DeleteObject(divider_pen);

  // Items -------------------------------------------------------------------
  if (item_font != nullptr && previous_font != nullptr) {
    SelectObject(buffer, item_font);
  }
  const int dot_size = Scaled(kDotSize, scale_);
  for (int index = 0; index < static_cast<int>(item_rects_.size()); ++index) {
    const RECT& item = item_rects_[static_cast<size_t>(index)];
    const bool hovered = index == hover_;
    if (hovered) {
      FillRoundedRect(buffer, item, Scaled(kItemRadius, scale_), kHighlight);
    }
    const int middle = (item.top + item.bottom) / 2;
    const int dot_left = item.left + Scaled(10, scale_);
    const RECT marker{dot_left, middle - dot_size / 2, dot_left + dot_size,
                      middle - dot_size / 2 + dot_size};
    const bool danger = items_[static_cast<size_t>(index)].danger;
    FillEllipse(buffer, marker, danger ? kDanger : kAccent);

    RECT label_rect{dot_left + dot_size + Scaled(12, scale_), item.top,
                    item.right - Scaled(10, scale_), item.bottom};
    SetTextColor(buffer, danger ? kDanger : kText);
    DrawTextW(buffer, items_[static_cast<size_t>(index)].label.c_str(), -1,
              &label_rect,
              DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);
  }

  if (previous_font != nullptr) {
    SelectObject(buffer, previous_font);
  }
  if (state_font != nullptr) {
    DeleteObject(state_font);
  }
  if (detail_font != nullptr) {
    DeleteObject(detail_font);
  }
  if (item_font != nullptr) {
    DeleteObject(item_font);
  }

  BitBlt(dc, 0, 0, width, height, buffer, 0, 0, SRCCOPY);

  SelectObject(buffer, previous_bitmap);
  DeleteObject(bitmap);
  DeleteDC(buffer);
  EndPaint(window, &paint);
}

int TrayMenu::ItemAt(int x, int y) const {
  for (int index = 0; index < static_cast<int>(item_rects_.size()); ++index) {
    const RECT& item = item_rects_[static_cast<size_t>(index)];
    if (x >= item.left && x < item.right && y >= item.top && y < item.bottom) {
      return index;
    }
  }
  return -1;
}

int TrayMenu::Show(HWND owner, bool connected, const std::wstring& state,
                   const std::wstring& detail,
                   const std::vector<Item>& items) {
  if (owner == nullptr || items.empty()) {
    return -1;
  }
  EnsureWindowClass();

  connected_ = connected;
  state_ = state;
  detail_ = detail;
  items_ = items;
  hover_ = -1;
  result_ = -1;
  finished_ = false;
  activated_ = false;

  Layout(PrimaryScalePercent());

  POINT cursor{};
  GetCursorPos(&cursor);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  GetMonitorInfoW(MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST),
                  &monitor_info);
  const RECT work = monitor_info.rcWork;

  // Anchored to the cursor: above it when there is room (which is the case for
  // the tray corner at the bottom of the screen), below it otherwise.
  int left = cursor.x - width_ + Scaled(24, scale_);
  int top = cursor.y - height_ - Scaled(8, scale_);
  if (top < work.top) {
    top = cursor.y + Scaled(8, scale_);
  }
  if (left < work.left) {
    left = work.left + Scaled(4, scale_);
  }
  if (left + width_ > work.right) {
    left = work.right - width_ - Scaled(4, scale_);
  }
  if (top + height_ > work.bottom) {
    top = work.bottom - height_ - Scaled(4, scale_);
  }

  window_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kMenuClassName,
                            L"ScaleGuard", WS_POPUP, left, top, width_, height_,
                            owner, nullptr, GetModuleHandleW(nullptr), this);
  if (window_ == nullptr) {
    return -1;
  }

  HRGN region = CreateRoundRectRgn(0, 0, width_ + 1, height_ + 1,
                                   Scaled(kCornerRadius, scale_) * 2,
                                   Scaled(kCornerRadius, scale_) * 2);
  if (region != nullptr) {
    // The window takes ownership of the region; it must not be deleted here.
    SetWindowRgn(window_, region, TRUE);
  }

  ShowWindow(window_, SW_SHOWNA);
  SetForegroundWindow(window_);
  UpdateWindow(window_);

  // The nested loop is what makes the menu behave like a menu: it stays up
  // until the user chooses something or clicks away, and the caller then acts
  // on the result. `TrackPopupMenu` does exactly the same internally.
  MSG message{};
  while (!finished_) {
    if (GetMessageW(&message, nullptr, 0, 0) == 0) {
      break;
    }
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  if (window_ != nullptr) {
    DestroyWindow(window_);
  }
  finished_ = false;
  return result_;
}
