#!/bin/bash
set -euo pipefail
umask 077
test -f private/rdp.json
STAGE=$(mktemp -d /tmp/remoteipad-deb.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p packages
for VARIANT in rootful rootless; do
    PREFIX="" ARCH=iphoneos-arm
    if [ "$VARIANT" = rootless ]; then PREFIX=/var/jb; ARCH=iphoneos-arm64; fi
    ROOT="$STAGE/$VARIANT"
    PAYLOAD="$ROOT$PREFIX"
    mkdir -p "$ROOT/DEBIAN" "$PAYLOAD/usr/bin" "$PAYLOAD/usr/share/remoteipad" \
        "$PAYLOAD/usr/share/doc/com.xyhelper.remoteipad" \
        "$PAYLOAD/Library/LaunchDaemons" "$PAYLOAD/Library/PreferenceBundles/RemoteIPad.bundle" \
        "$PAYLOAD/Library/MobileSubstrate/DynamicLibraries"
    install -m 755 "build/$VARIANT/remoteipadd" "$PAYLOAD/usr/bin/remoteipadd"
    install -m 755 "build/$VARIANT/RemoteIPad" "$PAYLOAD/Library/PreferenceBundles/RemoteIPad.bundle/RemoteIPad"
    install -m 755 "build/$VARIANT/RemoteIPadSettings.dylib" "$PAYLOAD/Library/MobileSubstrate/DynamicLibraries/"
    install -m 644 packaging/PreferencesInfo.plist "$PAYLOAD/Library/PreferenceBundles/RemoteIPad.bundle/Info.plist"
    install -m 644 packaging/SettingsHook.plist "$PAYLOAD/Library/MobileSubstrate/DynamicLibraries/RemoteIPadSettings.plist"
    sed "s|/var/jb|$PREFIX|g" packaging/com.xyhelper.remoteipad.plist > "$PAYLOAD/Library/LaunchDaemons/com.xyhelper.remoteipad.plist"
    sed "s|iphoneos-arm64|$ARCH|" packaging/control > "$ROOT/DEBIAN/control"
    for SCRIPT in postinst prerm; do
        sed "s|/var/jb|$PREFIX|g" "packaging/$SCRIPT" | tr -d '\r' > "$ROOT/DEBIAN/$SCRIPT"
        chmod 755 "$ROOT/DEBIAN/$SCRIPT"
    done
    python3 - "$PAYLOAD/usr/share/remoteipad/initial.json" <<'PY'
import base64, json, pathlib, re, sys
config = json.loads(pathlib.Path("private/rdp.json").read_text(encoding="utf-8-sig"))
assert config["schemaVersion"] == 3 and config["port"] == 3389
assert re.fullmatch(r"[0-9a-fA-F]{32}", config["ntHash"])
assert 1 <= len(config["username"]) <= 64 and not re.search(r"[\x00-\x1f\x7f-\x9f:\\]", config["username"])
assert len(base64.b64decode(config["salt"], validate=True)) == 32
assert len(base64.b64decode(config["passwordHash"], validate=True)) == 32
assert 310000 <= config["iterations"] <= 1000000
assert config["fps"] in (30, 60) and config["width"] == 1440 and 500000 <= config["bitrate"] <= 20000000
config["enabled"] = True
pathlib.Path(sys.argv[1]).write_text(json.dumps(config, indent=2), encoding="utf-8")
PY
    install -m 644 build/deps/FreeRDP/LICENSE "$PAYLOAD/usr/share/doc/com.xyhelper.remoteipad/FreeRDP-LICENSE"
    install -m 644 build/deps/openssl/LICENSE.txt "$PAYLOAD/usr/share/doc/com.xyhelper.remoteipad/OpenSSL-LICENSE"
    install -m 644 packaging/Input-NOTICE.txt "$PAYLOAD/usr/share/doc/com.xyhelper.remoteipad/Input-NOTICE.txt"
    find "$ROOT" -type d -exec chmod 755 {} +
    find "$PAYLOAD" -type f -name '*.plist' -exec chmod 644 {} +
    chmod 600 "$PAYLOAD/usr/share/remoteipad/initial.json"
    chmod 644 "$ROOT/DEBIAN/control"
    dpkg-deb --root-owner-group -Zxz --build "$ROOT" "packages/com.xyhelper.remoteipad_0.4.0~rc8_$ARCH.deb"
done
