[CmdletBinding()]
param([string]$DeviceAddress = '192.168.88.120')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $PSScriptRoot 'Invoke-Ipad.ps1'
. "$PSScriptRoot\Nla.ps1"
$id = [Guid]::NewGuid().ToString('N')
$upload = "/var/mobile/remoteipad-test-$id"
$directory = "/var/jb/var/lib/remoteipad-test-$id"
$backedUp = $false
function Request([hashtable]$body) {
    $env:RI_TEST_INPUT = $body | ConvertTo-Json -Compress
    try {
        $response = & $helper -Root -Command "$directory/management-test" -InputEnvironment RI_TEST_INPUT
        $reply = ($response -join "`n") | ConvertFrom-Json
        if (!$reply.ok) { throw 'Management operation was not successful' }
        return $reply.state
    } finally { Remove-Item Env:\RI_TEST_INPUT }
}
function Read-Configuration {
    $text = & $helper -Root -Command 'cat /var/jb/var/lib/remoteipad/config.json'
    return (($text -join "`n") | ConvertFrom-Json)
}
function Assert-Port([bool]$expected) {
    $client = [Net.Sockets.TcpClient]::new()
    $open = $false
    try {
        $task = $client.ConnectAsync($DeviceAddress,3389)
        if ($expected) {
            if (!$task.Wait(5000)) { throw 'Enabled service did not accept TCP' }
            $open = $client.Connected
        } else {
            if (!([IAsyncResult]$task).AsyncWaitHandle.WaitOne(5000)) { throw 'Disabled-port check timed out' }
            $open = !$task.IsFaulted -and $client.Connected
        }
        if ($open -ne $expected) { throw 'RDP TCP state does not match the service switch' }
    } finally { $client.Dispose() }
}
& $helper -Root -Command "set -eu; umask 077; test ! -e $upload; test ! -L $upload; touch $upload; chown mobile:mobile $upload"
try {
    & $helper -Root -Upload (Join-Path $root 'build\rootless\management-test') -RemotePath $upload `
        -Command "set -eu; test -L /var/jb; test ! -e $directory; test ! -L $directory; umask 077; mkdir $directory; cp $upload $directory/management-test; chmod 755 $directory/management-test; chown root:wheel $directory/management-test; cp /var/jb/var/lib/remoteipad/config.json $directory/config.backup; chmod 600 $directory/config.backup"
    $backedUp = $true
    $original = Read-Configuration
    & $helper -Root -Command 'set -eu; launchctl bootout system/com.xyhelper.remoteipad; launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.xyhelper.remoteipad.plist; sleep 2'
    $state = Request @{op='status'}
    if (!$state.enabled -or !$state.listening -or $state.version -ne '0.4.0~rc8' -or $state.error) {
        throw 'Fresh installed service is not healthy'
    }
    $state = Request @{op='setEnabled'; enabled=$false}
    if ($state.enabled -or $state.listening -or $state.clientConnected -or $state.capture -ne 'idle') {
        throw 'Disabling did not stop networking and capture'
    }
    Assert-Port $false
    if ((Read-Configuration).enabled) { throw 'Disabled switch was not persisted' }
    $certificateBefore = & $helper -Root -Command 'base64 /var/jb/var/lib/remoteipad/server.crt'
    & $helper -Root -Command 'set -eu; /var/jb/usr/bin/remoteipadd --prepare-install; launchctl bootout system/com.xyhelper.remoteipad; launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.xyhelper.remoteipad.plist; sleep 2'
    $state = Request @{op='status'}
    if ($state.enabled -or $state.listening -or $state.capture -ne 'idle') {
        throw 'Disabled switch did not survive installation preparation and daemon restart'
    }
    Assert-Port $false
    $prepared = Read-Configuration
    foreach ($field in @('username','salt','passwordHash','iterations','ntHash','port','schemaVersion')) {
        if ($prepared.$field -ne $original.$field) { throw 'Repeated installation preparation reset existing credentials' }
    }
    $certificateAfter = & $helper -Root -Command 'base64 /var/jb/var/lib/remoteipad/server.crt'
    if (($certificateBefore -join '') -ne ($certificateAfter -join '')) {
        throw 'Repeated installation preparation replaced the device certificate'
    }
    $state = Request @{op='setEnabled'; enabled=$true}
    if (!$state.enabled -or !$state.listening -or $state.error) { throw 'Re-enabling failed' }
    Assert-Port $true
    $name = 'verify-' + $id.Substring(0,12)
    $password = 'verify-' + [char]0x4e2d + '-' + [Guid]::NewGuid().ToString('N')
    $state = Request @{op='setCredentials'; username=$name; password=$password}
    if ($state.username -ne $name -or !$state.listening -or $state.clientConnected -or $state.error) {
        throw 'Changing credentials failed to reset the connection and restart authentication'
    }
    $changed = Read-Configuration
    $bytes = [Text.Encoding]::Unicode.GetBytes($password)
    $nt = [RINtHash]::Compute($bytes)
    $expectedNt = [BitConverter]::ToString($nt).Replace('-','').ToLowerInvariant()
    [Array]::Clear($bytes,0,$bytes.Length)
    [Array]::Clear($nt,0,$nt.Length)
    $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new(
        $password,[Convert]::FromBase64String($changed.salt),$changed.iterations,
        [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $expectedHash = [Convert]::ToBase64String($kdf.GetBytes(32)) } finally { $kdf.Dispose() }
    if ($changed.username -ne $name -or $changed.ntHash -ne $expectedNt -or
        $changed.passwordHash -ne $expectedHash -or $changed.schemaVersion -ne 3 -or !$changed.enabled) {
        throw 'Updated PBKDF2 and Unicode NLA credentials do not match'
    }
    $sam = & $helper -Root -Command 'cat /var/jb/var/lib/remoteipad/nla.sam'
    if (($sam -join "`n").Trim() -ne "${name}:::${expectedNt}:") {
        throw 'The active NLA authentication store was not refreshed'
    }
    & $helper -Root -Command 'launchctl bootout system/com.xyhelper.remoteipad; launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.xyhelper.remoteipad.plist; sleep 2'
    $state = Request @{op='status'}
    if ($state.username -ne $name -or !$state.enabled -or !$state.listening) {
        throw 'New credentials or switch were not preserved across daemon restart'
    }
    Write-Output 'PASS: service off/on, closed/open TCP, idle capture, disabled restart, idempotent installation, preserved certificate, Unicode PBKDF2 + NT hash, refreshed NLA store and restart persistence.'
} finally {
    if (Test-Path Env:\RI_TEST_INPUT) { Remove-Item Env:\RI_TEST_INPUT }
    if ($backedUp) {
        & $helper -Root -Command "set -eu; launchctl bootout system/com.xyhelper.remoteipad; cp $directory/config.backup /var/jb/var/lib/remoteipad/config.json; chmod 600 /var/jb/var/lib/remoteipad/config.json; launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.xyhelper.remoteipad.plist; sleep 2"
        $restored = Read-Configuration
        foreach ($field in @('username','salt','passwordHash','iterations','ntHash','enabled','port','schemaVersion')) {
            if ($restored.$field -ne $original.$field) { throw 'Restoring the new-install account failed; test backup retained' }
        }
        $state = Request @{op='status'}
        if (!$state.listening -or $state.error) { throw 'Restored service is not healthy; test backup retained' }
        & $helper -Root -Command "rm -rf $directory; rm -f $upload"
        Write-Output 'PASS: restored the fresh-install account and enabled service; temporary configuration and test tool removed.'
    } else {
        & $helper -Root -Command "rm -f $upload"
    }
}
& "$root\tests\rdp-negotiation.ps1" -DeviceAddress $DeviceAddress
