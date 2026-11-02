[CmdletBinding()]
param([switch]$Probe, [switch]$Foundation, [switch]$Dependencies)
$ErrorActionPreference = 'Stop'
if (([int]$Probe.IsPresent + [int]$Foundation.IsPresent + [int]$Dependencies.IsPresent) -gt 1) {
    throw 'Choose only one build mode'
}
$root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\PrivateFiles.ps1"
if (!$Probe -and !$Foundation -and !$Dependencies) {
    Protect-RiPrivateDirectory (Join-Path $root 'packages')
    Protect-RiPrivateDirectory (Join-Path $root 'private')
}
docker build -t remoteipad-builder:local $root
if ($LASTEXITCODE -ne 0) { throw 'Docker builder image failed' }
$command = if ($Dependencies) { "tr -d '\r' < scripts/dependencies.sh | bash" } elseif ($Probe) {
    "tr -d '\r' < scripts/probe.sh | bash"
} elseif ($Foundation) {
    "tr -d '\r' < scripts/build.sh | bash -s -- --foundation"
} else {
    "tr -d '\r' < scripts/build.sh | bash -s -- --packages"
}
docker run --rm --network none --mount "type=bind,source=$root,target=/work" remoteipad-builder:local -c $command
if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }
