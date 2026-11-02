[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dependencies = @(
    @{ Name = 'FreeRDP'; Url = 'https://github.com/FreeRDP/FreeRDP.git'; Tag = '3.32.2'; Commit = '97eff6ddfbbfaa8e42a126d362686bd001ff8bdc' },
    @{ Name = 'openssl'; Url = 'https://github.com/openssl/openssl.git'; Tag = 'openssl-3.5.9'; Commit = '45e844fa2a14ec92d146bd8f5778ac130b6625fb' }
)
New-Item -ItemType Directory -Force (Join-Path $root 'build\deps') | Out-Null
foreach ($dependency in $dependencies) {
    $path = Join-Path $root ('build\deps\' + $dependency.Name)
    if (!(Test-Path -LiteralPath $path)) {
        git clone --depth 1 --branch $dependency.Tag $dependency.Url $path
        if ($LASTEXITCODE -ne 0) { throw "Dependency download failed: $($dependency.Name)" }
    }
    $commit = git -C $path rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $commit -ne $dependency.Commit) {
        throw "Dependency revision mismatch: $($dependency.Name)"
    }
}
