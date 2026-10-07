#ifndef SHADOWBAT_TRAY_PANEL_H_
#define SHADOWBAT_TRAY_PANEL_H_
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <functional>
#include <memory>
#include <string>

// Win32 owns the transient shell. Flutter renders all content; the main
// repository remains the only owner of credentials, proxy settings and core.
class TrayPanel {
public:
  using Map = flutter::EncodableMap;
  using Action = std::function<void(const std::string &, Map)>;
  TrayPanel(HWND owner, Action action);
  ~TrayPanel();
  void Prepare();
  void Update(const Map &state);
  void Toggle(const RECT &anchor);
  void Hide();
private:
  static LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM);
  void Position();
  void ResizeView();
  int Scale(int value) const;
  HWND owner_, window_ = nullptr;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  UINT dpi_ = 96;
  int height_ = 386;
  ULONGLONG dismissed_ = 0;
  RECT anchor_{};
  Map state_;
  Action action_;
};
#endif
