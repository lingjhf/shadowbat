#ifndef SHADOWBAT_WINDOWS_H_
#define SHADOWBAT_WINDOWS_H_
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <string>
#include <vector>
#include <windows.h>

class TrayPanel;

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
  void PrepareTray();

private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  void Handle(const flutter::MethodCall<Value> &call,
              std::unique_ptr<flutter::MethodResult<Value>> result);
  void Execute(const flutter::MethodCall<Value> &call,
               std::unique_ptr<flutter::MethodResult<Value>> result);
  void QueueWork(std::function<void()> work);
  void QueueReply(std::function<void()> reply);
  void DrainReplies();
  std::mutex work_mutex_;
  std::condition_variable work_ready_;
  std::deque<std::function<void()>> work_, replies_;
  std::thread worker_;
  std::vector<std::shared_ptr<flutter::MethodResult<Value>>> pending_results_;
  bool stopping_ = false;
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
  bool exiting_ = false;
  Map state_;
  std::unique_ptr<TrayPanel> tray_panel_;
  UINT taskbar_created_;
};
#endif
