#!/bin/sh
# Build without a developer certificate; this is an ad-hoc CI artifact.
set -eu
flutter build macos --release --config-only
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -derivedDataPath build/macos-ci \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ARCHS=arm64 build
