<#
.SYNOPSIS
  input on a Windows host: the session seams substituted, then a real qemu.

.DESCRIPTION
  The seams are the monitor line (Invoke-InputHmp), the barrier message
  (Send-InputBarrier) and the two connections behind them, so what the guest
  would have been sent is captured and the monitor's replies are chosen. What
  is asserted:

    * the grammar and its exit codes, which are contract;
    * a bad combo, an untypeable character and a bad flag are refused before
      the domain is even looked up, so nothing is sent;
    * a pixel maps to the centre of its slice of the tablet's 0..32767;
    * each verb's events, in order, and the US layout of type;
    * a paused domain, one with no absolute pointer and a position off the
      screen are each refused, and the session is closed either way;
    * against a real qemu -- running, no disk, no guest, qemu's own
      input_event trace written to a file -- the driver's events arrive as the
      absolute positions, buttons, wheel notches and key codes they were sent
      as, the barrier object is gone afterwards, and the two refusals hold.

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
. (Join-Path $moduleDir 'input.ps1')

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

# The first 24 bytes of a PNG of W x H: all Get-ShotPngSize reads.
function New-PngHead {
    param([string]$Path, [int]$W, [int]$H)
    $be = { param($v) [byte[]]@((($v -shr 24) -band 0xff), (($v -shr 16) -band 0xff), (($v -shr 8) -band 0xff), ($v -band 0xff)) }
    $b = [byte[]](@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52) + (& $be $W) + (& $be $H))
    [IO.File]::WriteAllBytes($Path, $b)
}

$vm = 'testvm'
$qemuProc = $null

try {
    New-VirutilsDir $script:VirutilsImageDir | Out-Null

    # --- grammar ---------------------------------------------------------------

    Check 'input -h exits 0'               0 (Dies { Input-Main @('-h') }).Code
    Check 'input click -h exits 0'         0 (Dies { Input-Main @('click', '-h') }).Code
    Check 'input with no verb exits 1'     1 (Dies { Input-Main @() }).Code
    $r = Dies { Input-Main @('poke', $vm) }
    Check 'an unknown verb exits 1'        1 $r.Code
    CheckTrue '  and names it'             ($r.Msg -match 'unknown command: poke')
    Check 'click with one coordinate exits 1' 1 (Dies { Input-Main @('click', $vm, '3') }).Code
    Check 'drag with two exits 1'          1 (Dies { Input-Main @('drag', $vm, '1', '2') }).Code
    Check 'key with no combo exits 1'      1 (Dies { Input-Main @('key', $vm) }).Code
    $r = Dies { Input-Main @('click', $vm, 'x', '3') }
    CheckTrue 'a coordinate must be a number' ($r.Msg -match "expected a number, got 'x'")
    $r = Dies { Input-Main @('click', $vm, '1', '2', '-b', 'side') }
    CheckTrue '-b takes left, right or middle' ($r.Msg -match 'left, right or middle')
    $r = Dies { Input-Main @('move', $vm, '1', '2', '--double') }
    CheckTrue '--double is click''s alone' ($r.Msg -match 'unknown flag for move: --double')
    $r = Dies { Input-Main @('key', 'nosuch', 'ctrl+zz') }
    CheckTrue 'an unknown key is refused before the domain is looked up' ($r.Msg -match "unknown key 'zz' in 'ctrl\+zz'")
    $r = Dies { Input-Main @('type', 'nosuch', "caf$([char]0xE9)", "$([char]0x4E2D)") }
    CheckTrue 'an untypeable character is refused by code point' ($r.Msg -match "'.' \(U\+00E9\), '.' \(U\+4E2D\)")
    CheckTrue '  and nothing is sent'      ($r.Msg -match 'Nothing was sent')
    $r = Dies { Input-Main @('click', 'nosuch', '1', '2') }
    CheckTrue 'an unknown domain is named' ($r.Msg -match 'no such domain: nosuch')

    # --- what is sent ----------------------------------------------------------

    Check 'pixel 0 of 1280 is the centre of its slice'  12    (Get-InputAbs 0 1280)
    Check 'pixel 640 of 1280'                          16396 (Get-InputAbs 640 1280)
    Check 'the last pixel stays inside the range'      32755 (Get-InputAbs 1279 1280)
    Check 'one pixel across is the middle'             16384 (Get-InputAbs 0 1)
    Check 'ctrl+alt+delete'      'ctrl alt delete'  ((Read-InputCombo 'ctrl+alt+delete') -join ' ')
    Check 'win and enter by alias' 'meta_l'         ((Read-InputCombo 'win') -join ' ')
    Check 'case is ignored'      'alt f4'           ((Read-InputCombo 'Alt+F4') -join ' ')
    Check 'ctrl++ is ctrl and the plus key' 'ctrl shift equal' ((Read-InputCombo 'ctrl++') -join ' ')
    Check 'punctuation by character' 'ctrl slash'   ((Read-InputCombo 'ctrl+/') -join ' ')
    Check 'a qcode by its own name' 'kp_enter'      ((Read-InputCombo 'kp_enter') -join ' ')
    $combos = ConvertTo-InputCombos "Hi! `r`n`""
    Check 'type: US layout, shift where it is held' 'shift-h i shift-1 spc ret shift-apostrophe' `
        (($combos | ForEach-Object { $_ -join '-' }) -join ' ')

    # --- the session seams -----------------------------------------------------

    Set-Content -LiteralPath (Get-DomainLauncher $vm) -Encoding ASCII -Value @(
        '@echo off'
        "start /b `"`" `"qemu-system-x86_64w.exe`" -name $vm ^"
        "    -monitor `"tcp:127.0.0.1:1,server,nowait`""
    )
    $realFns = @{}
    foreach ($n in 'Test-DomainRunning', 'Open-InputSession', 'Invoke-InputHmp', 'Open-InputPointer',
                   'Send-InputBarrier', 'Close-InputSession', 'Wait-Input') {
        $realFns[$n] = (Get-Item "function:$n").ScriptBlock
    }

    $script:Log = @()
    $script:Status = 'VM status: running'
    $script:Mice = "  Mouse #3: QEMU HID Tablet (absolute)`r`n* Mouse #2: QEMU PS/2 Mouse"
    function Test-DomainRunning { param([string]$Vm) return $true }
    function Open-InputSession { param([string]$Vm) $script:Log += 'open'; return @{ Vm = $Vm } }
    function Close-InputSession { param($S) $script:Log += 'close' }
    function Open-InputPointer { param($S) $script:Log += 'pointer' }
    function Wait-Input { param([int]$Ms) }
    function Send-InputBarrier {
        param($S, [string]$Code, [byte[]]$Payload = @())
        $script:Log += ("$Code " + (($Payload | ForEach-Object { '{0:x2}' -f $_ }) -join '')).Trim()
    }
    function Invoke-InputHmp {
        param($S, [string]$Command)
        $script:Log += $Command
        switch -regex ($Command) {
            '^info status' { return $script:Status }
            '^info mice'   { return $script:Mice }
            '^screendump "(.*)" -f png$' {
                New-PngHead ($Matches[1] -replace '\\\\', '\') 1280 800
                return ''
            }
            default { return '' }
        }
    }
    # The events alone: what reached the barrier and the keyboard.
    function Events { @($script:Log | Where-Object { $_ -match '^(DM|sendkey)' }) -join ' | ' }

    $script:Log = @()
    $out = Quiet { Input-Main @('click', $vm, '640', '400') }
    Check 'click: move, press, release'    'DMMV 400c4014 | DMDN 01 | DMUP 01' (Events)
    Check '  after status, mice and a screendump' 'open info status info mice screendump' `
        ((@($script:Log | Select-Object -First 4) -replace ' ".*', '') -join ' ')
    Check '  and the session closes'       'close' $script:Log[-1]
    CheckTrue '  saying what it did'       ($out -match "${vm}: click 640,400 on 1280x800")

    $script:Log = @()
    [void](Quiet { Input-Main @('click', $vm, '0', '799', '--double', '-b', 'right') })
    Check 'double right click'             'DMMV 000c7feb | DMDN 03 | DMUP 03 | DMDN 03 | DMUP 03' (Events)

    $script:Log = @()
    [void](Quiet { Input-Main @('move', $vm, '1279', '0') })
    Check 'move'                           'DMMV 7ff30014' (Events)

    $script:Log = @()
    [void](Quiet { Input-Main @('wheel', $vm, '10', '10', '-2') })
    Check 'wheel -2: two notches down'     'DMMV 010c01ae | DMWM 0000ff88 | DMWM 0000ff88' (Events)
    $script:Log = @()
    [void](Quiet { Input-Main @('wheel', $vm, '10', '10', '1') })
    Check 'wheel 1: one notch up'          'DMMV 010c01ae | DMWM 00000078' (Events)

    $script:Log = @()
    [void](Quiet { Input-Main @('drag', $vm, '0', '0', '100', '0', '-b', 'middle') })
    $ev = @($script:Log | Where-Object { $_ -match '^DM' })
    Check 'drag: start, press, ten steps, release' 13 $ev.Count
    Check '  pressed at the start'         'DMMV 000c0014 | DMDN 02' (($ev[0..1]) -join ' | ')
    Check '  released at the end'          ('DMMV {0:x4}0014 | DMUP 02' -f (Get-InputAbs 100 1280)) (($ev[-2..-1]) -join ' | ')

    $script:Log = @()
    $out = Quiet { Input-Main @('key', $vm, 'ctrl+a', 'enter') }
    Check 'key: each combo, default hold'  'sendkey ctrl-a 100 | sendkey ret 100' (Events)
    CheckTrue '  with no screendump and no pointer' (-not ($script:Log -match '^(screendump|pointer|info mice)'))

    $script:Log = @()
    [void](Quiet { Input-Main @('type', $vm, 'a', '-B') })
    Check 'type: words joined by a space, a dash typed' 'sendkey a 30 | sendkey spc 30 | sendkey minus 30 | sendkey shift-b 30' (Events)

    $script:Status = 'VM status: paused'
    $script:Log = @()
    $r = Dies { Quiet { Input-Main @('key', $vm, 'enter') } }
    CheckTrue 'a paused domain is refused'  ($r.Msg -match "$vm is not running \(paused\)")
    Check '  and nothing is sent'           '' (Events)
    Check '  and the session closes'        'close' $script:Log[-1]
    $script:Status = 'VM status: running'

    $script:Mice = '* Mouse #2: QEMU PS/2 Mouse'
    $script:Log = @()
    $r = Dies { Quiet { Input-Main @('click', $vm, '1', '1') } }
    CheckTrue 'no absolute pointer is refused' ($r.Msg -match 'no absolute pointer')
    CheckTrue '  naming what qemu has'      ($r.Msg -match 'qemu lists: \* Mouse #2: QEMU PS/2 Mouse')
    CheckTrue '  and saying what to add'    ($r.Msg -match '-device usb-tablet')
    Check '  and nothing is sent'           '' (Events)
    $script:Log = @()
    [void](Quiet { Input-Main @('key', $vm, 'enter') })
    Check 'key still works without one'     'sendkey ret 100' (Events)
    $script:Mice = '  Mouse #3: QEMU HID Tablet (absolute)'

    $script:Log = @()
    $r = Dies { Quiet { Input-Main @('drag', $vm, '1', '1', '1280', '5') } }
    CheckTrue 'a position off the screen is refused' ($r.Msg -match "1280,5 is outside $vm's 1280x800 screen")
    Check '  before the pointer is opened'  0 @($script:Log | Where-Object { $_ -eq 'pointer' }).Count
    Check '  and the session closes'        'close' $script:Log[-1]

    foreach ($n in $realFns.Keys) { Set-Item "function:$n" $realFns[$n] }

    # --- a real qemu -----------------------------------------------------------

    $qemuDir = @(
        (Join-Path $env:USERPROFILE 'scoop\apps\qemu\current')
        'C:\Program Files\qemu'
    ) | Where-Object { Test-Path (Join-Path $_ 'qemu-system-x86_64.exe') } | Select-Object -First 1
    if (-not $qemuDir) {
        [Console]::Out.WriteLine('skip     a real qemu: none installed')
    } else {
        $port = Get-FreeLoopbackPort
        Set-Content -LiteralPath (Get-DomainLauncher $vm) -Encoding ASCII -Value @(
            '@echo off'
            "start /b `"`" `"qemu-system-x86_64w.exe`" -name $vm ^"
            "    -monitor `"tcp:127.0.0.1:$port,server,nowait`""
        )
        $trace = Join-Path $env:VIRUTILS_DIR 'trace.log'
        # Not paused: qemu drops input sent to a stopped guest. No disk, so the
        # firmware finds nothing to boot and sits there; the trace is written
        # as qemu takes each event, guest or no guest.
        $qemuProc = Start-Process -FilePath (Join-Path $qemuDir 'qemu-system-x86_64.exe') -PassThru -WindowStyle Hidden `
            -ArgumentList '-nodefaults', '-machine', 'q35', '-vga', 'std', '-display', 'none',
                          '-device', 'qemu-xhci,id=xhci', '-device', 'usb-tablet,id=tab0',
                          '-monitor', "tcp:127.0.0.1:$port,server,nowait",
                          '-d', 'trace:input_event*', '-D', $trace
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-DomainRunning $vm) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        CheckTrue 'the throwaway qemu answers'  (Test-DomainRunning $vm)

        $ErrorActionPreference = 'Continue'
        $exe = (Get-Process -Id $PID).Path
        $driver = Join-Path $root 'virutil.ps1'
        $run = { & $exe -NoProfile -NonInteractive -File $driver input @args 2>&1 | ForEach-Object { "$_" } }
        $traced = { @(Get-Content -LiteralPath $trace | Where-Object { $_ -notmatch 'input_event_sync' } |
                      ForEach-Object { $_ -replace '^.*input_event_', '' -replace 'con -1, ', '' }) }

        $out = & $run click $vm 10 20
        Check 'a real click exits 0'            0 $LASTEXITCODE
        $m = [regex]::Match("$out", '(\d+)x(\d+)')
        CheckTrue '  and says the screen size'  $m.Success
        if ($m.Success) {
            $w = [int]$m.Groups[1].Value; $h = [int]$m.Groups[2].Value
            Check '  qemu took the absolute position and the button' (@(
                    ('abs axis x, value 0x{0:x}' -f (Get-InputAbs 10 $w))
                    ('abs axis y, value 0x{0:x}' -f (Get-InputAbs 20 $h))
                    'btn button left, down 1'
                    'btn button left, down 0') -join ' | ') ((& $traced) -join ' | ')
        }
        Clear-Content -LiteralPath $trace

        $null = & $run wheel $vm 1 1 -2
        Check 'a real wheel -2 is two notches down' 2 @(& $traced | Where-Object { $_ -eq 'btn button wheel-down, down 1' }).Count
        Clear-Content -LiteralPath $trace

        $null = & $run key $vm ctrl+a
        $null = & $run type $vm 'aB'
        Start-Sleep -Milliseconds 300
        Check 'real keys arrive as qcodes, in order' (@(
                'key_qcode key qcode ctrl, down 1', 'key_qcode key qcode a, down 1'
                'key_qcode key qcode a, down 0',    'key_qcode key qcode ctrl, down 0'
                'key_qcode key qcode a, down 1',    'key_qcode key qcode a, down 0'
                'key_qcode key qcode shift, down 1', 'key_qcode key qcode b, down 1'
                'key_qcode key qcode b, down 0',    'key_qcode key qcode shift, down 0') -join ' | ') ((& $traced) -join ' | ')

        $objects = Invoke-DomainMonitor $vm 'qom-list /objects'
        CheckTrue 'no barrier object is left behind' ($objects -and $objects -notmatch 'virutil-input')

        [void](Invoke-DomainMonitor $vm 'stop')
        $out = & $run key $vm enter
        Check 'a paused qemu is refused'        1 $LASTEXITCODE
        CheckTrue '  as paused'                 ("$out" -match 'not running \(paused\)')
        [void](Invoke-DomainMonitor $vm 'cont')

        [void](Invoke-DomainMonitor $vm 'device_del tab0')
        Start-Sleep -Milliseconds 500
        $out = & $run click $vm 1 1
        Check 'with the tablet gone, a click exits 1' 1 $LASTEXITCODE
        CheckTrue '  saying there is no absolute pointer' ("$out" -match 'no absolute pointer')
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
