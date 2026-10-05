#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app=${1:-build/macos-ci/Build/Products/Release/shadowbat.app}
test -d "$app/Contents"
version=$(python3 scripts/check-version.py)
mkdir -p dist/macos
image="dist/macos/Shadowbat-$version-macos-arm64-ad-hoc.dmg"
test ! -e "$image"
staging=$(mktemp -d)
mount=$(mktemp -d)
cleanup() {
  if mount | grep -F " on $mount " >/dev/null; then hdiutil detach "$mount" >/dev/null; fi
  rm -rf "$staging" "$mount"
}
trap cleanup EXIT HUP INT TERM
ditto "$app" "$staging/Shadowbat.app"
ln -s /Applications "$staging/Applications"
cat > "$staging/README.txt" <<'NOTE'
Drag Shadowbat.app into Applications.
This CI build is ad-hoc signed, not Apple notarized.
The privileged system-proxy helper requires formal team signing for installation.
NOTE
hdiutil create -volname Shadowbat -srcfolder "$staging" -format UDZO "$image"
hdiutil verify "$image"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$image" >/dev/null
test -f "$mount/Shadowbat.app/Contents/Info.plist"
test "$(readlink "$mount/Applications")" = /Applications
codesign --verify --deep --strict "$mount/Shadowbat.app"
hdiutil detach "$mount" >/dev/null
(cd dist/macos && shasum -a 256 "$(basename "$image")" > "$(basename "$image").sha256")
printf 'Verified DMG: %s\n' "$image"
