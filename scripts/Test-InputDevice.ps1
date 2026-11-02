[CmdletBinding()]
param([switch]$KeepFixture, [switch]$CleanupOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $PSScriptRoot 'Invoke-Ipad.ps1'
$app = '/var/jb/Applications/RemoteIPadInputTest.app'
$cache = '/var/mobile/Library/Caches/com.xyhelper.remoteipad-input-test.plist'
function Remove-Fixture {
    & $helper -Root -Command @"
set -eu
if [ -e $app ]; then
    test ! -L $app
    grep -q '<string>com.xyhelper.remoteipad.input-test</string>' $app/Info.plist
    actual=`$(cd $app && pwd -P)
    ps -A -o pid=,comm= | while read -r pid executable; do
        if [ "`$executable" = "`$actual/InputFixture" ]; then kill -TERM "`$pid"; fi
    done
    $app/InputFixture --unregister
    rm -rf $app
fi
rm -f $cache
"@
}
if ($CleanupOnly) { Remove-Fixture; return }
$id = [Guid]::NewGuid().ToString('N')
$directory = "/var/jb/var/tmp/remoteipad-input-test-$id"
$upload = "/var/mobile/remoteipad-input-test-$id.tar"
$archive = Join-Path $root "build\input-test-$id.tar"
$created = $false
try {
    foreach ($file in @('build\InputFixture.app\InputFixture','build\input-device','build\rootless\input-flow-test')) {
        if (!(Test-Path -LiteralPath (Join-Path $root $file))) { throw 'Build packages and Build.ps1 -Probe first' }
    }
    & $helper -Root -Command "set -eu; test ! -e $app; test ! -e $directory; test ! -e $upload; umask 077; touch $upload; chown mobile:mobile $upload; mkdir $directory"
    & tar.exe -cf $archive -C (Join-Path $root 'build') InputFixture.app input-device -C rootless input-flow-test latency-flow-test output-flow-test preferences-test
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create native input test archive' }
    & $helper -Upload $archive -RemotePath $upload -Command 'true'
    & $helper -Root -Command @"
set -eu
tar -xf $upload -C $directory
cp -R $directory/InputFixture.app $app
chmod 755 $app/InputFixture $directory/input-device $directory/input-flow-test $directory/latency-flow-test $directory/output-flow-test $directory/preferences-test
uicache -p $app
"@
    $created = $true
    & $helper -Root -Command "set -eu; $directory/input-flow-test; $directory/latency-flow-test; $directory/output-flow-test; $directory/preferences-test; uiopen --url remoteipad-input-test://reset; sleep 2"
    $text = 'AbC 123 ' + [char]0x4e2d + [char]0x6587 + ' ' + [char]0xd83c + [char]0xdf31 + " e" + [char]0x0301 + "`nsecond line"
    $quoted = "'" + $text.Replace("'","'\''") + "'"
    & $helper -Root -Command "set -eu; $directory/input-device --text $quoted; sleep 1"
    $encoded = & $helper -Root -Command "base64 $cache"
    [xml]$state = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($encoded -join '')))
    if ([string]$state.plist.dict.string -cne $text) { throw 'Unicode HID did not produce the exact expected fixture text' }
    Write-Output 'PASS: standalone Unicode HID actual text includes Chinese, emoji, combining character and newline.'
} finally {
    try {
        if ($created -and !$KeepFixture) { Remove-Fixture }
    } finally {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
        & $helper -Root -Command "set -eu; test ! -L $directory; if [ -d $directory ]; then rm -rf $directory; fi; rm -f $upload"
    }
}
