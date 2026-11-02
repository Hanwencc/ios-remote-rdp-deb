[CmdletBinding()]
param(
    [string]$DeviceAddress = '192.168.88.120',
    [string]$CertificatePath,
    [ValidateSet('Tls12','Tls13')][string]$TlsVersion = 'Tls12'
)
$ErrorActionPreference = 'Stop'
if (!$CertificatePath) {
    $CertificatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'private\installed-server.crt'
}
$protocol = [Security.Authentication.SslProtocols][Enum]::Parse(
    [Security.Authentication.SslProtocols],$TlsVersion)
$certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
    $CertificatePath)
$expected = $certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256)
$client = New-Object Net.Sockets.TcpClient
$tls = $null
try {
    if (!$client.ConnectAsync($DeviceAddress,3389).Wait(15000)) { throw 'RDP TCP connect timeout' }
    $stream = $client.GetStream()
    $stream.ReadTimeout = 5000
    $stream.WriteTimeout = 5000
    $request = [byte[]](3,0,0,19,14,224,0,0,0,0,0,1,0,8,0,3,0,0,0)
    $stream.Write($request,0,$request.Length)
    $response = New-Object byte[] 19
    $received = 0
    while ($received -lt $response.Length) {
        $count = $stream.Read($response,$received,$response.Length-$received)
        if ($count -eq 0) { throw 'RDP negotiation connection closed' }
        $received += $count
    }
    if ($response[0] -ne 3 -or $response[3] -ne 19 -or $response[11] -ne 2 -or
        [BitConverter]::ToUInt32($response,15) -ne 2) {
        throw 'Server did not select TLS + NLA (HYBRID)'
    }
    $validation = [Net.Security.RemoteCertificateValidationCallback]{
        param($sender,$remote,$chain,$errors)
        $script:serverChainStatus = @($chain.ChainStatus | ForEach-Object { $_.Status.ToString() })
        $script:incompleteChain = @($chain.ChainStatus | Where-Object {
            ($_.Status -band [Security.Cryptography.X509Certificates.X509ChainStatusFlags]::PartialChain) -ne 0
        }).Count -gt 0
        $leaf = New-Object Security.Cryptography.X509Certificates.X509Certificate2($remote)
        try {
            $nameMismatch = ($errors -band [Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) -ne 0
            return !$nameMismatch -and $leaf.NotBefore -le [DateTime]::Now -and
                $leaf.NotAfter -ge [DateTime]::Now -and
                $leaf.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256) -eq $expected
        } finally { $leaf.Dispose() }
    }
    $tls = New-Object Net.Security.SslStream($stream,$false,$validation)
    $tls.AuthenticateAsClient($DeviceAddress,$null,$protocol,$false)
    if (!$tls.IsEncrypted -or $tls.SslProtocol -ne $protocol) {
        throw 'TLS encryption is not confirmed'
    }
    if ($script:incompleteChain) { throw 'Server certificate chain is incomplete (PartialChain)' }
    Write-Output "RDP negotiated HYBRID/NLA; $($tls.SslProtocol) encrypted; exact server certificate pin and address verified."
    Write-Output "Certificate chain status: $($script:serverChainStatus -join ', ')"
    Write-Output 'This validates negotiation and server identity only, not password authentication or video.'
} finally {
    if ($tls) { $tls.Dispose() }
    $client.Dispose()
    $certificate.Dispose()
}
