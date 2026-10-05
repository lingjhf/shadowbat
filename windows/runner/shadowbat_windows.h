#ifndef SHADOWBAT_WINDOWS_H_
#define SHADOWBAT_WINDOWS_H_
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
#include <string>
#include <vector>
#include <windows.h>

// Win32 owns the tray, credentials, proxy transaction, and child process
// lifetime.
class ShadowbatWindows {
public:
  ShadowbatWindows(HWND window, flutter::BinaryMessenger *messenger);
  ~ShadowbatWindows();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     LRESULT *result);
  static bool HandleUtility(const std::vector<std::string> &arguments);
  static HANDLE AcquireInstance(bool preview);

private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  void Handle(const flutter::MethodCall<Value> &call,
              std::unique_ptr<flutter::MethodResult<Value>> result);
  void ShowWindow();
  void ShowMenu();
  void Action(const std::string &name, Map arguments = {});
  void InstallTray();
  HWND window_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  HANDLE core_ = nullptr, job_ = nullptr;
  DWORD core_pid_ = 0;
  std::wstring directory_, executable_;
  std::wstring registry_;
  bool preview_ = false;
  Map state_;
  UINT taskbar_created_;
};
#endif
