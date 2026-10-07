#include "tray_panel.h"
#include <algorithm>
#include <dwmapi.h>
#include <flutter/dart_project.h>
#include <flutter/standard_method_codec.h>
#include "flutter/generated_plugin_registrant.h"
#include <utility>
#include <optional>

namespace {
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
bool Flag(const M &state, const char *key) {
  auto found = state.find(V(key));
  auto flag = found == state.end() ? nullptr : std::get_if<bool>(&found->second);
  return flag && *flag;
}
} // namespace

TrayPanel::TrayPanel(HWND owner, Action action) : owner_(owner), action_(std::move(action)) {}
TrayPanel::~TrayPanel() {
  channel_.reset();
  controller_.reset();
  if (window_) DestroyWindow(window_);
}
int TrayPanel::Scale(int value) const { return MulDiv(value, static_cast<int>(dpi_), 96); }
void TrayPanel::Prepare() {
  if (window_) return;
  WNDCLASS wc{};
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = L"ShadowbatTrayPanel";
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.style = CS_DROPSHADOW;
  RegisterClass(&wc);
  window_ = CreateWindowEx(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, wc.lpszClassName, L"Shadowbat 托盘",
      WS_POPUP | WS_CLIPCHILDREN, 0, 0, 320, height_, owner_, nullptr, wc.hInstance, this);
  if (!window_) return;
  dpi_ = GetDpiForWindow(window_);
  SetWindowPos(window_, nullptr, 0, 0, Scale(320), Scale(height_), SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  DWORD corners = 2;
  DwmSetWindowAttribute(window_, 33, &corners, sizeof(corners));
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments({"--tray-panel"});
  controller_ = std::make_unique<flutter::FlutterViewController>(Scale(320), Scale(height_), project);
  if (!controller_->engine() || !controller_->view()) { controller_.reset(); return; }
  RegisterPlugins(controller_->engine());
  auto view = controller_->view()->GetNativeWindow();
  SetParent(view, window_);
  channel_ = std::make_unique<flutter::MethodChannel<V>>(controller_->engine()->messenger(),
      "com.lingj.shadowbat/tray", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto &call, auto result) {
    if (call.method_name() == "snapshot") { result->Success(V(state_)); return; }
    if (call.method_name() == "hide") { Hide(); result->Success(); return; }
    if (call.method_name() == "command") {
      auto args = call.arguments() ? std::get_if<M>(call.arguments()) : nullptr;
      if (!args) { result->Error("tray", "缺少托盘命令。"); return; }
      auto name = args->find(V("name"));
      auto method = name == args->end() ? nullptr : std::get_if<std::string>(&name->second);
      if (!method) { result->Error("tray", "无效托盘命令。"); return; }
      auto values = args->find(V("arguments"));
      auto data = values == args->end() ? nullptr : std::get_if<M>(&values->second);
      if (*method == "showMainWindow" || *method == "quit") Hide();
      action_(*method, data ? *data : M{});
      result->Success();
      return;
    }
    result->NotImplemented();
  });
  controller_->engine()->SetNextFrameCallback([this] {
    if (IsWindowVisible(window_)) InvalidateRect(window_, nullptr, FALSE);
  });
  ResizeView();
  controller_->ForceRedraw();
}
void TrayPanel::ResizeView() {
  if (!controller_) return;
  RECT area{};
  GetClientRect(window_, &area);
  MoveWindow(controller_->view()->GetNativeWindow(), 0, 0, area.right, area.bottom, TRUE);
}
void TrayPanel::Position() {
  MONITORINFO monitor{sizeof(monitor)};
  GetMonitorInfo(MonitorFromRect(&anchor_, MONITOR_DEFAULTTONEAREST), &monitor);
  int width = Scale(320), height = Scale(height_);
  int x = (anchor_.left + anchor_.right - width) / 2;
  int y = anchor_.top - height - Scale(8);
  if (y < monitor.rcWork.top) y = anchor_.bottom + Scale(8);
  x = std::clamp(x, static_cast<int>(monitor.rcWork.left), std::max(static_cast<int>(monitor.rcWork.left), static_cast<int>(monitor.rcWork.right) - width));
  y = std::clamp(y, static_cast<int>(monitor.rcWork.top), std::max(static_cast<int>(monitor.rcWork.top), static_cast<int>(monitor.rcWork.bottom) - height));
  SetWindowPos(window_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
}
void TrayPanel::Update(const Map &state) {
  state_ = state;
  int height = 386 + (Flag(state_, "recoveryNeeded") ? 42 : 0);
  auto error = state_.find(V("errorMessage"));
  auto text = error == state_.end() ? nullptr : std::get_if<std::string>(&error->second);
  if (text && !text->empty()) height += 56;
  bool changed = height_ != height;
  height_ = height;
  if (window_ && changed) Position();
  if (channel_) channel_->InvokeMethod("stateChanged", std::make_unique<V>(state_));
}
void TrayPanel::Toggle(const RECT &anchor) {
  if (window_ && IsWindowVisible(window_)) { Hide(); return; }
  if (GetTickCount64() - dismissed_ < 250) return;
  anchor_ = anchor;
  Prepare();
  if (!controller_) return;
  SetWindowPos(window_, nullptr, anchor.left, anchor.top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  dpi_ = GetDpiForWindow(window_);
  Position();
  ::ShowWindow(window_, SW_SHOW);
  SetForegroundWindow(window_);
  SetFocus(controller_->view()->GetNativeWindow());
  controller_->ForceRedraw();
}
void TrayPanel::Hide() {
  if (window_) ::ShowWindow(window_, SW_HIDE);
  dismissed_ = GetTickCount64();
}
LRESULT CALLBACK TrayPanel::WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto self = reinterpret_cast<TrayPanel *>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<TrayPanel *>(reinterpret_cast<CREATESTRUCT *>(lparam)->lpCreateParams);
    self->window_ = window;
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(window, message, wparam, lparam);
  std::optional<LRESULT> flutter_result;
  if (self->controller_) flutter_result = self->controller_->HandleTopLevelWindowProc(window, message, wparam, lparam);
  switch (message) {
  case WM_ACTIVATE:
    if (LOWORD(wparam) == WA_INACTIVE) self->Hide();
    break;
  case WM_CLOSE: self->Hide(); return 0;
  case WM_SIZE: self->ResizeView(); return 0;
  case WM_DPICHANGED: self->dpi_ = HIWORD(wparam); self->Position(); self->ResizeView(); return 0;
  }
  if (flutter_result) return *flutter_result;
  return DefWindowProc(window, message, wparam, lparam);
}
