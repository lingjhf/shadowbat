# Shadowbat Flutter

原生 SwiftUI 版 Shadowbat 的 Flutter 主窗口迁移。主窗口由 Flutter 绘制，macOS 状态栏托盘、代理服务和系统集成继续使用 Swift。支持 Apple Silicon / macOS 14 及以上，以及 Windows x64。Windows 使用 sing-box 内核，托盘、凭据、系统代理与进程生命周期由原生 Win32 实现，并提供 Wintun 隧道。

## 运行

```sh
flutter pub get
flutter run -d macos
flutter build macos --release
```

Xcode 工程为 `macos/Runner.xcworkspace`。Runner 与 ProxyHelper 使用同一开发团队签名；当前沿用原工程的团队设置，可在 Xcode 中为两个 target 一起修改。使用 ad-hoc 签名构建可以运行本地代理，但不能注册需要团队签名校验的系统辅助程序。正式分发需要 Developer ID 签名及公证。为支持进程内核、zsh 集成与系统辅助程序，沿用原版关闭 App Sandbox、开启 Hardened Runtime 的分发方式。

主窗口为默认 360×640、9:16 比例，支持系统浅色/深色模式：

- 连接：全局开关、自动/手动选择、固定节点、系统/终端代理、测试连接。
- 节点：添加、编辑、删除、详情浏览、参与自动选择。运行时锁定配置编辑。
- 设置：本地 SOCKS5 / HTTP 端口、辅助程序授权/刷新、终端集成与激活命令。
- 日志：实时显示、选择复制、清空；原生保留最近 500 条。
- 托盘：原生 NSStatusItem + NSPopover + SwiftUI 面板，保留服务、系统代理、终端代理、节点选择、恢复代理、打开主窗口和退出。

关闭主窗口会隐藏 Dock 图标并保持托盘和代理运行。重新打开恢复主窗口和 Dock；退出会等待代理恢复，恢复失败时取消退出。

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
windows/runner/shadowbat_windows.cpp   Win32 托盘、凭据、代理恢复、内核进程
windows/tools/                 sing-box、libcronet、Wintun 与许可证
windows/resources/             PowerShell 终端集成脚本
macos/Runner/ShadowbatBridge.swift   命令分派、状态推送、原生托盘
macos/Native/                  原版 Swift 模型、服务、终端脚本、托盘视图
macos/Shared/                  App / 辅助程序共用协议与设置
macos/ProxyHelper/             系统代理辅助程序
macos/Tools/                   arm64 sslocal、许可证与版本/校验信息
```

Flutter 和托盘共享唯一的 `ConnectionViewModel`。Flutter 通过命令通道调用原生后端，事件通道同步完整状态。节点密码不出现在状态、节点 JSON 或日志中，只在编辑器读取与提交时经过命令通道。自动选择由 shadowsocks-rust balancer 执行，故障切换保持内核及本地端口；所有节点失效时不回退直连。

Linux、移动端等其他平台尚未实现代理后端。当前不包含订阅或用户自定义规则分流；TUN 目前仅在 Windows 实现。

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
- 托盘由 `Shell_NotifyIcon` 和原生菜单实现，共享 Flutter 后端状态。关闭窗口继续运行，托盘提供连接、节点、代理、TUN、恢复和退出操作。
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
# 独立管理员测试真实 Wintun 网卡创建、停止与删除
powershell -ExecutionPolicy Bypass -File scripts/test-windows-interactive.ps1 -TunnelOnly
```

SSH 网络登录不能直接访问桌面凭据库。交互测试仅注册一次性的开发测试任务，结束后删除。TUN 测试校验生产配置，创建实际网卡，并仅为合成测试地址增加临时路由，验证 TCP 经 Wintun 与 Shadowsocks 转发、正常退出与网卡删除；真实远端节点的全局 TCP/UDP、DNS 与网络切换需进一步验收。

## 验证

```sh
flutter analyze
flutter test
python3 scripts/test-helper.py
python3 scripts/test-local.py
```

原生集成检查需要 Xcode 与 PATH 中的 `ssserver`，使用本地 HTTP/DNS/Shadowsocks 测试服务、隔离配置目录和测试钥匙串项，不修改个人 `.zshrc` 或真实系统代理。辅助程序测试覆盖授权服务的快照、冲突合并、故障恢复和目录权限。

Debug 构建支持独立界面预览：

```sh
open -n build/macos/Build/Products/Debug/shadowbat.app --args --isolated-preview
```

隔离预览使用临时节点目录、独立偏好与测试钥匙串服务、临时 `.zshrc`，不注册系统辅助程序。该开关只在 Debug 生效。

真实系统授权、有效远端节点连接、关闭窗口后托盘常驻、睡眠唤醒和网络切换仍应在目标 Mac 上验收。

## Git、分支与版本发布

远程仓库为 `git@github.com:lingjhf/shadowbat.git`。沿用 `cutdex_agent` 的 `main` 主分支与 `v*` 标签发布方式：日常改动在功能分支完成并提交到 `main`；`pubspec.yaml` 是应用版本的唯一来源，当前为 `1.0.0+1`。`+1` 是 Flutter 构建号，发布标签需完整匹配 `v1.0.0+1`。

CI 在指向 `main` 的 PR、`main` 推送、`v*` 标签推送及手动触发时运行，固定使用 Flutter 3.47.5。它检查格式、静态分析和版本，执行 Linux/Windows/macOS 的 Flutter 测试，构建 Windows x64 与 macOS arm64，并生成 ZIP 与 SHA-256 文件。工作流 Action 固定到提交 SHA；Dependabot 每周检查 Action 更新。汇总检查名为 `CI passed`，可设为主分支必过检查。

发布时先更新 `pubspec.yaml` 和 `CHANGELOG.md`，将代码合并到 `main`，然后从对应提交创建标签：

```sh
python3 scripts/check-version.py
git tag -a v1.0.0+1 -m 'Shadowbat 1.0.0+1'
git push origin v1.0.0+1
```

标签触发完整 CI，通过后检查标签与版本一致、提交属于 `main`，再创建 GitHub Release 并上传两个平台的 ZIP 与校验文件。带预发布后缀（如 `1.1.0-beta.1+2`）的标签发布为 prerelease。应用保持 `publish_to: none`，不会发布到 pub.dev。

Windows CI 产物未签名；macOS CI 产物为 ad-hoc 签名，未经 Apple 公证，其系统代理辅助程序仍需正式团队签名才能用于授权安装。正式分发签名应在独立的受控发布流程中完成，证书、私钥及个人节点配置不进入 Git。`Native proxy validation` 对应参考项目的手动验证工作流，仅从 `main` 执行 macOS 本地加密转发与辅助程序测试；Windows 完整凭据/TUN 集成验证使用真机测试脚本。
