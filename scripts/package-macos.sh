#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app=${1:-build/macos-ci/Build/Products/Release/shadowbat.app}
signing=${2:-ad-hoc}
case "$signing" in ad-hoc|development) ;; *) printf 'Unsupported signing mode: %s\n' "$signing" >&2; exit 1 ;; esac
test -d "$app/Contents"
if test "$signing" = development; then
  case "$(codesign -dvv "$app" 2>&1)" in
    *"Authority=Apple Development:"*) ;;
    *) printf 'Development package requires an Apple Development signature\n' >&2; exit 1 ;;
  esac
fi
version=$(python3 scripts/check-version.py)
mkdir -p dist/macos
image="dist/macos/Shadowbat-$version-macos-arm64-$signing.dmg"
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
if test "$signing" = development; then
cat > "$staging/README.txt" <<'NOTE'
Drag Shadowbat.app into Applications after quitting previous copies.
This local build uses an Apple Development certificate, not Developer ID notarization.
The app, Flutter frameworks, core and privileged helper share the same Team ID.
NOTE
else
cat > "$staging/README.txt" <<'NOTE'
Drag Shadowbat.app into Applications.
This CI build is ad-hoc signed, not Apple notarized.
The privileged system-proxy helper requires formal team signing for installation.
NOTE
fi
hdiutil create -volname Shadowbat -srcfolder "$staging" -format UDZO "$image"
hdiutil verify "$image"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$image" >/dev/null
test -f "$mount/Shadowbat.app/Contents/Info.plist"
test "$(readlink "$mount/Applications")" = /Applications
codesign --verify --deep --strict "$mount/Shadowbat.app"
# Test the same copy users install, rather than only verifying signatures.
installed=$(mktemp -d "$staging/installed-XXXXXXXX")
ditto "$mount/Shadowbat.app" "$installed/Shadowbat.app"
python3 scripts/test-macos-startup.py "$installed/Shadowbat.app"
hdiutil detach "$mount" >/dev/null
(cd dist/macos && shasum -a 256 "$(basename "$image")" > "$(basename "$image").sha256")
printf 'Verified DMG: %s\n' "$image"
