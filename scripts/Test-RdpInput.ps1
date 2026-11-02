[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][int]$ClientProcessId,
    [switch]$SkipClipboard
)
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'Invoke-Ipad.ps1'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class RiInputTest {
    [StructLayout(LayoutKind.Sequential)] struct Keyboard {
        public ushort Key, Scan; public uint Flags, Time; public UIntPtr Extra;
    }
    [StructLayout(LayoutKind.Sequential)] struct Mouse {
        public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra;
    }
    [StructLayout(LayoutKind.Explicit)] struct Data {
        [FieldOffset(0)] public Keyboard Keyboard;
        [FieldOffset(0)] public Mouse Mouse;
    }
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public Data Data; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint first, uint second, bool attach);
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, Input[] input, int size);
    public static void Focus(IntPtr window) {
        if (IsIconic(window)) ShowWindow(window, 9);
        uint process;
        uint current = GetCurrentThreadId();
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out process);
        bool attached = current != foreground && AttachThreadInput(current, foreground, true);
        try { SetForegroundWindow(window); }
        finally { if (attached) AttachThreadInput(current, foreground, false); }
        Thread.Sleep(300); Guard(window);
    }
    public static void Guard(IntPtr window) {
        if (window == IntPtr.Zero || GetForegroundWindow() != window || IsIconic(window))
            throw new InvalidOperationException("RDP lost foreground focus; input test stopped. Expected=" +
                window + ", actual=" + GetForegroundWindow() + ", minimized=" + IsIconic(window));
    }
    public static void Scan(IntPtr window, ushort scan, bool down, bool extended) {
        Guard(window);
        var value = new Input { Type=1, Data=new Data { Keyboard=new Keyboard {
            Scan=scan, Flags=(uint)(8 | (down ? 0 : 2) | (extended ? 1 : 0)) } } };
        if (SendInput(1, new[] {value}, Marshal.SizeOf(typeof(Input))) != 1)
            throw new InvalidOperationException("Windows keyboard injection failed.");
        Thread.Sleep(30);
    }
    public static void Unicode(IntPtr window, string text) {
        foreach (char c in text) {
            Guard(window);
            var input = new[] {
                new Input { Type=1, Data=new Data { Keyboard=new Keyboard { Scan=c, Flags=4 } } },
                new Input { Type=1, Data=new Data { Keyboard=new Keyboard { Scan=c, Flags=6 } } }
            };
            if (SendInput(2, input, Marshal.SizeOf(typeof(Input))) != 2)
                throw new InvalidOperationException("Windows Unicode injection failed.");
            Thread.Sleep(30);
        }
    }
}
'@
$process = Get-Process -Id $ClientProcessId
if ($process.ProcessName -ne 'mstsc' -or !$process.MainWindowHandle) { throw 'Expected a visible mstsc process' }
$window = $process.MainWindowHandle
function Scan([int]$code, [bool]$down, [bool]$extended=$false) {
    [RiInputTest]::Scan($window,$code,$down,$extended)
}
function Key([int]$code, [bool]$extended=$false) {
    Scan $code $true $extended
    Scan $code $false $extended
}
function Read-Fixture {
    $encoded = & $helper -Root -Command 'base64 /var/mobile/Library/Caches/com.xyhelper.remoteipad-input-test.plist'
    [xml]$state = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($encoded -join '')))
    return [string]$state.plist.dict.string
}
function Expect-Text([string]$expected, [string]$name) {
    $actual = ''
    for ($i=0; $i -lt 8; $i++) {
        $actual = Read-Fixture
        if ($actual -ceq $expected) { Write-Output "PASS: $name"; return }
        Start-Sleep -Milliseconds 250
    }
    throw "$name failed: expected $($expected.Length) UTF-16 units, received $($actual.Length)"
}
function Reset-Fixture {
    & $helper -Root -Command 'uiopen --url remoteipad-input-test://reset; sleep 1'
    [RiInputTest]::Focus($window)
    Expect-Text '' 'isolated fixture reset'
}
$clipboardBackup = $null
$clipboardChanged = $false
if (!$SkipClipboard) {
    $currentClipboard = [Windows.Forms.Clipboard]::GetDataObject()
    if ($currentClipboard) {
        $clipboardBackup = New-Object Windows.Forms.DataObject
        foreach ($format in $currentClipboard.GetFormats($false)) {
            $value = $currentClipboard.GetData($format,$false)
            if ($null -eq $value -or
                ($value -isnot [string] -and $value -isnot [IO.MemoryStream] -and $value -isnot [byte[]])) {
                throw 'Clipboard has formats this test cannot safely restore. Save it first, or use -SkipClipboard.'
            }
            if ($value -is [IO.MemoryStream]) {
                if ($value.Length -gt 8MB) { throw 'Clipboard backup exceeds the test limit' }
                $value = [IO.MemoryStream]::new($value.ToArray())
            } elseif ($value.Length -gt 8MB) { throw 'Clipboard backup exceeds the test limit' }
            $clipboardBackup.SetData($format,$false,$value)
        }
    }
}
try {
    Reset-Fixture
    Key 0x1e
    Expect-Text 'a' 'RDP letter scan'
    Scan 0x2a $true
    Key 0x30
    Scan 0x2a $false
    Expect-Text 'aB' 'RDP shifted scan'
    Key 0x2e
    Expect-Text 'aBc' 'RDP scan codes and Shift'
    Key 0x4b $true
    Key 0x0e
    Expect-Text 'ac' 'left arrow and Backspace'
    Key 0x4d $true
    Key 0x1c
    Expect-Text "ac`n" 'Enter'
    Scan 0x1d $true
    Key 0x1e
    Scan 0x1d $false
    Key 0x0e
    Expect-Text '' 'Ctrl+A maps to iOS Command+A'

    $unicode = ([string][char]0x4e2d) + [char]0x6587 + ' ' + [char]0xd83c + [char]0xdf31
    [RiInputTest]::Unicode($window,$unicode)
    Expect-Text $unicode 'mstsc Unicode Chinese and emoji'

    if (!$SkipClipboard) {
        Reset-Fixture
        $plain = "RDP " + $unicode + "`r`nsecond line"
        [Windows.Forms.Clipboard]::SetText($plain)
        $clipboardChanged = $true
        Start-Sleep -Seconds 1
        Scan 0x1d $true
        Key 0x2f
        Scan 0x1d $false
        Expect-Text ($plain.Replace("`r`n","`n")) 'CLIPRDR Ctrl+V Chinese, emoji and multiline'
        Scan 0x1d $true
        Key 0x2f
        Scan 0x1d $false
        Expect-Text (($plain.Replace("`r`n","`n")) * 2) 'second Ctrl+V inserts exactly once'
        Key 0x2d
        Expect-Text ((($plain.Replace("`r`n","`n")) * 2) + 'x') 'Control released after paste'
        Reset-Fixture
        $longText = ('line ' + $unicode + "`n") * 1024
        [Windows.Forms.Clipboard]::SetText($longText)
        Start-Sleep -Seconds 1
        Scan 0x1d $true
        Scan 0x2f $true
        Scan 0x2f $true
        Scan 0x2f $true
        Scan 0x2f $false
        Scan 0x1d $false
        Expect-Text $longText 'long chunked paste and held-V repeat suppression'
        Scan 0x1d $true
        Key 0x1e
        Scan 0x1d $false
        [Windows.Forms.Clipboard]::SetText('replacement')
        Start-Sleep -Seconds 1
        Scan 0x1d $true
        Key 0x2f
        Scan 0x1d $false
        Expect-Text 'replacement' 'paste replaces selected text'
    }
} finally {
    $remaining = Get-Process -Id $ClientProcessId -ErrorAction SilentlyContinue
    if ($remaining -and $remaining.MainWindowHandle -eq $window) {
        try {
            [RiInputTest]::Guard($window)
            foreach ($code in @(0x1d,0x2a,0x36,0x38)) { Scan $code $false }
        } catch { Write-Warning 'RDP focus lost; disconnect the session if a modifier remains pressed.' }
    }
    if ($clipboardChanged) {
        if ($clipboardBackup) { [Windows.Forms.Clipboard]::SetDataObject($clipboardBackup,$true) }
        else { [Windows.Forms.Clipboard]::Clear() }
    }
}
