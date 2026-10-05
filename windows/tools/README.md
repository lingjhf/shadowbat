# Windows core

Pinned official sing-box 1.14.2 windows-amd64 and official signed Wintun 0.14.1 amd64.

- Core release: https://github.com/SagerNet/sing-box/releases/tag/v1.14.2
- Core archive SHA-256: `c2d8bfff918755808781dfdeeb8581b6c91eb3a243d9a7b55483cfc0c0684d32`
- Driver source: https://www.wintun.net/
- Driver archive SHA-256: `07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51`

Run `powershell -File scripts/prepare-windows-core.ps1` from the project root to reproduce the vendored binaries. Keep `libcronet.dll` and `wintun.dll` alongside `sing-box.exe`. CMake copies this directory into the app's `cores` directory, with both licenses. This backend targets Windows x64; other architectures need their corresponding binaries.
