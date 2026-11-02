import base64
import io
import json
import pathlib
import plistlib
import re
import struct
import subprocess
import tarfile
import tempfile

ROOT = pathlib.Path("/work")
for arch, prefix in (("iphoneos-arm", ""), ("iphoneos-arm64", "/var/jb")):
    package = ROOT / "packages" / f"com.xyhelper.remoteipad_0.4.0~rc8_{arch}.deb"
    assert package.is_file(), f"Missing {arch} package"
    actual_arch = subprocess.check_output(["dpkg-deb", "-f", str(package), "Architecture"], text=True).strip()
    assert actual_arch == arch
    assert subprocess.check_output(["dpkg-deb", "-f", str(package), "Version"], text=True).strip() == "0.4.0~rc8"
    assert subprocess.check_output(["dpkg-deb", "-f", str(package), "Name"], text=True).strip() == "XYHelper Remote RDP"
    payload = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", str(package)])
    with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
        members = {member.name.removeprefix("./"): member for member in archive.getmembers()}
        assert all(member.uid == member.gid == 0 and not member.mode & 0o022 for member in members.values())
        def read(relative):
            member = members[prefix.lstrip("/") + relative]
            assert member.uid == member.gid == 0
            return archive.extractfile(member).read()
        seed = json.loads(read("/usr/share/remoteipad/initial.json" if prefix else "usr/share/remoteipad/initial.json"))
        assert seed["enabled"] is True and seed["schemaVersion"] == 3 and seed["port"] == 3389
        assert len(base64.b64decode(seed["salt"], validate=True)) == 32
        assert len(base64.b64decode(seed["passwordHash"], validate=True)) == 32
        assert re.fullmatch(r"[0-9a-fA-F]{32}", seed["ntHash"])
        assert "password" not in seed
        assert members[(prefix + "/usr/share/remoteipad/initial.json").lstrip("/")].mode == 0o600
        assert not any(name.endswith((".key", "server.crt", "ca.crt")) for name in members)
        assert not any("pilot" in name for name in members)
        launch = plistlib.loads(read("/Library/LaunchDaemons/com.xyhelper.remoteipad.plist" if prefix else "Library/LaunchDaemons/com.xyhelper.remoteipad.plist"))
        assert launch["KeepAlive"] and launch["ProgramArguments"] == [prefix + "/usr/bin/remoteipadd"]
        assert launch["StandardErrorPath"] == prefix + "/var/lib/remoteipad/service.log"
        info = plistlib.loads(read("/Library/PreferenceBundles/RemoteIPad.bundle/Info.plist" if prefix else "Library/PreferenceBundles/RemoteIPad.bundle/Info.plist"))
        assert info["CFBundleDisplayName"] == "XYHelper Remote RDP"
        for binary in ("usr/bin/remoteipadd", "Library/PreferenceBundles/RemoteIPad.bundle/RemoteIPad",
                       "Library/MobileSubstrate/DynamicLibraries/RemoteIPadSettings.dylib"):
            data = read("/" + binary if prefix else binary)
            magic, cpu = struct.unpack_from("<II", data)
            assert magic == 0xFEEDFACF and cpu == 0x0100000C, "Payload must be ARM64 Mach-O"
            if not prefix:
                assert b"/var/jb" not in data, "Rootful binary must not reference rootless paths"
        daemon = read("/usr/bin/remoteipadd" if prefix else "usr/bin/remoteipadd")
        assert b"0.4.0~rc8" in daemon
        assert b"IOHIDEventCreateUnicodeEvent" in daemon
        assert b"cliprdr" in daemon
        assert b"MIT License" in read("/usr/share/doc/com.xyhelper.remoteipad/Input-NOTICE.txt" if prefix
                                     else "usr/share/doc/com.xyhelper.remoteipad/Input-NOTICE.txt")
        assert (prefix + "/var/lib/remoteipad/control.sock").encode() in daemon
        preferences = read("/Library/PreferenceBundles/RemoteIPad.bundle/RemoteIPad" if prefix else "Library/PreferenceBundles/RemoteIPad.bundle/RemoteIPad")
        def contains_label(label):
            return any(label.encode(encoding) in preferences for encoding in ("utf-8", "utf-16-le"))
        for label in ("启用 RDP 服务", "修改 RDP 账号密码", "连接协议", "RDP 客户端",
                      "软件版本", "视频分辨率", "编码帧率", "采集与提交耗时",
                      "空闲（未采集）", "未启用", "RDP / NLA / AVC420", "XYHelper Remote RDP"):
            assert contains_label(label), f"Missing RDP Settings label: {label}"
        for label in ("修改网页用户名和密码", "网页协议", "网页端口", "网页用户名",
                      "视频连接", "控制连接", "实际帧率"):
            assert not contains_label(label), f"Obsolete Settings label: {label}"
        hook = read("/Library/MobileSubstrate/DynamicLibraries/RemoteIPadSettings.dylib" if prefix else "Library/MobileSubstrate/DynamicLibraries/RemoteIPadSettings.dylib")
        assert (prefix + "/Library/PreferenceBundles/RemoteIPad.bundle").encode() in hook
        assert b"XYHelper Remote RDP" in hook and b"_PSIconImageKey" in hook
        with tempfile.NamedTemporaryFile() as stream:
            stream.write(hook)
            stream.flush()
            load = subprocess.check_output(["otool", "-l", stream.name], text=True)
            assert f"path {prefix}/Library/Frameworks " in load
            assert f"path {prefix}/usr/lib " in load
            assert "name @rpath/CydiaSubstrate.framework/CydiaSubstrate " in load
    control = subprocess.check_output(["dpkg-deb", "--ctrl-tarfile", str(package)])
    with tarfile.open(fileobj=io.BytesIO(control)) as archive:
        for script in ("postinst", "prerm"):
            member = archive.getmember("./" + script)
            text = archive.extractfile(member).read().decode()
            assert text.startswith(f"#!{prefix}/bin/sh\n")
            subprocess.run(["bash", "-n"], input=text, text=True, check=True)
            if script == "postinst":
                assert f"{prefix}/usr/bin/remoteipadd --prepare-install" in text
                assert 'executable" = "/Applications/Preferences.app/Preferences"' in text
                assert 'kill -KILL "$pid"' in text
    print(f"PASS: {arch} architecture, ARM64 binaries, paths, modes, settings, install scripts and private-key exclusion")
