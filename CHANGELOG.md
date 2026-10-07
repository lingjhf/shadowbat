# Changelog

## 1.3.8+16

- Stop recursive XPC reconnection after helper rejection or invalidation during macOS app replacement.
- On explicit proxy recovery, reload an unavailable helper once through ServiceManagement, retaining durable recovery snapshots and respecting background approval.
- Bound XPC and service unregistration waits, finish overlapping requests safely, and release the recovery UI on failure so it can be retried.
- Preserve active lease conflicts without restarting the helper; refresh approval status and clear stale receipts only after confirmed restoration.
- Add isolated recovery and real anonymous XPC timeout regression checks.

## 1.3.7+15

- Replace the macOS tray popover with an arrowless native panel, retaining rounded corners and a shadow.
- Keep the panel below its status icon as content changes, activate keyboard focus on opening, and dismiss on Escape or outside clicks while preserving picker menus.
- Verify borderless geometry, mode changes, reopening and dismissal with isolated native fixtures and the packaged app.

## 1.3.6+14

- Activate the macOS app and make the tray window key when it opens, assigning the SwiftUI content as its initial keyboard responder.
- Retain status-icon positioning while preparing first-open and reopen focus, with an interactive fixture for actual user-gesture verification.

## 1.3.5+13

- Anchor the macOS tray below the status icon using the button's actual coordinate direction.
- Resolve the SwiftUI panel size before opening so its first layout cannot shift the popover away from the icon.
- Verify first opening, selection changes, reopening, and the tray position in the packaged application.

## 1.3.4+12

- Keep AppKit's normal event loop running during asynchronous quit cleanup, then exit after it completes; avoid a termination loop that blocks core shutdown.
- Make overlapping disconnect and quit requests wait for the same cleanup result.
- Complete macOS core shutdown independently of cancelled connection tasks; serialize concurrent stops and reap the process before allowing reconnection.
- Wait for an authorized TUN session to stop even if its startup notification has not arrived yet.
- Escalate crash watchdog cleanup for a core that ignores graceful termination, verifying the unique runtime configuration path before signalling it.
- Briefly retry busy ports during immediate restart, while preserving and reporting unrelated listeners.
- Validate repeated cancellation, immediate port reuse, restart after a host crash, and unrelated port conflicts on isolated ports.

## 1.3.3+11

- Restore the macOS menu bar icon on each launch even when a previous quit saved it as hidden; assign a stable status item identity.
- Coalesce native state updates and reuse the log date formatter to keep the menu bar and main window responsive during log bursts.
- Check menu bar visibility and image availability after restarting the packaged app with a saved hidden status item.

## 1.3.2+10

- Add local Apple Development signing for the app, Flutter frameworks, core and helper, enabling authenticated system-proxy helper connections on the development Mac.
- Fix immediate macOS launch failure caused by hardened library validation rejecting ad-hoc signed Flutter frameworks.
- Apply the library validation exception only to local/CI app signing, preserving formal release and privileged helper signing rules.
- Validate startup of the complete release app copied from the packaged DMG with isolated settings.

## 1.3.1+9

- Add macOS TUN switches to the Flutter settings and native tray, sharing one connection lifecycle and saved preference.
- Launch a per-connection native supervisor through macOS administrator authorization without installing a permanent service.
- Support IPv4/IPv6 TCP, UDP and DNS routing; preserve direct exceptions and local HTTP/SOCKS listeners.
- Clean up after disconnect, authorization cancellation, core failure, supervisor failure and app crashes, using a separate root watchdog.
- Hide the macOS window and tray immediately on quit while network cleanup runs asynchronously.

## 1.3.0+8

- Migrate the macOS native proxy backend to pinned sing-box 1.14.2, retaining the Swift tray, credentials and process cleanup.
- Enable the shared Flutter direct configuration page on macOS, including persistence, local DNS for direct domains and migration backups.
- Verify encrypted HTTP/SOCKS/CONNECT forwarding, automatic node failover and direct access with the proxy upstream stopped.
- Add an isolated administrator TUN harness using the native configuration; the macOS app's TUN control remains pending privileged integration.

## 1.2.0+7

- Replace Windows routing controls with direct exceptions for domains, IP addresses and CIDR networks; public traffic defaults to proxy.
- Remove configurable fallback, proxy rules and ordering controls.
- Migrate legacy settings with a backup, retaining only direct entries and their enabled state.
- Verify empty settings, disabled exceptions and actual direct/proxy traffic.

## 1.1.1+6

- Hide Windows windows and tray immediately when quitting, while restoring proxy settings and stopping the core in the background.
- Prevent duplicate shutdown requests and restore the UI if cleanup fails.
- Verify shutdown responsiveness during slow native work.

## 1.1.0+5

- Add Windows routing rules for domains, subdomains, IPv4/IPv6 and CIDR networks, with ordered matching, enable/disable, editing and persistence.
- Add configurable direct/proxy defaults, target testing and system DNS resolution testing.
- Route custom LAN rules through TUN and split DNS by domain policy; reserved local addresses stay direct.
- Verify both direct and encrypted paths against isolated native fixtures.

## 1.0.3+4

- Windows 托盘浮窗改用 Flutter 渲染，统一字体、图标、开关和节点选择的显示质量。
- 原生层管理托盘图标、定位、失焦隐藏和窗口生命周期；Flutter 面板共享主窗口的代理状态与后台线程。

## 1.0.2+3

- Run Windows native process, credential and proxy operations on a serialized worker.
- Return platform replies on the UI thread and verify UI responsiveness during slow native work.

## 1.0.1+2

- Replace the Windows context menu with a native tray panel matching the macOS layout.
- Add live proxy switches, segmented selection, a manual node dropdown, keyboard dismissal and DPI/theme handling.
- Show connection state in the native tray icon and add real desktop interaction verification.

## 1.0.0+1

- Flutter desktop interface for connection, nodes, settings and logs.
- Native macOS tray and Swift proxy services retained from Shadowbat macOS.
- Native Win32 tray, Credential Manager, system proxy restoration and PowerShell integration.
- Windows sing-box and Wintun support, including administrator restart for TUN.
- macOS DMG and Windows EXE installer.
- Portable Windows ZIP with app-local Visual C++ runtime and file integrity checks.
- CI checks, desktop builds and version-tagged GitHub releases.
