#include "shadowbat_windows.h"
#include "resource.h"
#include "tray_panel.h"
#include <aclapi.h>
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <flutter/standard_method_codec.h>
#include <fstream>
#include <iterator>
#include <sddl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wincred.h>
#include <wininet.h>

namespace {
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
constexpr UINT kTray = WM_APP + 42;
constexpr UINT kNativeReply = WM_APP + 43;
struct NativeReply {
  enum Kind { success, error, missing } kind = success;
  V value;
  std::string code, message;
};
// Copy the reply on the worker; the engine-facing MethodResult stays on the UI thread.
class DeferredResult : public flutter::MethodResult<V> {
public:
  explicit DeferredResult(std::function<void(NativeReply)> reply) : reply_(std::move(reply)) {}
protected:
  void SuccessInternal(const V *value) override {
    NativeReply reply;
    if (value) reply.value = *value;
    reply_(std::move(reply));
  }
  void ErrorInternal(const std::string &code, const std::string &message, const V *details) override {
    NativeReply reply;
    reply.kind = NativeReply::error;
    reply.code = code;
    reply.message = message;
    if (details) reply.value = *details;
    reply_(std::move(reply));
  }
  void NotImplementedInternal() override {
    NativeReply reply;
    reply.kind = NativeReply::missing;
    reply_(std::move(reply));
  }
private:
  std::function<void(NativeReply)> reply_;
};
HICON NetworkIcon(bool connected) {
  constexpr int size = 32;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  void *pixels = nullptr;
  HDC dc = CreateCompatibleDC(nullptr);
  HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!dc || !bitmap || !pixels) {
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
    return nullptr;
  }
  memset(pixels, 0, size * size * 4);
  auto oldBitmap = SelectObject(dc, bitmap);
  DWORD light = 0, bytes = sizeof(light);
  RegGetValue(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &bytes);
  auto pen = CreatePen(PS_SOLID, 2, connected ? (light ? RGB(35, 35, 40) : RGB(245, 245, 250)) : RGB(150, 150, 155));
  auto oldPen = SelectObject(dc, pen);
  auto oldBrush = SelectObject(dc, GetStockObject(NULL_BRUSH));
  RoundRect(dc, 11, 3, 22, 12, 3, 3);
  MoveToEx(dc, 16, 12, nullptr); LineTo(dc, 16, 19);
  MoveToEx(dc, 7, 22, nullptr); LineTo(dc, 7, 18); LineTo(dc, 25, 18); LineTo(dc, 25, 22);
  RoundRect(dc, 2, 22, 13, 30, 3, 3);
  RoundRect(dc, 20, 22, 31, 30, 3, 3);
  if (!connected) { MoveToEx(dc, 3, 2, nullptr); LineTo(dc, 30, 30); }
  GdiFlush();
  auto data = static_cast<DWORD *>(pixels);
  for (int i = 0; i < size * size; ++i) if (data[i] & 0x00ffffff) data[i] |= 0xff000000;
  BYTE maskPixels[size * size / 8]{};
  HBITMAP mask = CreateBitmap(size, size, 1, 1, maskPixels);
  ICONINFO iconInfo{TRUE, 0, 0, mask, bitmap};
  HICON icon = CreateIconIndirect(&iconInfo);
  SelectObject(dc, oldBrush);
  SelectObject(dc, oldPen);
  SelectObject(dc, oldBitmap);
  DeleteObject(pen);
  DeleteObject(bitmap);
  DeleteObject(mask);
  DeleteDC(dc);
  return icon;
}
constexpr wchar_t kProxyKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
std::wstring Wide(const std::string &s) {
  if (s.empty())
    return {};
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                              static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                      static_cast<int>(s.size()), out.data(), n);
  return out;
}
std::string Utf8(const std::wstring &s) {
  if (s.empty())
    return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                              nullptr, 0, nullptr, nullptr);
  std::string out(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), n, nullptr, nullptr);
  return out;
}
const V *Get(const M &m, const char *key) {
  auto i = m.find(V(key));
  return i == m.end() ? nullptr : &i->second;
}
std::string Text(const M &m, const char *key) {
  auto v = Get(m, key);
  auto s = v ? std::get_if<std::string>(v) : nullptr;
  return s ? *s : "";
}
bool Flag(const M &m, const char *key) {
  auto v = Get(m, key);
  auto b = v ? std::get_if<bool>(v) : nullptr;
  return b && *b;
}
int Integer(const M &m, const char *key) {
  auto v = Get(m, key);
  auto n = v ? std::get_if<int32_t>(v) : nullptr;
  return n ? *n : 0;
}
std::wstring Exe() {
  wchar_t path[32768]{};
  GetModuleFileName(nullptr, path, 32768);
  return path;
}
std::wstring Quote(const std::wstring &s) { return L"\"" + s + L"\""; }
bool Admin() {
  SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
  PSID sid = nullptr;
  BOOL member = FALSE;
  if (AllocateAndInitializeSid(&authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
                               DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                               &sid)) {
    CheckTokenMembership(nullptr, sid, &member);
    FreeSid(sid);
  }
  return member != FALSE;
}
std::wstring UserSID() {
  HANDLE token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
    return L"";
  DWORD count = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &count);
  std::vector<BYTE> data(count);
  if (!GetTokenInformation(token, TokenUser, data.data(), count, &count)) {
    CloseHandle(token);
    return L"";
  }
  LPWSTR sid = nullptr;
  ConvertSidToStringSid(reinterpret_cast<TOKEN_USER *>(data.data())->User.Sid,
                        &sid);
  std::wstring out = sid ? sid : L"";
  if (sid)
    LocalFree(sid);
  CloseHandle(token);
  return out;
}
bool Secure(const std::wstring &path) {
  auto sddl =
      L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;" + UserSID() + L")";
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
          sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr))
    return false;
  BOOL present, defaulted;
  PACL dacl;
  GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted);
  DWORD code = SetNamedSecurityInfo(
      const_cast<wchar_t *>(path.c_str()), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr,
      nullptr, dacl, nullptr);
  LocalFree(descriptor);
  return code == ERROR_SUCCESS;
}
std::wstring RegName(bool preview) {
  return preview ? L"Software\\Shadowbat\\Preview" : L"Software\\Shadowbat";
}
void NotifyProxy() {
  InternetSetOption(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOption(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}
// Preserve exact registry presence, type and bytes, including disabled PAC
// settings.
struct RegValue {
  DWORD type = 0;
  std::vector<BYTE> bytes;
  bool exists = false;
};
const wchar_t *kFields[] = {L"ProxyEnable", L"ProxyServer", L"ProxyOverride",
                            L"AutoConfigURL"};
RegValue Read(HKEY key, const wchar_t *name) {
  RegValue v;
  DWORD size = 0;
  if (RegQueryValueEx(key, name, nullptr, &v.type, nullptr, &size) !=
      ERROR_SUCCESS)
    return v;
  if (size > 65536)
    return v;
  v.bytes.resize(size);
  v.exists = true;
  if (RegQueryValueEx(key, name, nullptr, &v.type, v.bytes.data(), &size) !=
      ERROR_SUCCESS)
    v.exists = false;
  return v;
}
bool Write(HKEY key, const wchar_t *name, const RegValue &value) {
  auto status =
      value.exists ? RegSetValueEx(key, name, 0, value.type, value.bytes.data(),
                                   static_cast<DWORD>(value.bytes.size()))
                   : RegDeleteValue(key, name);
  return status == ERROR_SUCCESS ||
         (!value.exists && status == ERROR_FILE_NOT_FOUND);
}
RegValue StringValue(const std::wstring &s) {
  RegValue v;
  v.exists = true;
  v.type = REG_SZ;
  v.bytes.resize((s.size() + 1) * sizeof(wchar_t));
  memcpy(v.bytes.data(), s.c_str(), v.bytes.size());
  return v;
}
RegValue NumberValue(DWORD n) {
  RegValue v;
  v.exists = true;
  v.type = REG_DWORD;
  v.bytes.resize(sizeof(n));
  memcpy(v.bytes.data(), &n, sizeof(n));
  return v;
}
std::wstring SettingsKey(const std::wstring &registry) {
  return registry == RegName(true) ? registry + L"\\InternetSettings"
                                   : kProxyKey;
}
DWORD ProxyFlags(const std::wstring &registry) {
  if (registry == RegName(true)) {
    DWORD flags = PROXY_TYPE_DIRECT, size = sizeof(flags);
    RegGetValue(HKEY_CURRENT_USER, SettingsKey(registry).c_str(), L"Flags",
                RRF_RT_REG_DWORD, nullptr, &flags, &size);
    return flags;
  }
  INTERNET_PER_CONN_OPTION option{};
  option.dwOption = INTERNET_PER_CONN_FLAGS;
  INTERNET_PER_CONN_OPTION_LIST list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 1;
  list.pOptions = &option;
  DWORD size = sizeof(list);
  if (!InternetQueryOption(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                           &list, &size))
    return PROXY_TYPE_DIRECT;
  return option.Value.dwValue;
}
bool ApplyOptions(const std::vector<RegValue> &fields,
                  const std::wstring &registry) {
  INTERNET_PER_CONN_OPTION options[4]{};
  DWORD flags = PROXY_TYPE_DIRECT;
  memcpy(&flags, fields[4].bytes.data(), sizeof(flags));
  if (registry == RegName(true)) {
    HKEY key;
    if (RegCreateKeyEx(HKEY_CURRENT_USER, SettingsKey(registry).c_str(), 0,
                       nullptr, 0, KEY_WRITE, nullptr, &key,
                       nullptr) != ERROR_SUCCESS)
      return false;
    auto code = RegSetValueEx(key, L"Flags", 0, REG_DWORD,
                              reinterpret_cast<BYTE *>(&flags), sizeof(flags));
    RegCloseKey(key);
    return code == ERROR_SUCCESS;
  }
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = flags;
  auto str = [](const RegValue &value) {
    return value.exists && value.bytes.size() >= sizeof(wchar_t)
               ? std::wstring(
                     reinterpret_cast<const wchar_t *>(value.bytes.data()),
                     value.bytes.size() / sizeof(wchar_t) - 1)
               : std::wstring();
  };
  auto server = str(fields[1]), bypass = str(fields[2]), pac = str(fields[3]);
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = server.data();
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = bypass.data();
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = pac.data();
  INTERNET_PER_CONN_OPTION_LIST list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 4;
  list.pOptions = options;
  return InternetSetOption(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                           &list, sizeof(list)) != FALSE;
}
void Append(std::vector<BYTE> &buffer, DWORD n) {
  auto ptr = reinterpret_cast<BYTE *>(&n);
  buffer.insert(buffer.end(), ptr, ptr + 4);
}
std::vector<BYTE> Serialize(const std::vector<RegValue> &fields) {
  std::vector<BYTE> b;
  for (const auto &v : fields) {
    Append(b, v.exists ? 1 : 0);
    Append(b, v.type);
    Append(b, static_cast<DWORD>(v.bytes.size()));
    b.insert(b.end(), v.bytes.begin(), v.bytes.end());
  }
  return b;
}
bool Deserialize(const std::vector<BYTE> &b, std::vector<RegValue> *fields) {
  size_t offset = 0;
  for (int i = 0; i < 5; i++) {
    if (offset + 12 > b.size())
      return false;
    DWORD h[3];
    memcpy(h, b.data() + offset, 12);
    offset += 12;
    if (h[2] > 65536 || offset + h[2] > b.size())
      return false;
    RegValue v;
    v.exists = h[0] != 0;
    v.type = h[1];
    v.bytes.assign(b.begin() + offset, b.begin() + offset + h[2]);
    offset += h[2];
    fields->push_back(v);
  }
  return offset == b.size() && fields->size() == 5 &&
         (*fields)[4].type == REG_DWORD &&
         (*fields)[4].bytes.size() == sizeof(DWORD);
}
bool HasBackup(const std::wstring &registry) {
  HKEY key;
  if (RegOpenKeyEx(HKEY_CURRENT_USER, registry.c_str(), 0, KEY_READ, &key) !=
      ERROR_SUCCESS)
    return false;
  auto v = Read(key, L"ProxyBackup");
  RegCloseKey(key);
  return v.exists;
}
// Restore the protocol group only if it still matches our applied values.
bool RestoreProxy(const std::wstring &registry, bool *conflict) {
  *conflict = false;
  HKEY saved;
  if (RegOpenKeyEx(HKEY_CURRENT_USER, registry.c_str(), 0, KEY_READ | KEY_WRITE,
                   &saved) != ERROR_SUCCESS)
    return true;
  auto backup = Read(saved, L"ProxyBackup"),
       applied = Read(saved, L"ProxyApplied");
  if (!backup.exists) {
    RegCloseKey(saved);
    return true;
  }
  std::vector<RegValue> before, ours;
  if (!Deserialize(backup.bytes, &before) ||
      !Deserialize(applied.bytes, &ours)) {
    RegCloseKey(saved);
    return false;
  }
  HKEY current;
  if (RegCreateKeyEx(HKEY_CURRENT_USER, SettingsKey(registry).c_str(), 0,
                     nullptr, 0, KEY_READ | KEY_WRITE, nullptr, &current,
                     nullptr) != ERROR_SUCCESS) {
    RegCloseKey(saved);
    return false;
  }
  bool match = ProxyFlags(registry) ==
               *reinterpret_cast<const DWORD *>(ours[4].bytes.data());
  for (int i = 0; i < 4; i++) {
    auto now = Read(current, kFields[i]);
    if (now.exists != ours[i].exists || now.type != ours[i].type ||
        now.bytes != ours[i].bytes)
      match = false;
  }
  bool ok = true;
  if (match) {
    ok = ApplyOptions(before, registry);
    for (int i = 0; i < 4; i++)
      ok = Write(current, kFields[i], before[i]) && ok;
  } else
    *conflict = true;
  if (ok) {
    RegDeleteValue(saved, L"ProxyBackup");
    RegDeleteValue(saved, L"ProxyApplied");
    RegFlushKey(saved);
  }
  RegCloseKey(current);
  RegCloseKey(saved);
  if (registry != RegName(true))
    NotifyProxy();
  return ok;
}
bool SpawnUtility(const std::wstring &args, HANDLE *process = nullptr) {
  auto exe = Exe();
  auto command = Quote(exe) + L" " + args;
  STARTUPINFO startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION info{};
  if (!CreateProcess(exe.c_str(), command.data(), nullptr, nullptr, FALSE,
                     CREATE_NO_WINDOW, nullptr, nullptr, &startup, &info))
    return false;
  CloseHandle(info.hThread);
  if (process)
    *process = info.hProcess;
  else
    CloseHandle(info.hProcess);
  return true;
}
bool EnableProxy(const std::wstring &registry, int port, bool preview) {
  if (port < 1024 || port > 65535 || HasBackup(registry))
    return false;
  HKEY current, saved;
  if (RegCreateKeyEx(HKEY_CURRENT_USER, SettingsKey(registry).c_str(), 0,
                     nullptr, 0, KEY_READ | KEY_WRITE, nullptr, &current,
                     nullptr) != ERROR_SUCCESS)
    return false;
  if (RegCreateKeyEx(HKEY_CURRENT_USER, registry.c_str(), 0, nullptr, 0,
                     KEY_READ | KEY_WRITE, nullptr, &saved,
                     nullptr) != ERROR_SUCCESS) {
    RegCloseKey(current);
    return false;
  }
  std::vector<RegValue> before;
  for (auto field : kFields)
    before.push_back(Read(current, field));
  before.push_back(NumberValue(ProxyFlags(registry)));
  auto proxy = L"http=127.0.0.1:" + std::to_wstring(port) +
               L";https=127.0.0.1:" + std::to_wstring(port);
  std::vector<RegValue> ours{NumberValue(1), StringValue(proxy),
                             StringValue(L"localhost;127.*;[::1];<local>"),
                             RegValue{},
                             NumberValue(PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY)};
  auto a = Serialize(before), b = Serialize(ours);
  bool ok = RegSetValueEx(saved, L"ProxyBackup", 0, REG_BINARY, a.data(),
                          static_cast<DWORD>(a.size())) == ERROR_SUCCESS;
  ok = RegSetValueEx(saved, L"ProxyApplied", 0, REG_BINARY, b.data(),
                     static_cast<DWORD>(b.size())) == ERROR_SUCCESS &&
       ok;
  RegFlushKey(saved);
  if (ok) {
    ok = ApplyOptions(ours, registry);
    for (int i = 0; i < 4; i++)
      ok = Write(current, kFields[i], ours[i]) && ok;
  }
  if (!ok) {
    bool rollback = ApplyOptions(before, registry);
    for (int i = 0; i < 4; i++)
      rollback = Write(current, kFields[i], before[i]) && rollback;
    if (rollback) {
      RegDeleteValue(saved, L"ProxyBackup");
      RegDeleteValue(saved, L"ProxyApplied");
    }
  }
  RegCloseKey(current);
  RegCloseKey(saved);
  if (registry != RegName(true))
    NotifyProxy();
  if (!ok) {
    bool conflict;
    RestoreProxy(registry, &conflict);
    return false;
  }
  // Detached watcher restores preferences even if the Flutter process crashes.
  auto args = L"--proxy-watchdog " + std::to_wstring(GetCurrentProcessId()) +
              (preview ? L" --isolated-preview" : L"");
  if (!SpawnUtility(args)) {
    bool conflict;
    RestoreProxy(registry, &conflict);
    return false;
  }
  return true;
}
} // namespace

ShadowbatWindows::ShadowbatWindows(HWND window,
                                   flutter::BinaryMessenger *messenger)
    : window_(window) {
  preview_ = std::wstring(GetCommandLine()).find(L"--isolated-preview") !=
             std::wstring::npos;
  registry_ = RegName(preview_);
  executable_ = Exe();
  PWSTR local = nullptr;
  SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local);
  directory_ =
      std::wstring(local ? local : L".") + L"\\Shadowbat" +
      (preview_ ? L"\\preview-" + std::to_wstring(GetCurrentProcessId()) : L"");
  if (local)
    CoTaskMemFree(local);
  job_ = CreateJobObject(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (job_)
    SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &limits,
                            sizeof(limits));
  channel_ = std::make_unique<flutter::MethodChannel<V>>(
      messenger, "com.lingj.shadowbat/windows",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto &call, auto result) {
    Handle(call, std::move(result));
  });
  worker_ = std::thread([this] {
    HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    for (;;) {
      std::function<void()> work;
      {
        std::unique_lock<std::mutex> lock(work_mutex_);
        work_ready_.wait(lock, [this] { return stopping_ || !work_.empty(); });
        if (stopping_ && work_.empty()) break;
        work = std::move(work_.front());
        work_.pop_front();
      }
      work();
    }
    if (SUCCEEDED(com)) CoUninitialize();
  });
  taskbar_created_ = RegisterWindowMessage(L"TaskbarCreated");
  InstallTray();
}
ShadowbatWindows::~ShadowbatWindows() {
  channel_->SetMethodCallHandler(nullptr);
  {
    std::lock_guard<std::mutex> lock(work_mutex_);
    // Drain accepted work, including shutdown proxy restoration, before releasing handles.
    stopping_ = true;
  }
  work_ready_.notify_one();
  if (worker_.joinable()) worker_.join();
  replies_.clear();
  pending_results_.clear();
  NOTIFYICONDATA icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window_;
  icon.uID = 1;
  Shell_NotifyIcon(NIM_DELETE, &icon);
  if (core_)
    CloseHandle(core_);
  if (job_)
    CloseHandle(job_);
}
void ShadowbatWindows::InstallTray() {
  if (exiting_) return;
  NOTIFYICONDATA icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window_;
  icon.uID = 1;
  icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon.uCallbackMessage = kTray;
  HICON network = NetworkIcon(Text(state_, "state") == "connected");
  icon.hIcon = network ? network : LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"Shadowbat");
  Shell_NotifyIcon(NIM_ADD, &icon);
  if (network) DestroyIcon(network);
  icon.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIcon(NIM_SETVERSION, &icon);
}
void ShadowbatWindows::ShowWindow() {
  if (exiting_) return;
  if (tray_panel_) tray_panel_->Hide();
  ::ShowWindow(window_, SW_RESTORE);
  SetForegroundWindow(window_);
}
void ShadowbatWindows::Action(const std::string &name, M args) {
  channel_->InvokeMethod(name, std::make_unique<V>(args));
}
void ShadowbatWindows::PrepareTray() {
  if (!tray_panel_) {
    tray_panel_ = std::make_unique<TrayPanel>(window_, [this](const std::string &name, M args) {
      if (name == "showMainWindow") ShowWindow();
      else Action(name, std::move(args));
    });
    tray_panel_->Update(state_);
    tray_panel_->Prepare();
  }
}
void ShadowbatWindows::ShowMenu() {
  if (exiting_) return;
  PrepareTray();
  NOTIFYICONIDENTIFIER identifier{};
  identifier.cbSize = sizeof(identifier);
  identifier.hWnd = window_;
  identifier.uID = 1;
  RECT anchor{};
  if (FAILED(Shell_NotifyIconGetRect(&identifier, &anchor))) {
    POINT cursor{};
    GetCursorPos(&cursor);
    anchor = {cursor.x, cursor.y, cursor.x + 1, cursor.y + 1};
  }
  tray_panel_->Toggle(anchor);
}
bool ShadowbatWindows::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                     LRESULT *result) {
  if (message == kNativeReply) {
    DrainReplies();
    *result = 0;
    return true;
  }
  if (message == taskbar_created_) {
    InstallTray();
    *result = 0;
    return true;
  }
  if (message == WM_CLOSE) {
    ::ShowWindow(window_, SW_HIDE);
    *result = 0;
    return true;
  }
  if (message == kTray) {
    UINT notification = LOWORD(lparam);
    if (notification == WM_LBUTTONDBLCLK)
      ShowWindow();
    else if (notification == WM_CONTEXTMENU || notification == NIN_SELECT || notification == NIN_KEYSELECT)
      ShowMenu();
    *result = 0;
    return true;
  }
  if (message == WM_QUERYENDSESSION) {
    // Restoration is serialized with any in-flight proxy transaction. The detached
    // watchdog also restores the backup if Windows terminates us before this runs.
    QueueWork([this] { bool conflict; RestoreProxy(registry_, &conflict); });
    *result = TRUE;
    return true;
  }
  if (message == WM_GETMINMAXINFO) {
    auto limits = reinterpret_cast<MINMAXINFO *>(lparam);
    auto dpi = GetDpiForWindow(window_);
    limits->ptMinTrackSize = {MulDiv(360, static_cast<int>(dpi), 96),
                              MulDiv(640, static_cast<int>(dpi), 96)};
    *result = 0;
    return true;
  }
  if (message == WM_COMMAND && LOWORD(wparam) == IDCANCEL) {
    ::ShowWindow(window_, SW_HIDE);
    *result = 0;
    return true;
  }
  return false;
}
void ShadowbatWindows::QueueWork(std::function<void()> work) {
  {
    std::lock_guard<std::mutex> lock(work_mutex_);
    if (stopping_) return;
    work_.push_back(std::move(work));
  }
  work_ready_.notify_one();
}
void ShadowbatWindows::QueueReply(std::function<void()> reply) {
  std::lock_guard<std::mutex> lock(work_mutex_);
  if (stopping_) return;
  replies_.push_back(std::move(reply));
  PostMessage(window_, kNativeReply, 0, 0);
}
void ShadowbatWindows::DrainReplies() {
  std::deque<std::function<void()>> replies;
  {
    std::lock_guard<std::mutex> lock(work_mutex_);
    replies.swap(replies_);
  }
  for (auto &reply : replies) reply();
}
void ShadowbatWindows::Handle(const flutter::MethodCall<V> &call,
                             std::unique_ptr<flutter::MethodResult<V>> result) {
  auto name = call.method_name();
  if (name == "updateTray" || name == "restartElevated" || name == "quit" ||
      name == "beginShutdown" || name == "cancelShutdown") {
    Execute(call, std::move(result));
    return;
  }
  // MethodCall arguments are owned by the incoming callback, so copy before queuing.
  V arguments = call.arguments() ? *call.arguments() : V();
  auto response = std::shared_ptr<flutter::MethodResult<V>>(std::move(result));
  pending_results_.push_back(response);
  QueueWork([this, name, arguments = std::move(arguments), response] {
    auto reply = [this, response](NativeReply answer) {
      QueueReply([this, response, answer = std::move(answer)] {
        if (answer.kind == NativeReply::success) response->Success(answer.value);
        else if (answer.kind == NativeReply::error) response->Error(answer.code, answer.message, answer.value);
        else response->NotImplemented();
        pending_results_.erase(std::remove(pending_results_.begin(), pending_results_.end(), response), pending_results_.end());
      });
    };
    try {
      flutter::MethodCall<V> work(name, std::make_unique<V>(arguments));
      Execute(work, std::make_unique<DeferredResult>(reply));
    } catch (...) {
      NativeReply error;
      error.kind = NativeReply::error;
      error.code = "windows";
      error.message = "原生后台操作失败。";
      reply(std::move(error));
    }
  });
}
void ShadowbatWindows::Execute(
    const flutter::MethodCall<V> &call,
    std::unique_ptr<flutter::MethodResult<V>> result) {
  auto args = call.arguments() ? std::get_if<M>(call.arguments()) : nullptr;
  M empty;
  const auto &a = args ? *args : empty;
  auto name = call.method_name();
  auto fail = [&](const char *message) { result->Error("windows", message); };
  if (name == "beginShutdown") {
    exiting_ = true;
    if (tray_panel_) tray_panel_->Hide();
    ::ShowWindow(window_, SW_HIDE);
    NOTIFYICONDATA icon{};
    icon.cbSize = sizeof(icon);
    icon.hWnd = window_;
    icon.uID = 1;
    Shell_NotifyIcon(NIM_DELETE, &icon);
    result->Success(V(!IsWindowVisible(window_)));
    return;
  }
  if (name == "cancelShutdown") {
    exiting_ = false;
    InstallTray();
    ShowWindow();
    result->Success();
    return;
  }
  if (name == "testWorkerDelay" && preview_ &&
      std::wstring(GetCommandLine()).find(L"--self-test") != std::wstring::npos) {
    // Deliberately slow only in the existing opt-in, isolated integration test.
    Sleep(1200);
    result->Success();
    return;
  }
  if (name == "initialize") {
    std::error_code error;
    std::filesystem::create_directories(directory_, error);
    if (error || !Secure(directory_)) {
      fail("无法创建私有配置目录。");
      return;
    }
    PWSTR documents = nullptr;
    SHGetKnownFolderPath(FOLDERID_Documents, 0, nullptr, &documents);
    std::wstring doc =
        preview_ ? directory_ : std::wstring(documents ? documents : L"");
    if (documents)
      CoTaskMemFree(documents);
    result->Success(V(
        M{{V("directory"), V(Utf8(directory_))},
          {V("core"),
           V(Utf8(std::filesystem::path(executable_).parent_path().wstring() +
                  L"\\cores\\sing-box.exe"))},
          {V("admin"), V(Admin())},
          {V("shellProfiles"),
           V(flutter::EncodableList{
               V(Utf8(doc + L"\\PowerShell\\Microsoft.PowerShell_profile.ps1")),
               V(Utf8(doc + L"\\WindowsPowerShell\\Microsoft.PowerShell_"
                            L"profile.ps1"))})}}));
    return;
  }
  if (name == "isAdministrator") {
    result->Success(V(Admin()));
    return;
  }
  if (name == "secureFile") {
    auto path = Wide(Text(a, "path"));
    if (path.find(directory_ + L"\\") != 0 && path != directory_) {
      fail("文件不属于 Shadowbat 配置目录。");
      return;
    }
    if (!Secure(path)) {
      fail("无法设置私有文件权限。");
      return;
    }
    result->Success();
    return;
  }
  if (name == "readPassword" || name == "savePassword" ||
      name == "deletePassword") {
    auto id = Text(a, "id");
    if (id.empty() || id.size() > 128 ||
        id.find_first_not_of("0123456789abcdefABCDEF-") != std::string::npos) {
      fail("无效节点标识。");
      return;
    }
    auto target = (preview_ ? L"ShadowbatPreview/" : L"Shadowbat/") + Wide(id);
    if (name == "readPassword") {
      PCREDENTIAL credential = nullptr;
      if (!CredRead(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
        if (GetLastError() == ERROR_NOT_FOUND) {
          result->Success();
          return;
        }
        result->Error("windows", "Windows 凭据读取失败。", V(static_cast<int64_t>(GetLastError())));
        return;
      }
      std::string password(reinterpret_cast<char *>(credential->CredentialBlob),
                           credential->CredentialBlobSize);
      CredFree(credential);
      result->Success(V(password));
      return;
    }
    if (name == "savePassword") {
      auto password = Text(a, "password");
      CREDENTIAL credential{};
      std::wstring userName = L"Shadowbat";
      credential.UserName = userName.data();
      credential.Type = CRED_TYPE_GENERIC;
      credential.TargetName = target.data();
      credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
      credential.CredentialBlobSize = static_cast<DWORD>(password.size());
      credential.CredentialBlob = reinterpret_cast<BYTE *>(password.data());
      if (!CredWrite(&credential, 0)) {
        result->Error("windows", "Windows 凭据保存失败。", V(static_cast<int64_t>(GetLastError())));
        return;
      }
    } else if (!CredDelete(target.c_str(), CRED_TYPE_GENERIC, 0) &&
               GetLastError() != ERROR_NOT_FOUND) {
      fail("Windows 凭据删除失败。");
      return;
    }
    result->Success();
    return;
  }
  if (name == "hasProxyBackup") {
    result->Success(V(HasBackup(registry_)));
    return;
  }
  if (name == "enableSystemProxy") {
    if (!EnableProxy(registry_, Integer(a, "http"), preview_)) {
      fail("系统代理设置失败，请先恢复原设置。");
      return;
    }
    result->Success();
    return;
  }
  if (name == "restoreSystemProxy") {
    bool conflict = false;
    if (!RestoreProxy(registry_, &conflict)) {
      fail("系统代理恢复失败，已保留备份。");
      return;
    }
    result->Success(V(conflict));
    return;
  }
  if (name == "updateTray") {
    state_ = a;
    if (tray_panel_) tray_panel_->Update(state_);
    NOTIFYICONDATA icon{};
    icon.cbSize = sizeof(icon);
    icon.hWnd = window_;
    icon.uID = 1;
    icon.uFlags = NIF_TIP | NIF_ICON;
    HICON network = NetworkIcon(Text(a, "state") == "connected");
    icon.hIcon = network ? network : LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
    auto tip = Wide("Shadowbat · " + Text(a, "stateLabel"));
    wcsncpy_s(icon.szTip, tip.c_str(), _TRUNCATE);
    Shell_NotifyIcon(NIM_MODIFY, &icon);
    if (network) DestroyIcon(network);
    result->Success();
    return;
  }
  if (name == "terminalScript") {
    auto path = std::filesystem::path(executable_).parent_path() / L"cores" /
                L"terminal-proxy.ps1";
    std::ifstream file(path, std::ios::binary);
    if (!file) {
      fail("App 中缺少终端集成脚本。");
      return;
    }
    std::string script((std::istreambuf_iterator<char>(file)),
                       std::istreambuf_iterator<char>());
    result->Success(V(script));
    return;
  }
  if (name == "restartElevated") {
    auto reply = reinterpret_cast<INT_PTR>(ShellExecute(
        window_, L"runas", executable_.c_str(),
        (L"--wait-for-exit " + std::to_wstring(GetCurrentProcessId()) +
         (preview_ ? L" --isolated-preview" : L""))
            .c_str(),
        nullptr, SW_SHOWNORMAL));
    if (reply <= 32) {
      fail("管理员授权已取消或失败。");
      return;
    }
    result->Success();
    return;
  }
  if (name == "quit") {
    PostQuitMessage(0);
    result->Success();
    return;
  }
  if (name == "startCore") {
    if (core_) {
      DWORD status;
      GetExitCodeProcess(core_, &status);
      if (status == STILL_ACTIVE) {
        fail("内核已经运行。");
        return;
      }
      CloseHandle(core_);
      core_ = nullptr;
    }
    auto core = Wide(Text(a, "executable")), config = Wide(Text(a, "config")),
         log = Wide(Text(a, "log"));
    auto expected = (std::filesystem::path(executable_).parent_path() /
                     L"cores" / L"sing-box.exe")
                        .wstring();
    if (core != expected || config != directory_ + L"\\run.json" ||
        log != directory_ + L"\\core.log") {
      fail("无效内核启动路径。");
      return;
    }
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), nullptr, TRUE};
    HANDLE output = CreateFile(log.c_str(), GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE, &attributes,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) {
      fail("无法创建内核日志。");
      return;
    }
    STARTUPINFO startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
    startup.wShowWindow = SW_HIDE;
    startup.hStdOutput = output;
    startup.hStdError = output;
    HANDLE input =
        CreateFile(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                   &attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    startup.hStdInput = input;
    auto command = Quote(core) + L" run -c " + Quote(config);
    PROCESS_INFORMATION info{};
    auto cwd = std::filesystem::path(core).parent_path().wstring();
    BOOL started = CreateProcess(core.c_str(), command.data(), nullptr, nullptr,
                                 TRUE, CREATE_NEW_CONSOLE | CREATE_SUSPENDED,
                                 nullptr, cwd.c_str(), &startup, &info);
    CloseHandle(output);
    if (input != INVALID_HANDLE_VALUE)
      CloseHandle(input);
    if (!started) {
      fail("无法启动 sing-box，请确认内核已随应用打包。");
      return;
    }
    if (!job_ || !AssignProcessToJobObject(job_, info.hProcess)) {
      TerminateProcess(info.hProcess, 1);
      CloseHandle(info.hThread);
      CloseHandle(info.hProcess);
      fail("无法设置内核进程保护。");
      return;
    }
    core_ = info.hProcess;
    core_pid_ = info.dwProcessId;
    ResumeThread(info.hThread);
    CloseHandle(info.hThread);
    result->Success(V(static_cast<int64_t>(core_pid_)));
    return;
  }
  if (name == "corePID") {
    result->Success(V(static_cast<int64_t>(core_pid_)));
    return;
  }
  if (name == "coreStatus") {
    DWORD status = 0;
    bool running =
        core_ && GetExitCodeProcess(core_, &status) && status == STILL_ACTIVE;
    result->Success(V(M{{V("running"), V(running)},
                        {V("exitCode"), V(static_cast<int64_t>(status))}}));
    return;
  }
  if (name == "stopCore") {
    DWORD exitCode = 0;
    if (core_) {
      DWORD status = 0;
      GetExitCodeProcess(core_, &status);
      if (status == STILL_ACTIVE) {
        HANDLE utility = nullptr;
        if (SpawnUtility(L"--stop-core " + std::to_wstring(core_pid_),
                         &utility)) {
          WaitForSingleObject(utility, 8000);
          CloseHandle(utility);
        }
        if (WaitForSingleObject(core_, 1000) != WAIT_OBJECT_0) {
          TerminateProcess(core_, 1);
          WaitForSingleObject(core_, 2000);
        }
      }
      GetExitCodeProcess(core_, &exitCode);
      CloseHandle(core_);
      core_ = nullptr;
      core_pid_ = 0;
    }
    result->Success(V(static_cast<int64_t>(exitCode)));
    return;
  }
  result->NotImplemented();
}
HANDLE ShadowbatWindows::AcquireInstance(bool preview) {
  auto name = L"Local\\Shadowbat-" + UserSID() + (preview ? L"-preview" : L"");
  HANDLE mutex = CreateMutex(nullptr, TRUE, name.c_str());
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    if (mutex)
      CloseHandle(mutex);
    return nullptr;
  }
  return mutex;
}
bool ShadowbatWindows::HandleUtility(const std::vector<std::string> &args) {
  if (args.size() < 2)
    return false;
  if (args[0] == "--stop-core") {
    DWORD pid = static_cast<DWORD>(strtoul(args[1].c_str(), nullptr, 10));
    HANDLE process = OpenProcess(
        SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (process) {
      FreeConsole();
      if (AttachConsole(pid)) {
        SetConsoleCtrlHandler(nullptr, TRUE);
        GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
        WaitForSingleObject(process, 6000);
        FreeConsole();
      }
      CloseHandle(process);
    }
    return true;
  }
  if (args[0] == "--proxy-watchdog") {
    DWORD pid = static_cast<DWORD>(strtoul(args[1].c_str(), nullptr, 10));
    HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (parent) {
      while (WaitForSingleObject(parent, 1000) == WAIT_TIMEOUT &&
             HasBackup(
                 RegName(args.size() > 2 && args[2] == "--isolated-preview"))) {
      }
      CloseHandle(parent);
    }
    bool conflict;
    RestoreProxy(RegName(args.size() > 2 && args[2] == "--isolated-preview"),
                 &conflict);
    return true;
  }
  return false;
}
