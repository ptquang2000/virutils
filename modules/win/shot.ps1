# shot -- capture a running domain's screen to a PNG on this host.
#
# The counterpart of modules/linux/shot and modules/mac/shot. All three ask the
# hypervisor for the frame rather than the guest: here it is `screendump` on
# the QEMU monitor, which qemu answers by writing the file itself. Nothing is
# staged in the guest, no input is sent, and the guest is never told -- so a
# shot works on a guest with no agent, one still in firmware or Setup, and one
# that has hung.
#
# **What it captures is qemu's console, not a remote desktop.** The frame is the
# emulated VGA's, which is what the domain's own window shows: the physical
# console session, or the logon screen when nobody is on it. An RDP session is
# a separate session with its own desktop, and is not in it.
#
# PNG straight from qemu (`-f png`), because this host's qemu has libpng --
# measured on v11.1.0-12130: a q35 under -S gave a 1569-byte PNG. A build
# without it refuses the format by name, and only then does this fall back to
# qemu's PPM and convert it here (ConvertFrom-ShotPpm).
#
# qemu writes the file into <root>\tmp first and it is moved into place after,
# so a failed capture never truncates a file that -o already names.

function Get-ShotUsage {
    @(
        'usage: virutil shot VM [-o FILE]'
        ''
        "Capture VM's screen to a PNG on this host and print its path."
        ''
        '  -o, --output FILE  where to write it (default: VM-YYYYMMDD-HHMMSS.png'
        '                     in the current directory). An existing FILE is'
        '                     replaced. It is PNG whatever its extension.'
        '  -h, --help         this message'
        ''
        "The frame is the domain's emulated display, taken over the QEMU"
        'monitor: what its window shows, firmware and logon screen included.'
        'An RDP session is a separate desktop and is not in it. Nothing runs in'
        'the guest and no input is sent, so the guest needs no agent.'
    )
}

function Shot-Main {
    param([string[]]$Arguments)

    $vm = $null; $out = $null
    $i = 0
    while ($i -lt $Arguments.Count) {
        $a = $Arguments[$i]
        if ($a -in @('-h', '--help')) {
            Usage (Get-ShotUsage) 0
        } elseif ($a -in @('-o', '--output')) {
            $i++
            if ($i -ge $Arguments.Count) { Die "virutil shot: $a needs a value" }
            $out = $Arguments[$i]
        } elseif ($a.StartsWith('-')) {
            Die "virutil shot: unknown flag: $a (see: virutil shot -h)"
        } elseif ($null -eq $vm) {
            $vm = $a
        } else {
            Usage (Get-ShotUsage) 1
        }
        $i++
    }
    if (-not $vm) { Usage (Get-ShotUsage) 1 }
    if (-not (Test-Domain $vm)) { Die "no such domain: $vm (see: virutil domain list)" }
    if (-not (Test-DomainRunning $vm)) { Die "$vm is not running: there is no display to capture" }

    $cwd = (Get-Location).ProviderPath
    if (-not $out) { $out = '{0}-{1:yyyyMMdd-HHmmss}.png' -f $vm, (Get-Date) }
    $out = [IO.Path]::GetFullPath([IO.Path]::Combine($cwd, $out))
    $dir = Split-Path -Parent $out
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Die "virutil shot: no such directory: $dir"
    }

    $tmp = New-VirutilsDir $script:VirutilsTmpDir
    $token = [Guid]::NewGuid().ToString('N')
    $png = Join-Path $tmp "shot-$token.png"
    $ppm = Join-Path $tmp "shot-$token.ppm"
    try {
        $reply = Invoke-ShotScreendump $vm $png 'png'
        if ($reply -match '(?i)libpng|png support') {
            Say "this qemu cannot write PNG; taking a PPM and converting it"
            $reply = Invoke-ShotScreendump $vm $ppm 'ppm'
            Assert-ShotWritten $vm $ppm $reply
            ConvertFrom-ShotPpm $ppm $png
        } else {
            Assert-ShotWritten $vm $png $reply
        }
        if (-not (Test-ShotPng $png)) { Die "$vm's QEMU monitor answered the screendump but wrote no PNG" }
        [IO.File]::Copy($png, $out, $true)
    } finally {
        Remove-VirutilsFile $png | Out-Null
        Remove-VirutilsFile $ppm | Out-Null
    }

    $size = Get-ShotPngSize $out
    Say "$vm`: $($size.Width)x$($size.Height)"
    [Console]::Out.WriteLine($out)
}

# Invoke-ShotScreendump VM FILE FORMAT -- the monitor's reply, or $null.
#
# The path goes in double quotes, which is the one way the human monitor takes
# a word with a space in it -- and inside them it reads C-style escapes, so a
# Windows path's backslashes are doubled or `\U` in C:\Users is refused as an
# unknown escape. Unquoted it would take backslashes literally and stop at the
# first space instead.
function Invoke-ShotScreendump {
    param([string]$Vm, [string]$File, [string]$Format)
    $quoted = '"' + ($File -replace '\\', '\\' -replace '"', '\"') + '"'
    return (Invoke-DomainMonitor $Vm "screendump $quoted -f $Format")
}

# Assert-ShotWritten VM FILE REPLY -- dies unless qemu wrote FILE.
#
# The monitor gives no status, only prose on failure, so both are read: a
# complaint in the reply, and then the file itself. qemu writes it before it
# prints the next prompt, which Invoke-DomainMonitor has drained past, so a
# short wait covers only a slow disk.
function Assert-ShotWritten {
    param([string]$Vm, [string]$File, $Reply)
    if ($null -eq $Reply) { Die "could not reach $Vm's QEMU monitor to take a screendump" }
    $clean = $Reply -replace "$([char]27)\[[0-9;]*[A-Za-z]", ''
    $err = [regex]::Match($clean, '(?m)^\s*(Error: .*|Could not .*|could not .*)$')
    if ($err.Success) {
        Die @("the QEMU monitor refused the screendump:", $err.Groups[1].Value.Trim())
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Test-Path -LiteralPath $File) -and (Get-Item -LiteralPath $File).Length -gt 0) { return }
        Start-Sleep -Milliseconds 200
    }
    Die @(
        "$Vm's QEMU monitor answered but wrote no screendump. Only one client"
        'is served at a time, so something else holding the monitor port may'
        'have had it. Nothing was changed.'
    )
}

# Test-ShotPng FILE -- does it start with the PNG signature?
function Test-ShotPng {
    param([string]$File)
    $b = New-Object byte[] 8
    $f = [IO.File]::OpenRead($File)
    try { $n = $f.Read($b, 0, 8) } finally { $f.Dispose() }
    return ($n -eq 8 -and (($b | ForEach-Object { '{0:x2}' -f $_ }) -join '') -eq '89504e470d0a1a0a')
}

# Get-ShotPngSize FILE -- @{ Width; Height } from the IHDR chunk, which a PNG
# always carries first: big-endian at offsets 16 and 20.
function Get-ShotPngSize {
    param([string]$File)
    $b = New-Object byte[] 24
    $f = [IO.File]::OpenRead($File)
    try { [void]$f.Read($b, 0, 24) } finally { $f.Dispose() }
    $be = { param($o) ([int]$b[$o] -shl 24) -bor ([int]$b[$o + 1] -shl 16) -bor ([int]$b[$o + 2] -shl 8) -bor [int]$b[$o + 3] }
    return @{ Width = (& $be 16); Height = (& $be 20) }
}

# ConvertFrom-ShotPpm PPM PNG -- qemu's binary PPM (P6, maxval 255) to PNG.
#
# System.Drawing encodes PNG on both PowerShells here but reads no PPM, so the
# pixels are copied in by row. A 24bpp bitmap is BGR, and reversing each row's
# bytes turns RGB into BGR at the cost of mirroring the row, which one
# RotateFlip puts back: a native call per row rather than a script loop over
# every pixel.
function ConvertFrom-ShotPpm {
    param([string]$Ppm, [string]$Png)
    $data = [IO.File]::ReadAllBytes($Ppm)
    $fields = @(); $pos = 0
    while ($fields.Count -lt 4) {
        while ($pos -lt $data.Length -and [char]$data[$pos] -match '\s') { $pos++ }
        if ($pos -lt $data.Length -and $data[$pos] -eq 0x23) {
            while ($pos -lt $data.Length -and $data[$pos] -ne 0x0A) { $pos++ }
            continue
        }
        $start = $pos
        while ($pos -lt $data.Length -and [char]$data[$pos] -notmatch '\s') { $pos++ }
        if ($pos -eq $start) { Die "not a PPM: $Ppm" }
        $fields += [Text.Encoding]::ASCII.GetString($data, $start, $pos - $start)
    }
    $pos++
    if ($fields[0] -ne 'P6' -or $fields[3] -ne '255') {
        Die "unexpected screendump format ($($fields[0]), maxval $($fields[3])): $Ppm"
    }
    $w = [int]$fields[1]; $h = [int]$fields[2]
    if ($data.Length - $pos -lt $w * $h * 3) { Die "truncated PPM: $Ppm" }

    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap($w, $h, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $lock = $bmp.LockBits((New-Object Drawing.Rectangle(0, 0, $w, $h)),
            [Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
        $row = New-Object byte[] ($w * 3)
        for ($y = 0; $y -lt $h; $y++) {
            [Array]::Copy($data, $pos + $y * $w * 3, $row, 0, $row.Length)
            [Array]::Reverse($row)
            [Runtime.InteropServices.Marshal]::Copy($row, 0,
                [IntPtr]::Add($lock.Scan0, $y * $lock.Stride), $row.Length)
        }
        $bmp.UnlockBits($lock)
        $bmp.RotateFlip([Drawing.RotateFlipType]::RotateNoneFlipX)
        $bmp.Save($Png, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bmp.Dispose()
    }
}
