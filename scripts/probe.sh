#!/bin/bash
set -euo pipefail
mkdir -p build
SDK="$THEOS/sdks/iPhoneOS16.5.sdk"
clang++ -target arm64-apple-ios15.0 -isysroot "$SDK" -std=c++17 -fobjc-arc \
  native/Probe.mm native/Engine.mm -o build/remoteipad-probe \
  -framework Foundation -framework UIKit -framework IOSurface -framework CoreVideo \
  -framework CoreGraphics -framework VideoToolbox -framework ImageIO \
  -framework QuartzCore -framework CoreMedia
ldid -Snative/entitlements.plist build/remoteipad-probe
clang++ -target arm64-apple-ios15.0 -isysroot "$SDK" -std=c++17 -fobjc-arc \
  tests/input-device.mm native/Engine.mm -o build/input-device \
  -framework Foundation -framework UIKit -framework IOSurface -framework CoreVideo \
  -framework CoreGraphics -framework VideoToolbox -framework QuartzCore -framework CoreMedia
ldid -Snative/entitlements.plist build/input-device
mkdir -p build/InputFixture.app
clang++ -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc \
  tests/InputFixture.mm -o build/InputFixture.app/InputFixture -framework Foundation -framework UIKit -framework CoreGraphics
cp tests/InputFixture.plist build/InputFixture.app/Info.plist
ldid -Stests/InputFixture.entitlements build/InputFixture.app/InputFixture
