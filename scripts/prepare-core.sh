#!/bin/sh
# Pinned official macOS arm64 sing-box, also used by the Windows backend.
set -eu
task_repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
task_scratch=$(mktemp -d)
trap 'rm -rf "$task_scratch"' EXIT HUP INT TERM
curl --fail --location --retry 3 'https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-darwin-arm64.tar.gz' -o "$task_scratch/core.tar.gz"
printf '%s  %s\n' '925c5382eca8492b0150f868a6db20b18290a38700e621724b3703fd453e032d' "$task_scratch/core.tar.gz" | shasum -a 256 -c -
tar -xzf "$task_scratch/core.tar.gz" -C "$task_scratch"
mkdir -p "$task_repo/macos/Tools"
cp "$task_scratch/sing-box-1.14.2-darwin-arm64/sing-box" "$task_repo/macos/Tools/sing-box"
chmod 755 "$task_repo/macos/Tools/sing-box"
cp "$task_scratch/sing-box-1.14.2-darwin-arm64/LICENSE" "$task_repo/macos/Tools/sing-box-LICENSE.txt"
printf 'sing-box 1.14.2\n' > "$task_repo/macos/Tools/core-version.txt"
cd "$task_repo/macos/Tools"
shasum -a 256 sing-box > sing-box.sha256
