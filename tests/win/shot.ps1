<#
.SYNOPSIS
  shot on a Windows host: the monitor seam substituted, then a real qemu.

.DESCRIPTION
  The seam is Invoke-DomainMonitor, so the screendump line the monitor would
  have been sent is captured and its reply is chosen. What is asserted:

    * the grammar and its exit codes, which are contract;
    * the path reaches the monitor quoted, with its backslashes escaped;
    * a refusal in the reply, no reply, and no file are each failures;
    * a qemu without libpng is answered with its PPM, converted here, pixels
      intact, and the scratch files go either way;
    * against a real qemu -- paused, no disk, no guest, its monitor on a
      loopback port -- the driver writes a real PNG where -o says, replaces an
      existing file, and picks a name in the current directory without -o.

  The real-qemu half skips itself when no qemu is installed.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $here)
$moduleDir = Join-Path $root 'modules\win'
$env:VIRUTILS_DIR = Join-Path ([IO.Path]::GetTempPath()) ("virutil-test-" + [Guid]::NewGuid().ToString('N'))

. (Join-Path $moduleDir 'parser.ps1')
. (Join-Path $moduleDir 'paths.ps1')
. (Join-Path $moduleDir 'domain.ps1')
. (Join-Path $moduleDir 'shot.ps1')

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, $Want, $Got)
    if ("$Want" -eq "$Got") { [Console]::Out.WriteLine("ok       $Name"); $script:Pass++ }
    else {
        [Console]::Out.WriteLine("FAIL     $Name")
        [Console]::Out.WriteLine("         wanted [$Want], got [$Got]")
        $script:Fail++
    }
}
function CheckTrue { param([string]$Name, $Got) Check $Name $true ([bool]$Got) }

# Dies BODY -- the message and the exit code a thrown virutil error carries, or
# an empty message and $null if BODY returned.
function Dies {
    param([scriptblock]$Body)
    try { & $Body | Out-Null; return @{ Msg = ''; Code = $null } }
    catch {
        $e = $_.Exception
        $code = if ($e.Data -and $e.Data.Contains('VirutilCode')) { [int]$e.Data['VirutilCode'] } else { $null }
        return @{ Msg = $e.Message; Code = $code }
    }
}

function Quiet {
    param([scriptblock]$Body)
    $outOrig = [Console]::Out; $errOrig = [Console]::Error
    $buf = New-Object IO.StringWriter
    [Console]::SetOut($buf); [Console]::SetError($buf)
    try { & $Body } finally { [Console]::SetOut($outOrig); [Console]::SetError($errOrig) }
    return $buf.ToString()
}

# A P6 of W x H pixels, each RGB triple from PIXELS in row order.
function New-Ppm {
    param([string]$Path, [int]$W, [int]$H, [byte[]]$Pixels)
    $head = [Text.Encoding]::ASCII.GetBytes("P6`n# virutil test`n$W $H`n255`n")
    [IO.File]::WriteAllBytes($Path, [byte[]]($head + $Pixels))
}

function Get-Pixel {
    param([string]$Path, [int]$X, [int]$Y)
    Add-Type -AssemblyName System.Drawing
    $b = New-Object Drawing.Bitmap($Path)
    try { $c = $b.GetPixel($X, $Y); return '{0},{1},{2}' -f $c.R, $c.G, $c.B }
    finally { $b.Dispose() }
}

function Test-PngMagic {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    return ($b.Length -gt 8 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47)
}

function Get-ShotScratch {
    if (-not (Test-Path -LiteralPath $script:VirutilsTmpDir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $script:VirutilsTmpDir -Filter 'shot-*').Count
}

$vm = 'testvm'
$work = Join-Path $env:VIRUTILS_DIR 'work'
$qemuProc = $null

try {
    New-VirutilsDir $script:VirutilsImageDir | Out-Null
    New-VirutilsDir $work | Out-Null

    # --- grammar ---------------------------------------------------------------

    Check 'shot -h exits 0'              0 (Dies { Shot-Main @('-h') }).Code
    Check 'shot with no VM exits 1'      1 (Dies { Shot-Main @() }).Code
    Check 'a second VM exits 1'          1 (Dies { Shot-Main @('a', 'b') }).Code
    $r = Dies { Shot-Main @('a', '-o') }
    Check '-o with no value exits 1'     1 $r.Code
    CheckTrue '  and names the flag'     ($r.Msg -match '-o needs a value')
    $r = Dies { Shot-Main @('a', '--nope') }
    Check 'an unknown flag exits 1'      1 $r.Code
    CheckTrue '  and names it'           ($r.Msg -match '--nope')
    $r = Dies { Shot-Main @('nosuch') }
    CheckTrue 'an unknown domain is named' ($r.Msg -match 'no such domain: nosuch')

    # A launcher is all Test-Domain asks for; the monitor port in it is read
    # back by the real Invoke-DomainMonitor in the last section.
    $port = Get-FreeLoopbackPort
    Set-Content -LiteralPath (Get-DomainLauncher $vm) -Encoding ASCII -Value @(
        '@echo off'
        "start /b `"`" `"qemu-system-x86_64w.exe`" -name $vm ^"
        "    -monitor `"tcp:127.0.0.1:$port,server,nowait`""
    )

    # --- the monitor seam ----------------------------------------------------

    $realMonitor = ${function:Invoke-DomainMonitor}
    $realRunning = ${function:Test-DomainRunning}

    $script:Running = $false
    function Test-DomainRunning { param([string]$Vm) return $script:Running }
    $r = Dies { Shot-Main @($vm) }
    CheckTrue 'a shut-off domain is refused' ($r.Msg -match "$vm is not running")

    $script:Running = $true
    $script:Sent = @()
    $script:Reply = { param($cmd) "QEMU monitor`r`n(qemu) $cmd`r`n(qemu) " }
    function Invoke-DomainMonitor {
        param([string]$Vm, [string]$Command, [int]$TimeoutMs = 2000)
        $script:Sent += $Command
        return (& $script:Reply $Command)
    }

    [void](Dies { Invoke-ShotScreendump $vm 'C:\a b\"x".png' 'png' })
    Check 'the path is quoted and escaped' 'screendump "C:\\a b\\\"x\".png" -f png' $script:Sent[-1]

    $script:Reply = { param($cmd) "(qemu) $cmd`r`nError: Could not open 'x.png': Permission denied`r`n(qemu) " }
    $r = Dies { Quiet { Shot-Main @($vm, '-o', (Join-Path $work 'refused.png')) } }
    Check 'a refusal exits 1'              1 $r.Code
    CheckTrue '  and quotes the monitor'   ($r.Msg -match "Could not open 'x.png'")
    CheckTrue '  and writes nothing'       (-not (Test-Path (Join-Path $work 'refused.png')))

    $script:Reply = { param($cmd) $null }
    $r = Dies { Quiet { Shot-Main @($vm, '-o', (Join-Path $work 'gone.png')) } }
    CheckTrue 'no monitor is a failure'    ($r.Msg -match 'could not reach')

    # A reply with no complaint and no file: someone else held the monitor.
    $script:Reply = { param($cmd) "(qemu) " }
    $r = Dies { Quiet { Shot-Main @($vm, '-o', (Join-Path $work 'none.png')) } }
    CheckTrue 'no file is a failure'       ($r.Msg -match 'wrote no screendump')

    # A file that is not a PNG is not a shot, however the monitor answered.
    $script:Reply = {
        param($cmd)
        $file = ([regex]::Match($cmd, '^screendump "(.*)" -f png$').Groups[1].Value) -replace '\\\\', '\'
        [IO.File]::WriteAllText($file, 'not an image')
        return "(qemu) $cmd`r`n(qemu) "
    }
    $r = Dies { Quiet { Shot-Main @($vm, '-o', (Join-Path $work 'junk.png')) } }
    CheckTrue 'a file that is not a PNG fails' ($r.Msg -match 'wrote no PNG')
    CheckTrue '  and is not copied'         (-not (Test-Path (Join-Path $work 'junk.png')))

    $script:Reply = { param($cmd) "(qemu) " }
    $existing = Join-Path $work 'keep.png'
    [IO.File]::WriteAllText($existing, 'old')
    [void](Dies { Quiet { Shot-Main @($vm, '-o', $existing) } })
    Check 'a failed shot leaves -o alone'  'old' ([IO.File]::ReadAllText($existing))

    # A qemu with no libpng: refuse png by name, answer ppm with a 3x2 frame.
    # Each pixel distinct, so a channel swap or a mirrored row both show.
    $script:Reply = {
        param($cmd)
        if ($cmd -match '-f png$') { return "(qemu) $cmd`r`nError: Enable PNG support with libpng for screendump`r`n(qemu) " }
        $file = ([regex]::Match($cmd, '^screendump "(.*)" -f ppm$').Groups[1].Value) -replace '\\\\', '\'
        New-Ppm $file 3 2 ([byte[]]@(255,0,0, 0,255,0, 0,0,255,  10,20,30, 40,50,60, 70,80,90))
        return "(qemu) $cmd`r`n(qemu) "
    }
    $fallback = Join-Path $work 'fallback.png'
    $r = Dies { Quiet { Shot-Main @($vm, '-o', $fallback) } }
    Check 'a PPM-only qemu still gives a PNG' '' $r.Msg
    CheckTrue '  that is a PNG'            ((Test-Path $fallback) -and (Test-PngMagic $fallback))
    Check '  3 wide, 2 high'               '3x2' ('{0}x{1}' -f (Get-ShotPngSize $fallback).Width, (Get-ShotPngSize $fallback).Height)
    Check '  top-left is red'              '255,0,0'  (Get-Pixel $fallback 0 0)
    Check '  top-right is blue'            '0,0,255'  (Get-Pixel $fallback 2 0)
    Check '  bottom-middle is intact'      '40,50,60' (Get-Pixel $fallback 1 1)
    Check '  png then ppm were asked for'  'png ppm' (($script:Sent[-2..-1] | ForEach-Object { $_.Split(' ')[-1] }) -join ' ')
    Check 'no scratch file is left'        0 (Get-ShotScratch)

    Set-Item function:Invoke-DomainMonitor $realMonitor
    Set-Item function:Test-DomainRunning $realRunning

    # --- a real qemu ---------------------------------------------------------

    $qemuDir = @(
        (Join-Path $env:USERPROFILE 'scoop\apps\qemu\current')
        'C:\Program Files\qemu'
    ) | Where-Object { Test-Path (Join-Path $_ 'qemu-system-x86_64.exe') } | Select-Object -First 1
    if (-not $qemuDir) {
        [Console]::Out.WriteLine('skip     a real qemu: none installed')
    } else {
        # -S: no vcpu ever runs, so there is no firmware and no guest, only a
        # VGA surface for screendump to read.
        $qemuProc = Start-Process -FilePath (Join-Path $qemuDir 'qemu-system-x86_64.exe') -PassThru -WindowStyle Hidden `
            -ArgumentList '-nodefaults', '-machine', 'q35', '-vga', 'std', '-display', 'none', '-S',
                          '-monitor', "tcp:127.0.0.1:$port,server,nowait"
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-DomainRunning $vm) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        CheckTrue 'the throwaway qemu answers'  (Test-DomainRunning $vm)

        # Continue for the driver runs alone: Windows PowerShell turns a native
        # command's stderr into a terminating error under Stop, even redirected.
        $ErrorActionPreference = 'Continue'
        $exe = (Get-Process -Id $PID).Path
        $driver = Join-Path $root 'virutil.ps1'
        $sub = Join-Path $work 'a dir'
        New-VirutilsDir $sub | Out-Null
        $target = Join-Path $sub 'shot.png'
        [IO.File]::WriteAllText($target, 'old')

        $out = & $exe -NoProfile -NonInteractive -File $driver shot $vm -o $target 2>$null
        Check 'a real shot exits 0'             0 $LASTEXITCODE
        Check '  and prints the path'           $target ("$out".Trim())
        CheckTrue '  over the old file, as PNG' (Test-PngMagic $target)
        CheckTrue '  with a real frame'         ((Get-ShotPngSize $target).Width -gt 0)

        Push-Location $work
        try {
            $out = & $exe -NoProfile -NonInteractive -File $driver shot $vm 2>$null
            Check 'with no -o it exits 0'       0 $LASTEXITCODE
            $named = @(Get-ChildItem -LiteralPath $work -Filter "$vm-*.png")
            Check '  into the current directory' 1 $named.Count
            if ($named.Count -eq 1) {
                CheckTrue '  named VM-YYYYMMDD-HHMMSS.png' ($named[0].Name -match "^$vm-\d{8}-\d{6}\.png$")
                Check '  and prints that path'  $named[0].FullName ("$out".Trim())
            }
        } finally { Pop-Location }
        Check 'no scratch file is left'         0 (Get-ShotScratch)
        $ErrorActionPreference = 'Stop'
    }

    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("$($script:Pass) passed, $($script:Fail) failed")
} finally {
    if ($qemuProc -and -not $qemuProc.HasExited) { Stop-Process -Id $qemuProc.Id -Force }
    if ($qemuProc) { $qemuProc.WaitForExit(5000) | Out-Null }
    if (Test-Path -LiteralPath $env:VIRUTILS_DIR) {
        [IO.Directory]::Delete($env:VIRUTILS_DIR, $true)
    }
}

exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
