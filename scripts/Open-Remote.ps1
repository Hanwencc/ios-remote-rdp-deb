[CmdletBinding()]
param(
    [string]$DeviceAddress = '192.168.88.120',
    [string]$Username,
    [string]$CertificatePath,
    [switch]$GenerateOnly
)
$ErrorActionPreference = 'Stop'
$ip = [Net.IPAddress]::Parse($DeviceAddress)
if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'IPv4 required' }
$root = Split-Path -Parent $PSScriptRoot
if (!$Username) {
    $config = Get-Content -LiteralPath (Join-Path $root 'private\rdp.json') -Raw | ConvertFrom-Json
    $Username = $config.username
}
if (!$Username -or $Username.Length -gt 64 -or $Username -match '[\x00-\x1f\x7f-\x9f:\\]') {
    throw 'Invalid RDP username'
}
if (!$CertificatePath) { $CertificatePath = Join-Path $root 'private\installed-server.crt' }
& "$root\tests\rdp-negotiation.ps1" -DeviceAddress $DeviceAddress -CertificatePath $CertificatePath
$connection = @"
full address:s:$DeviceAddress`:3389
username:s:$Username
screen mode id:i:1
desktopwidth:i:1080
desktopheight:i:1440
session bpp:i:32
smart sizing:i:1
prompt for credentials:i:1
enablecredsspsupport:i:1
authentication level:i:2
redirectclipboard:i:1
redirectprinters:i:0
redirectsmartcards:i:0
redirectcomports:i:0
drivestoredirect:s:
audiomode:i:2
bitmapcachepersistenable:i:0
"@
$file = Join-Path $root 'build\RemoteIPad.rdp'
[IO.File]::WriteAllText($file,$connection,[Text.Encoding]::Unicode)
$certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
    $CertificatePath)
try {
    Write-Output "Expected server SHA1 fingerprint: $($certificate.Thumbprint)"
    Write-Output ("Expected server SHA256 fingerprint: " +
        $certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256))
} finally { $certificate.Dispose() }
if ($GenerateOnly) {
    Write-Output "Connection file written: $file"
    return
}
$process = Start-Process -FilePath "$env:WINDIR\System32\mstsc.exe" -ArgumentList "`"$file`"" -PassThru
Write-Output "mstsc PID $($process.Id); enter the existing remote password and verify the server certificate."
$process.WaitForExit()
