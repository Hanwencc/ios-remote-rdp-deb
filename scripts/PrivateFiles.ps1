function New-RiPrivateAccessControl([switch]$Directory) {
    $acl = if ($Directory) {
        [Security.AccessControl.DirectorySecurity]::new()
    } else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true,$false)
    $inheritance = if ($Directory) { 'ContainerInherit,ObjectInherit' } else { 'None' }
    foreach ($identity in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity,'FullControl',$inheritance,'None','Allow'))
    }
    return $acl
}

function Protect-RiPrivateDirectory([string]$Path) {
    $directory = New-Item -ItemType Directory -Force -Path $Path
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing to change private-directory permissions through a link'
    }
    [IO.Directory]::SetAccessControl($directory.FullName,(New-RiPrivateAccessControl -Directory))
}

function Write-RiPrivateText([string]$Path,[string]$Text) {
    $path = [IO.Path]::GetFullPath($Path)
    if ((Test-Path -LiteralPath $path) -and
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Refusing to write credentials through a link'
    }
    $acl = New-RiPrivateAccessControl
    $stream = [IO.FileStream]::new($path,[IO.FileMode]::OpenOrCreate,
        [Security.AccessControl.FileSystemRights]::FullControl,[IO.FileShare]::None,
        4096,[IO.FileOptions]::None,$acl)
    try {
        $stream.SetAccessControl($acl)
        $stream.SetLength(0)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes,0,$bytes.Length)
    } finally { $stream.Dispose() }
}
