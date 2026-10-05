#!/bin/sh
set -eu
task_repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
task_prefix=$(brew --prefix shadowsocks-rust)
task_version=$("$task_prefix/bin/sslocal" --version)
if [ "$task_version" != "shadowsocks 1.25.0" ]; then
    printf 'Expected shadowsocks 1.25.0, got %s\n' "$task_version" >&2
    exit 1
fi
mkdir -p "$task_repo/macos/Tools"
cp "$task_prefix/bin/sslocal" "$task_repo/macos/Tools/sslocal"
chmod 755 "$task_repo/macos/Tools/sslocal"
cp "$task_prefix/LICENSE" "$task_repo/macos/Tools/shadowsocks-rust-LICENSE.txt"
printf '%s\n' "$task_version" > "$task_repo/macos/Tools/core-version.txt"
cd "$task_repo/macos/Tools"
shasum -a 256 sslocal > sslocal.sha256
printf 'Prepared %s (%s)\n' "$task_version" "$(lipo -archs sslocal)"
