#!/bin/sh
# Build without a developer certificate; this is an ad-hoc CI artifact.
set -eu
flutter build macos --release --config-only
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -derivedDataPath build/macos-ci \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ARCHS=arm64 build
# Ad-hoc signatures have no Apple Team ID, so hardened library validation
# rejects the embedded Flutter frameworks even when every signature is valid.
# Apply this exception only to the local/CI app, retaining the production
# entitlements and the privileged helper's strict signing policy.
codesign --force --sign - --options runtime \
  --entitlements macos/Runner/AdHocRelease.entitlements \
  build/macos-ci/Build/Products/Release/shadowbat.app
codesign --verify --deep --strict build/macos-ci/Build/Products/Release/shadowbat.app
