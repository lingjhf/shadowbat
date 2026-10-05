# Shadowsocks 内核

`sslocal` 来自 Homebrew 的 shadowsocks-rust 1.25.0 arm64 bottle。上游地址为 https://github.com/shadowsocks/shadowsocks-rust ，许可证为 MIT，完整许可证保存在 `shadowsocks-rust-LICENSE.txt`。

`sslocal.sha256` 校验仓库中的原始文件。App 构建时会重签名内核，因此 App 内副本的 SHA-256 会改变。该文件仅依赖 macOS 系统动态库。

可通过 在项目根目录运行 `sh scripts/prepare-core.sh` 从已安装的对应 Homebrew 版本重新生成这些文件。支持 Intel Mac 时，需要另外准备 x86_64 内核或 Universal 二进制，并修改工程的架构设置。
