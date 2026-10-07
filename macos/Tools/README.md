# sing-box 内核

`sing-box` 来自 SagerNet 官方 1.14.2 macOS arm64 发布包：
[sing-box-1.14.2-darwin-arm64.tar.gz](https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-darwin-arm64.tar.gz)。发布包 SHA-256 为 `925c5382eca8492b0150f868a6db20b18290a38700e621724b3703fd453e032d`。

官方许可证声明保存在 `sing-box-LICENSE.txt`，上游源代码为 [SagerNet/sing-box](https://github.com/SagerNet/sing-box/tree/v1.14.2)。`sing-box.sha256` 校验仓库中的原始二进制。App 构建时重签名内核，App 内副本的 SHA-256 会改变。

在项目根目录运行 `sh scripts/prepare-core.sh` 会下载固定版本、验证归档校验值并准备内核与许可证。支持 Intel Mac 时，需要另外准备 x86_64 内核或 Universal 二进制，并修改工程的架构设置。Homebrew 的 shadowsocks-rust 仅用于本地测试中的独立服务端。
