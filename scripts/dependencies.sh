#!/bin/bash
set -euo pipefail
ROOT=/work
PREFIX="$ROOT/build/ios-deps"
SSL="$ROOT/build/deps/openssl"
RDP="$ROOT/build/deps/FreeRDP"
test "$(git -c safe.directory="$SSL" -C "$SSL" rev-parse HEAD)" = 45e844fa2a14ec92d146bd8f5778ac130b6625fb
test "$(git -c safe.directory="$RDP" -C "$RDP" rev-parse HEAD)" = 97eff6ddfbbfaa8e42a126d362686bd001ff8bdc
mkdir -p "$ROOT/build/openssl-ios" "$PREFIX"
cd "$ROOT/build/openssl-ios"
CC="$THEOS/toolchain/linux/iphone/bin/clang -target arm64-apple-ios15.0 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk" \
AR="$THEOS/toolchain/linux/iphone/bin/llvm-ar" \
RANLIB="$THEOS/toolchain/linux/iphone/bin/ranlib" \
perl "$SSL/Configure" ios64-xcrun no-shared no-tests no-apps no-module no-asm --prefix="$PREFIX"
make -j4 build_libs > "$ROOT/build/openssl-build.log" 2>&1 || { tail -80 "$ROOT/build/openssl-build.log"; exit 1; }
make install_dev > "$ROOT/build/openssl-install.log" 2>&1 || { tail -80 "$ROOT/build/openssl-install.log"; exit 1; }
cd "$ROOT"
cmake -S "$RDP" -B build/freerdp-ios -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/scripts/ios-toolchain.cmake" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    -DCMAKE_C_COMPILER_AR="$THEOS/toolchain/linux/iphone/bin/llvm-ar" \
    -DCMAKE_C_COMPILER_RANLIB="$THEOS/toolchain/linux/iphone/bin/ranlib" \
    -DCMAKE_CXX_COMPILER_AR="$THEOS/toolchain/linux/iphone/bin/llvm-ar" \
    -DCMAKE_CXX_COMPILER_RANLIB="$THEOS/toolchain/linux/iphone/bin/ranlib" \
    -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=OFF -DWITH_CLIENT_CHANNELS=OFF \
    -DWITH_SERVER=ON -DWITH_SERVER_CHANNELS=ON \
    -DWITH_SAMPLE=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_PLATFORM_SERVER=OFF \
    -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF \
    -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_CUPS=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF \
    -DWITH_PCSC=OFF -DWITH_PKCS11=OFF -DWITH_GSSAPI=OFF -DWITH_KRB5=OFF \
    -DWITH_WINPR_TOOLS=OFF -DWITH_MANPAGES=OFF -DWITH_FUSE=OFF \
    -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON \
    -DWITH_UNICODE_BUILTIN=ON -DWITH_WINPR_JSON=OFF -DWITH_AAD=OFF \
    -DCHANNEL_RDPGFX_SERVER=ON -DCHANNEL_CLIPRDR_SERVER=ON -DBUILD_TESTING=OFF \
    > build/freerdp-configure.log 2>&1 || { tail -100 build/freerdp-configure.log; exit 1; }
cmake --build build/freerdp-ios -j4 > build/freerdp-build.log 2>&1 || { tail -100 build/freerdp-build.log; exit 1; }
cmake --install build/freerdp-ios > build/freerdp-install.log 2>&1 || { tail -80 build/freerdp-install.log; exit 1; }
echo "Pinned iOS FreeRDP/WinPR/OpenSSL dependencies built."
