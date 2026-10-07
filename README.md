# Shadowbat Flutter

原生 SwiftUI 版 Shadowbat 的 Flutter 主窗口迁移。主窗口由 Flutter 绘制，macOS 状态栏托盘、代理服务和系统集成继续使用 Swift。支持 Apple Silicon / macOS 14 及以上，以及 Windows x64。两个平台使用 sing-box 1.14.2 内核。Windows 托盘面板由 Flutter 绘制，托盘图标、窗口管理、凭据、系统代理与进程生命周期由原生 Win32 实现，并提供 Wintun 隧道。

## 运行

```sh
flutter pub get
flutter run -d macos
flutter build macos --release
```

Xcode 工程为 `macos/Runner.xcworkspace`。Runner 与 ProxyHelper 使用同一开发团队签名；当前沿用原工程的团队设置，可在 Xcode 中为两个 target 一起修改。使用 ad-hoc 签名构建可以运行本地代理，但不能注册需要团队签名校验的系统辅助程序。正式分发需要 Developer ID 签名及公证。为支持进程内核、zsh 集成与系统辅助程序，沿用原版关闭 App Sandbox、开启 Hardened Runtime 的分发方式。`scripts/build-macos-ci.sh` 仅在本地/CI 签名时为主应用加入 library validation 例外，允许加载没有 Team ID 的 Flutter 框架；正式团队签名的 Release 配置与辅助程序校验不变。DMG 打包后会复制完整应用并进行隔离启动检查，验证 Flutter 与原生状态通道均成功启动。

本机钥匙串已有 Apple Development 证书时，可用 `python3 scripts/sign-macos-development.py --identity <证书名称或SHA-1>` 对构建好的应用统一团队签名，再运行 `sh scripts/package-macos.sh build/macos-development/shadowbat.app development` 生成本机开发测试 DMG。该包可满足系统代理辅助程序的团队身份校验；首次安装仍需 macOS 后台授权。开发签名不等于 Developer ID 公证，公开分发仍需单独的发布签名流程。

主窗口为默认 360×640、9:16 比例，支持系统浅色/深色模式：

- 连接：全局开关、自动/手动选择、固定节点、系统/终端代理、测试连接。
- 节点：添加、编辑、删除、详情浏览、参与自动选择。运行时锁定配置编辑。
- 直连配置：域名、IP 和 CIDR 直连例外，公网默认代理，断开后编辑。
- 设置：TUN 隧道、本地 SOCKS5 / HTTP 端口、辅助程序授权/刷新、终端集成与激活命令。
- 日志：实时显示、选择复制、清空；原生保留最近 500 条。
- 托盘：原生 NSStatusItem + NSPopover + SwiftUI 面板，保留服务、系统代理、终端代理、TUN、节点选择、恢复代理、打开主窗口和退出。

关闭主窗口会隐藏 Dock 图标并保持托盘和代理运行。重新打开恢复主窗口和 Dock；退出立即隐藏窗口和托盘，并异步等待网络设置恢复，恢复失败时返回应用。

## 数据兼容

沿用原版 `com.lingj.shadowbat` Bundle ID、偏好键、应用支持目录和钥匙串服务：

- 节点：`~/Library/Application Support/com.lingj.shadowbat/profiles.json`。
- 密码：macOS 钥匙串的 `com.lingj.shadowbat.passwords` 服务。
- 终端：原版 `terminal-proxy.zsh` 与 `.zshrc` 标记加载段。

切换到新版前，先在旧版断开并退出。两版共享运行锁，不能同时控制同一份数据。钥匙串访问由 macOS 签名授权控制，换签名后可能需要允许访问或重新保存密码。

系统代理首次使用时，将完整 App 放在固定位置（例如 `/Applications/Shadowbat.app`），在设置页安装并授权，在系统设置允许后台服务后刷新状态。安装/授权需要用户在 macOS 完成；构建和测试不会自动注册辅助程序。

终端集成修改 `.zshrc` 前备份，重复安装不追加重复段；现有终端首次执行复制的激活命令，新终端自动加载。服务停止后恢复此前的代理环境变量。

## 实现结构

```text
lib/domain/models/             不含密码的不可变状态与节点模型
lib/data/services/             Flutter MethodChannel / EventChannel
lib/data/repositories/         代理仓库接口与 macOS 实现
lib/ui/                        Flutter 界面、节点编辑器、视图模型
lib/data/windows/              Windows 仓库、sing-box 配置、原生集成自检
windows/runner/shadowbat_windows.cpp   Win32 托盘入口、凭据、代理恢复、内核进程
windows/runner/tray_panel.cpp         Win32 浮窗宿主与 Flutter 托盘消息通道
windows/tools/                 sing-box、libcronet、Wintun 与许可证
windows/resources/             PowerShell 终端集成脚本
macos/Runner/ShadowbatBridge.swift   命令分派、状态推送、原生托盘
macos/Native/                  原版 Swift 模型、服务、终端脚本、托盘视图
macos/Shared/                  App / 辅助程序共用协议与设置
macos/ProxyHelper/             系统代理辅助程序
macos/Tools/                   arm64 sing-box、许可证与版本/校验信息
```

Flutter 和托盘共享唯一的 `ConnectionViewModel`。Flutter 通过命令通道调用原生后端，事件通道同步完整状态。节点密码不出现在状态、节点 JSON 或日志中，只在编辑器读取与提交时经过命令通道。自动选择由 shadowsocks-rust balancer 执行，故障切换保持内核及本地端口；所有节点失效时不回退直连。

Linux、移动端等其他平台尚未实现代理后端。当前不包含订阅；macOS 与 Windows 均支持直连配置和应用内 TUN 开关。

## Windows

在 Windows 安装 Flutter 与 Visual Studio 的“使用 C++ 的桌面开发”工作负载，然后运行：

```powershell
flutter pub get
flutter run -d windows
flutter build windows --release
.\build\windows\x64\runner\Release\shadowbat.exe
```

发布时保留整个 `Release` 目录，包括 `data`、Flutter DLL 和 `cores`。固定内核为 sing-box 1.14.2，驱动为官方 Wintun 0.14.1；来源、校验值与重建脚本见 `windows/tools/README.md`。

- 普通权限支持本地 HTTP/SOCKS5、当前用户系统代理、PowerShell 终端集成、节点编辑与自动/手动选择。
- 设置页打开 TUN 后，通过“以管理员身份重启”完成 Windows UAC 授权，再连接。TUN 接管公网 TCP/UDP 与 DNS，局域网、回环和私有网段保持直连；上游节点必须支持相应协议。仅开启系统代理时，应用仍需遵循 Windows 代理设置。
- 托盘图标由 `Shell_NotifyIcon` 管理，浮窗内容由 Flutter 渲染，原生窗口负责定位、缩放和失焦隐藏。浮窗布局与 macOS 面板对应，通过状态快照和命令通道共享主窗口唯一的后端。关闭窗口继续运行，托盘提供连接、节点、代理、TUN、恢复和退出操作。
- 配置保存在 `%LOCALAPPDATA%\Shadowbat`；节点密码保存在 Windows Credential Manager，不写入节点 JSON。运行配置含内核所需密码，使用仅当前用户、SYSTEM 与管理员可访问的目录，停止服务后删除。
- 修改 WinINet 设置前备份原有代理、PAC 与自动检测状态，停止时恢复；其他程序已改动时保留其设置。独立恢复进程处理应用异常退出；原生 Job 对象终止遗留内核。
- PowerShell 5/7 集成安装前备份已有 profile，脚本随提示符刷新代理环境，并在应用/内核停止后恢复原值。若个人执行策略禁止 profile 脚本，请按本机策略配置；应用不更改执行策略。

Mac 端已配置的 SSH 别名 `windows` 可用于同步到 `D:\workspace\shadowbat`：

```sh
python3 scripts/sync-windows.py
# 只覆盖源代码，保留远端内核和已有构建
python3 scripts/sync-windows.py --source-only
```

脚本覆盖同名文件，保留远端构建目录；Mac 钥匙串不会同步到 Windows，Windows 节点需单独配置密码。

生成便携 ZIP 可使用 `scripts/package-windows.ps1 -RuntimeDirectory <Visual Studio 的 x64 CRT 重分发目录>`。脚本复制完整 Release 包和应用本地 VC++ DLL，保留许可证，逐文件校验 ZIP 内容，并在 `dist/windows` 输出压缩包与 SHA-256 文件。它不打包个人配置或密码，未签名构建的文件名会明确包含 `unsigned`。

Windows 本机集成测试使用隔离数据、测试凭据、本地 Shadowsocks/HTTP 服务和隔离代理注册表，不改个人系统代理、终端 profile 或默认路由：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/test-windows.ps1
# 通过 SSH 测试时，借用已登录的桌面会话进行凭据验证
powershell -ExecutionPolicy Bypass -File scripts/test-windows-interactive.ps1
# 在桌面会话验证 Flutter 托盘浮窗与共享后端交互
powershell -ExecutionPolicy Bypass -File scripts/test-windows-tray.ps1
# 独立管理员测试真实 Wintun 网卡创建、停止与删除
powershell -ExecutionPolicy Bypass -File scripts/test-windows-interactive.ps1 -TunnelOnly
```

SSH 网络登录不能直接访问桌面凭据库。交互测试仅注册一次性的开发测试任务，结束后删除。TUN 测试校验生产配置，创建实际网卡，并仅为合成测试地址增加临时路由，验证 TCP 经 Wintun 与 Shadowsocks 转发、正常退出与网卡删除；真实远端节点的全局 TCP/UDP、DNS 与网络切换需进一步验收。

## 验证

```sh
flutter analyze
flutter test
python3 scripts/test-helper.py
python3 scripts/test-macos-proxy-recovery.py
python3 scripts/test-local.py
python3 scripts/test-macos-port-cleanup.py
python3 scripts/test-macos-quit.py
python3 scripts/test-macos-tray-position.py
# 交互验证：点击隔离测试窗口中的“打开托盘并检查焦点”
python3 scripts/test-macos-tray-position.py --interactive-focus
```

原生集成检查需要 Xcode 与 PATH 中的 `ssserver`，使用本地 HTTP/DNS/Shadowsocks 测试服务、隔离配置目录和测试钥匙串项，不修改个人 `.zshrc` 或真实系统代理。辅助程序测试覆盖授权服务的快照、冲突合并、故障恢复和目录权限。

覆盖更新前通过菜单正常退出应用；退出流程会自动断开连接并恢复代理。若出现待恢复记录，点击恢复设置：通信失败时会尝试更新后台辅助程序一次，失败后保留备份并允许重试。若系统要求重新允许后台辅助程序，请在系统设置中授权后再次恢复。恢复回归检查使用隔离配置和匿名 XPC 端点，不重启已安装的辅助程序或修改真实系统代理。

macOS 独立 TUN 验证无需付费开发者账号。先以普通用户生成原生配置，再通过管理员权限创建临时 utun。测试只添加 `198.18.0.123/32` 和 `198.18.0.124/32` 两条路由，使用本地加密代理和直连服务验证出口，并检查退出后路由、网卡、DNS 与系统代理清理。结果写入 `build/macos-tun/report.json`。

```sh
python3 scripts/test-macos-tun.py --prepare
sudo /usr/bin/python3 scripts/test-macos-tun.py
```

macOS 应用内使用：断开代理后在设置或托盘开启 TUN，再连接，并在 macOS 系统窗口完成管理员授权。TUN 管理进程按次启动，通过私有 Unix socket 接收经过字段校验的网络配置；内核与密码配置复制到 root 私有目录。断开时关闭控制连接，停止内核并移除临时网卡、路由及运行目录；应用或管理进程崩溃时也有监控清理。TUN 支持 IPv4/IPv6，不需要重启整个应用为管理员，不安装常驻服务，也无需付费开发者账号。启用 TUN 时可以关闭“系统代理”，避免安装系统代理辅助程序；这两项功能独立。现有系统代理辅助程序的团队签名校验保持不变。

应用后端完整验证使用包内的原生管理程序，测试 TCP、UDP、DNS、IPv4/IPv6 直连与代理，正常断开、内核/管理进程被强制结束及应用崩溃后的清理。只为四个合成地址添加路由，不接管当前默认网络；报告写入 `build/macos-tun-app/report.json`。真实远端节点及实际网络切换仍需在目标网络验收。

```sh
# 构建后，以当前桌面用户运行，macOS 会请求管理员授权
python3 scripts/test-macos-tun-app.py
# 临时 CI 虚拟机已有无密码 sudo 时使用（不会修改 sudo 权限）
python3 scripts/test-macos-tun-app.py --sudo-authorization
```

Debug 构建支持独立界面预览：

```sh
open -n build/macos/Build/Products/Debug/shadowbat.app --args --isolated-preview
```

隔离预览使用临时节点目录、独立偏好与测试钥匙串服务、临时 `.zshrc`，不注册系统辅助程序。该开关只在 Debug 生效。

真实系统授权、有效远端节点连接、关闭窗口后托盘常驻、睡眠唤醒和网络切换仍应在目标 Mac 上验收。

## 直连配置

“直连配置”页面只添加需要绕过代理的精确域名、域名及子域名、IPv4/IPv6 地址和 CIDR 网段，支持启用、编辑和删除。没有启用的直连目标时，公网流量全部使用当前代理节点；未命中直连配置的公网目标固定走代理，不提供默认直连或代理规则选项。代理失败不会自动转为直连。局域网、回环与链路本地地址默认直连。

Windows 设置保存在 `%LOCALAPPDATA%\Shadowbat\routing.json`；macOS 保存在 `~/Library/Application Support/com.lingj.shadowbat/routing.json`。不包含节点密码；断开连接后可编辑，下次连接生效。升级后自动迁移旧设置：固定默认代理，只保留原直连条目及其启用状态；迁移前的设置备份为 `routing-before-direct-config.json`。旧代理条目不转换为直连。

系统代理仅覆盖进入 HTTP/SOCKS 代理的流量，TUN 可接管更多应用流量。域名目标通过 DNS 反向映射和 TUN 协议嗅探辅助识别，直连域名使用本地 DNS，其余默认使用代理 DNS。目标测试支持输入域名或 IP；可能匹配 IP 直连目标的域名需要解析确认。“解析并测试”使用系统 DNS，实际内核可能得到不同地址，以内核连接日志为准。

```powershell
# 隔离自检覆盖空配置默认代理、域名/IP/网段直连、禁用目标、IPv6 和两条转发路径
powershell -ExecutionPolicy Bypass -File scripts/test-windows-interactive.ps1
# 额外探测指定 IP，验证真实连接选中的直连出口（不改个人代理配置）
powershell -ExecutionPolicy Bypass -File scripts/test-windows-interactive.ps1 -DirectTarget 101.33.73.2
```

## Git、分支与版本发布

远程仓库为 `git@github.com:lingjhf/shadowbat.git`。沿用 `cutdex_agent` 的 `main` 主分支与 `v*` 标签发布方式：日常改动在 `codex/<功能名称>` 等功能分支完成，通过 PR 合并到 `main`。`pubspec.yaml` 是应用版本的唯一来源，当前为 `1.3.8+16`。`+16` 是 Flutter 构建号，发布标签需完整匹配 `v1.3.8+16`。

CI 在指向 `main` 的 PR、`main` 推送、`v*` 标签推送及手动触发时运行，固定使用 Flutter 3.47.5。它检查格式、静态分析、版本格式与对应 CHANGELOG 条目，执行 Linux/Windows/macOS 的 Flutter 测试，构建 Windows x64 与 macOS arm64，并生成 macOS DMG、Windows EXE 安装包和便携 ZIP，以及 SHA-256 文件。工作流 Action 固定到提交 SHA；Dependabot 每周检查 Action 更新。汇总检查名为 `CI passed`，已设置为 main 的必过检查。

仓库使用与参考项目一致的 GitHub Rulesets，规则定义保存在 `.github/rulesets`：

- [Protect main](https://github.com/lingjhf/shadowbat/rules/24641125)：禁止删除、强制推送和直接推送，必须通过 PR；合并前分支必须跟上 main，所有 CI 必须成功，评审讨论必须解决。没有管理员绕过权限；与参考项目一致，不强制要求其他人批准个人仓库的 PR。
- [Version tags: administrators create](https://github.com/lingjhf/shadowbat/rules/24641162)：`v*` 标签只能由仓库管理员创建。
- [Version tags: prevent changes](https://github.com/lingjhf/shadowbat/rules/24641164)：已有 `v*` 标签禁止修改或删除，管理员也不能绕过。

使用已登录的 GitHub CLI 校验远程配置；只有明确修改保护策略时才使用 `--apply`，它会按规则名称更新现有规则，避免重复创建：

```sh
python3 scripts/repository-rules.py
python3 scripts/repository-rules.py --apply
```

版本格式为 `MAJOR.MINOR.PATCH[-prerelease]+BUILD`，预发布标识遵循 SemVer，构建号为正整数。发布应用变更时递增构建号，并同步更新 `CHANGELOG.md` 中的 `## <完整版本>` 条目；仅维护 CI、文档或仓库规则时可以保留应用版本。已发布的版本标签不能重复使用，例如下一次修复版本可以使用 `1.3.9+17`。

发布时先更新 `pubspec.yaml` 和 `CHANGELOG.md`，将代码通过 PR 合并到 `main`，再同步本地 main 并由管理员从对应提交创建标签：

```sh
git switch main
git pull --ff-only origin main
version=$(python3 scripts/check-version.py --check-changelog --require-main)
git tag -a "v$version" -m "Shadowbat $version"
git push origin "v$version"
```

标签触发完整 CI，通过后检查标签与版本一致、提交属于 `main`，再创建 GitHub Release 并上传 macOS DMG、Windows EXE 安装包、便携 ZIP 与校验文件。带预发布后缀（如 `1.1.0-beta.1+2`）的标签发布为 prerelease。应用保持 `publish_to: none`，不会发布到 pub.dev。

Windows CI 产物未签名；macOS CI 产物为 ad-hoc 签名，未经 Apple 公证，其系统代理辅助程序仍需正式团队签名才能用于授权安装。正式分发签名应在独立的受控发布流程中完成，证书、私钥及个人节点配置不进入 Git。`Native proxy validation` 对应参考项目的手动验证工作流，仅从 `main` 执行 macOS 本地加密转发与辅助程序测试；Windows 完整凭据/TUN 集成验证使用真机测试脚本。

Windows EXE 安装包使用 Inno Setup 6。先生成便携 ZIP，再执行 `scripts/package-windows-installer.ps1`；默认安装到当前用户的应用目录，无需管理员权限，TUN 仍通过应用的 UAC 流程启用。macOS 执行 `scripts/package-macos.sh` 生成带 Applications 快捷入口的 DMG。

Windows 托盘交互验收使用 `powershell -File scripts/test-windows-tray.ps1`，在已登录桌面的真机运行隔离预览，检查主窗口隐藏后打开浮窗、开关状态刷新、节点选择、Esc、打开主窗口和退出，并保存面板截图。

Windows 原生进程启动／退出、凭据、文件权限和代理事务在串行后台线程执行，结果通过窗口消息回到 Flutter 平台线程。托盘绘制留在 UI 线程。真机隔离自检包含 1200 ms 慢操作期间的 UI 响应校验。
