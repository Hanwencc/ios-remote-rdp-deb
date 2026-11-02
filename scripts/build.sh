#!/bin/bash
set -euo pipefail
MODE=${1:---packages}
if [ "$#" -gt 1 ] || { [ "$MODE" != "--foundation" ] && [ "$MODE" != "--packages" ]; }; then
    echo "Use --foundation or --packages." >&2; exit 1
fi
SDK="$THEOS/sdks/iPhoneOS16.5.sdk"
mkdir -p build
DEPS=/work/build/ios-deps
test -f "$DEPS/lib/libfreerdp3.a" || {
    echo "Pinned RDP dependencies missing. Run Get-Dependencies.ps1 and Build.ps1 -Dependencies first." >&2; exit 1;
}
BASE=(-target arm64-apple-ios15.0 -isysroot "$SDK" -std=c++17 -fobjc-arc -O2
    -Wall -Wextra -Werror=return-type -Wno-unused-parameter -Inative
    -I"$THEOS/vendor/include" -I"$DEPS/include/freerdp3" -I"$DEPS/include/winpr3" \
    -I"$DEPS/include" -F"$SDK/System/Library/PrivateFrameworks")
build_native() {
local PREFIX=$1 OUTPUT=$2
mkdir -p "$OUTPUT"
local COMMON=("${BASE[@]}" "-DRI_ROOT_PREFIX=\"$PREFIX\"")
clang++ "${COMMON[@]}" native/Daemon.mm native/Configuration.mm native/RDP.mm native/Engine.mm -o "$OUTPUT/remoteipadd" \
    -L"$DEPS/lib" -lfreerdp-server3 -lfreerdp3 -lwinpr3 -lssl -lcrypto -lz \
    -framework Foundation -framework CoreFoundation -framework Security -framework UIKit \
    -framework IOSurface -framework CoreVideo -framework VideoToolbox -framework QuartzCore \
    -framework CoreGraphics -framework CoreMedia
ldid -Snative/entitlements.plist "$OUTPUT/remoteipadd"
clang++ "${COMMON[@]}" tests/management.mm -o "$OUTPUT/management-test" -framework Foundation
ldid -S "$OUTPUT/management-test"
clang++ "${COMMON[@]}" tests/output-flow.cpp -o "$OUTPUT/output-flow-test"
ldid -S "$OUTPUT/output-flow-test"
clang++ "${COMMON[@]}" tests/latency-flow.cpp -o "$OUTPUT/latency-flow-test"
ldid -S "$OUTPUT/latency-flow-test"
clang++ "${COMMON[@]}" tests/input-flow.cpp -o "$OUTPUT/input-flow-test"
ldid -S "$OUTPUT/input-flow-test"
clang++ "${COMMON[@]}" tests/avc-buffer.mm -o "$OUTPUT/avc-buffer-test" \
    -framework CoreMedia -framework CoreFoundation
ldid -S "$OUTPUT/avc-buffer-test"
clang++ "${COMMON[@]}" -dynamiclib native/Preferences.mm -o "$OUTPUT/RemoteIPad" \
    -framework Foundation -framework UIKit -framework Preferences -framework QuartzCore
ldid -S "$OUTPUT/RemoteIPad"
clang++ "${COMMON[@]}" tests/preferences.mm -o "$OUTPUT/preferences-test" \
    -framework Foundation -framework UIKit -framework Preferences -framework QuartzCore
ldid -S "$OUTPUT/preferences-test"
clang++ "${COMMON[@]}" tests/encoder-properties.mm -o "$OUTPUT/encoder-properties-test" \
    -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreFoundation
ldid -Snative/entitlements.plist "$OUTPUT/encoder-properties-test"
clang++ "${COMMON[@]}" -dynamiclib native/SettingsHook.mm -o "$OUTPUT/RemoteIPadSettings.dylib" \
    -framework Foundation -framework UIKit -framework Preferences \
    -L"$THEOS/vendor/lib/iphone/rootless" -lsubstrate \
    "-Wl,-rpath,$PREFIX/usr/lib" "-Wl,-rpath,$PREFIX/Library/Frameworks"
ldid -S "$OUTPUT/RemoteIPadSettings.dylib"
}
if [ "$MODE" = "--foundation" ]; then
    build_native /var/jb build
    echo "RDP rootless foundation compile passed."
else
    build_native "" build/rootful
    build_native /var/jb build/rootless
    tr -d '\r' < scripts/package.sh | bash
fi
