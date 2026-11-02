[CmdletBinding()]
param([switch]$CleanOldVersion)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$package = Join-Path $root 'packages\com.xyhelper.remoteipad_0.4.0~rc8_iphoneos-arm64.deb'
if (!(Test-Path -LiteralPath $package -PathType Leaf)) { throw 'Build the rootless package first' }
$upload = '/var/mobile/remoteipad-' + [Guid]::NewGuid().ToString('N') + '.deb'
& "$PSScriptRoot\Invoke-Ipad.ps1" -Root -Command "set -eu; test -L /var/jb; test ! -e $upload; test ! -L $upload; umask 077; touch $upload; chown mobile:mobile $upload"
$cleanup = if ($CleanOldVersion) {
@'
for path in /var/jb/var/lib/remoteipad /var/jb/var/lib/remoteipad-pilot /var/mobile/Library/RemoteIPad; do
    test ! -L "$path"
    if [ -e "$path" ]; then test -d "$path"; fi
done
for label in com.xyhelper.remoteipad.pilot com.xyhelper.remoteipad; do
    if launchctl print "system/$label" >/dev/null 2>&1; then
        launchctl bootout "system/$label"
    fi
done
dpkg --purge com.xyhelper.remoteipad
rm -rf /var/jb/var/lib/remoteipad /var/jb/var/lib/remoteipad-pilot /var/mobile/Library/RemoteIPad
rm -f /var/jb/Library/LaunchDaemons/com.xyhelper.remoteipad.pilot.plist
test ! -e /var/jb/var/lib/remoteipad
test ! -e /var/jb/var/lib/remoteipad-pilot
test ! -e /var/mobile/Library/RemoteIPad
echo "Old Remote iPad package, configurations and pilot removed."
'@
} else { '' }
try {
    $command = "set -eu`ntest -L /var/jb`n$cleanup`ndpkg -i $upload`ntest -L /var/jb`nsleep 3`ndpkg-query -W com.xyhelper.remoteipad"
    & "$PSScriptRoot\Invoke-Ipad.ps1" -Root -Upload $package -RemotePath $upload -Command $command
} finally {
    & "$PSScriptRoot\Invoke-Ipad.ps1" -Root -Command "rm -f $upload"
}
$certificate = & "$PSScriptRoot\Invoke-Ipad.ps1" -Root -Command 'base64 /var/jb/var/lib/remoteipad/server.crt'
[IO.File]::WriteAllBytes((Join-Path $root 'private\installed-server.crt'),
    [Convert]::FromBase64String(($certificate -join '').Trim()))
Write-Output 'Installed rootless package; saved the new public certificate for exact client identity checks.'
