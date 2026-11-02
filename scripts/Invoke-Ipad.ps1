[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Mandatory=$true)][string]$Command,
    [string]$Upload,
    [string]$RemotePath,
    [string]$Download,
    [string]$InputEnvironment,
    [switch]$Root
)
$ErrorActionPreference = 'Stop'
if (($Upload -or $Download) -and !$RemotePath) { throw 'RemotePath is required for file transfer' }
$inputData = $null
if ($InputEnvironment) {
    $inputData = [Environment]::GetEnvironmentVariable($InputEnvironment)
    if ($null -eq $inputData) { throw 'Requested input environment variable is missing' }
}
$env:IPAD_REQUEST = (@{
    command = $Command.Replace("`r", '')
    upload = $Upload
    remotePath = $RemotePath
    download = $Download
    root = $Root.IsPresent
    input = $inputData
} | ConvertTo-Json -Compress)
try {
@'
import hashlib, json, os, pathlib, re, shlex, sys, paramiko
request = json.loads(os.environ["IPAD_REQUEST"])
input_data = request["input"]
lines = pathlib.Path("login-ipad.md").read_text(encoding="utf-8-sig").splitlines()
match = re.search(r"ssh\s+([^@\s]+)@([^\s]+)", lines[0])
if not match:
    raise RuntimeError("Invalid SSH connection file")
class PinnedHost(paramiko.MissingHostKeyPolicy):
    def missing_host_key(self, client, hostname, key):
        digest = hashlib.sha256(key.asbytes()).hexdigest()
        if digest != "bc982f94a4fbd3e6054a3faf2a92a58708013c2c32fee8ce7ef14435926ae196":
            raise RuntimeError("iPad SSH host key changed; refusing connection")
client = paramiko.SSHClient()
client.set_missing_host_key_policy(PinnedHost())
client.connect(match[2], username=match[1], password=lines[1].split(":", 1)[1].strip(),
               timeout=30, auth_timeout=20, look_for_keys=False, allow_agent=False)
try:
    if request["upload"]:
        with client.open_sftp() as sftp:
            sftp.put(request["upload"], request["remotePath"])
    command = request["command"]
    root = request["root"]
    if root:
        command = "sudo -S -p '' /var/jb/bin/sh -c " + shlex.quote(command)
    stdin, stdout, stderr = client.exec_command(command, timeout=120)
    if root:
        stdin.write(lines[3].split(":", 1)[1].strip() + "\n")
        stdin.flush()
    if input_data is not None:
        stdin.write(input_data + "\n")
        stdin.flush()
        stdin.channel.shutdown_write()
    sys.stdout.buffer.write(stdout.read())
    sys.stderr.buffer.write(stderr.read())
    code = stdout.channel.recv_exit_status()
    if code == 0 and request["download"]:
        with client.open_sftp() as sftp:
            sftp.get(request["remotePath"], request["download"])
    sys.exit(code)
finally:
    client.close()
'@ | python -
if ($LASTEXITCODE -ne 0) { throw "iPad operation failed ($LASTEXITCODE)" }
} finally {
    [Environment]::SetEnvironmentVariable('IPAD_REQUEST',$null,'Process')
}
