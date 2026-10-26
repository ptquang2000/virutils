<#
.SYNOPSIS
  Two virutil runs against one domain's guest agent. Check that they take
  turns rather than collide.

.DESCRIPTION
  The agent channel serves one host client at a time and qemu-ga answers in
  FIFO order on one stream, so two runs used to collide: one timed out, or read
  the other's reply (docs/qga-multi-client.md). Every call is now one round
  trip under a per-domain lock. What this checks:

  - the lock: who holds it is said while waiting, a wait that runs out fails
    naming the holder, a killed holder frees it, and it is re-entrant;
  - the round trip, against tests/win/fake-qga.ps1 -- a stand-in agent with the
    real channel's one-client, FIFO, late-reply-to-the-next-client behaviour:
    stale replies on connect, an agent that refuses a request carrying an "id",
    a reply that comes after its caller gave up, and an agent that is not up
    yet;
  - several `virutil exec` processes at once against the fake, every one
    getting its own output back.

  None of that needs a guest. The live half does: with -Vm or VIRUTILS_TEST_VM
  it runs parallel `exec` loops (and a push, if the guest has robocopy) against
  that domain and checks the same things there. It has no default VM and skips
  without one -- never name a domain someone else has leased.

      tests\win\agent.ps1
      $env:VIRUTILS_TEST_VM = 'scratch'; tests\win\agent.ps1
#>
param([string]$Vm)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $here)
$moduleDir = Join-Path $root 'modules\win'
$virutil = Join-Path $root 'virutil.ps1'
$fake = Join-Path $here 'fake-qga.ps1'
# Children run under the PowerShell this test runs under, so one run of the
# test covers one PowerShell: run it under both.
$shell = (Get-Process -Id $PID).Path

$liveVm = if ($Vm) { $Vm } elseif ($env:VIRUTILS_TEST_VM) { $env:VIRUTILS_TEST_VM } else { $null }
$liveDir = $env:VIRUTILS_DIR

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("virutil-test-" + [Guid]::NewGuid().ToString('N'))
$env:VIRUTILS_DIR = $scratch
$images = Join-Path $scratch 'images'
New-Item -ItemType Directory -Force -Path $images | Out-Null

. (Join-Path $moduleDir 'parser.ps1')
. (Join-Path $moduleDir 'paths.ps1')
. (Join-Path $moduleDir 'payload.ps1')
. (Join-Path $moduleDir 'guest.ps1')
. (Join-Path $moduleDir 'domain.ps1')

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
function Check {
    param([string]$Name, $Want, $Got)
    if ("$Want" -eq "$Got") { [Console]::Out.WriteLine("ok       $Name"); $script:Pass++ }
    else {
        [Console]::Out.WriteLine("FAIL     $Name")
        [Console]::Out.WriteLine("         wanted [$Want], got [$Got]")
        $script:Fail++
    }
}
function CheckLike {
    param([string]$Name, [string]$Pattern, [string]$Got)
    if ($Got -like $Pattern) { [Console]::Out.WriteLine("ok       $Name"); $script:Pass++ }
    else {
        [Console]::Out.WriteLine("FAIL     $Name")
        [Console]::Out.WriteLine("         wanted like [$Pattern], got [$Got]")
        $script:Fail++
    }
}
function Skipped { param([string]$Why) [Console]::Out.WriteLine("skip     $Why"); $script:Skip++ }

function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return $p
}

# A launcher in the scratch image directory carrying only what
# Get-GuestAgentPort reads back out of one.
function New-FakeDomain {
    param([string]$Name, [int]$Port)
    $text = "@echo off`r`nrem virutil domain: $Name -- tests/win/agent.ps1`r`n" +
            "    -chardev ""socket,id=qga0,host=127.0.0.1,port=$Port,server=on,wait=off"" ^`r`n"
    [IO.File]::WriteAllText((Join-Path $images "$Name.cmd"), $text)
}

$script:Fakes = @()
# Start-Fake NAME [FAKE ARGS] -- a fake agent behind a fake domain NAME; the
# path of its connection log.
function Start-Fake {
    param([string]$Name, [string[]]$FakeArgs = @())
    $port = Get-FreePort
    $log = Join-Path $scratch "$Name.fake.log"
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fake, '-Port', $port, '-Log', $log) + $FakeArgs
    $p = Start-Process -FilePath $shell -ArgumentList $argv -WindowStyle Hidden -PassThru
    $script:Fakes += $p
    for ($i = 0; $i -lt 300; $i++) {
        if ((Test-Path -LiteralPath $log) -and (Get-Content -LiteralPath $log) -contains 'ready') { break }
        Start-Sleep -Milliseconds 100
    }
    New-FakeDomain $Name $port
    return $log
}
function Get-Connects { param([string]$Log) return @(Get-Content -LiteralPath $Log | Where-Object { $_ -like 'connect *' }).Count }

# A child that takes NAME's lock, says so, and holds it until RELEASE exists
# (at once, given no RELEASE) -- with the command line a waiter is shown set to
# `sync NAME`. Released by the test rather than after a fixed time, because a
# PowerShell takes seconds to start on a loaded host and a timed hold races it.
$lockChild = Join-Path $scratch 'lock-child.ps1'
[IO.File]::WriteAllText($lockChild, @"
param([string]`$Name, [string]`$Release = '')
`$ErrorActionPreference = 'Stop'
. '$moduleDir\parser.ps1'; . '$moduleDir\paths.ps1'; . '$moduleDir\guest.ps1'
`$script:GuestAgentLockCommand = "sync `$Name"
try {
    Enter-GuestAgentLock `$Name
    [Console]::Out.WriteLine("got `$PID")
    while (`$Release -and -not (Test-Path -LiteralPath `$Release)) { Start-Sleep -Milliseconds 50 }
    Exit-GuestAgentLock `$Name
} catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }
"@)

# Start-LockChild NAME [-Hold] [-WaitS N] -- lock-child.ps1, started; -Hold
# makes it hold until Stop-LockChild. Wait-LockChild has its exit code and
# output.
function Start-LockChild {
    param([string]$Name, [switch]$Hold, [int]$WaitS = 120)
    $id = [Guid]::NewGuid().ToString('N')
    $out = Join-Path $scratch "$id.out"; $err = Join-Path $scratch "$id.err"
    $release = if ($Hold) { Join-Path $scratch "$id.release" } else { '' }
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $lockChild, $Name)
    if ($release) { $argv += $release }
    $env:VIRUTILS_AGENT_WAIT = "$WaitS"
    $p = Start-Process -FilePath $shell -WindowStyle Hidden -PassThru -ArgumentList $argv `
        -RedirectStandardOutput $out -RedirectStandardError $err
    # Windows PowerShell 5.1 reports no ExitCode for a Start-Process child
    # unless its handle was taken while it ran.
    $null = $p.Handle
    [Environment]::SetEnvironmentVariable('VIRUTILS_AGENT_WAIT', $null)
    return [pscustomobject]@{ Proc = $p; Out = $out; Err = $err; Release = $release }
}
function Stop-LockChild { param($C) [IO.File]::WriteAllText($C.Release, '') }
function Wait-LockChild {
    param($C)
    $C.Proc.WaitForExit()
    return [pscustomobject]@{
        Code = $C.Proc.ExitCode
        Out  = (Read-Shared $C.Out).Trim()
        Err  = (Read-Shared $C.Err).Trim()
    }
}
# A redirected stream file, read while its writer may still have it open.
function Read-Shared {
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}
# Wait-Output CHILD PATTERN [-Err] -- until the child has printed PATTERN.
function Wait-Output {
    param($C, [string]$Pattern, [switch]$Err)
    $file = if ($Err) { $C.Err } else { $C.Out }
    for ($i = 0; $i -lt 600; $i++) {
        if ((Read-Shared $file) -like $Pattern) { return }
        if ($C.Proc.HasExited) { return }
        Start-Sleep -Milliseconds 100
    }
}

# The n of a reply, or the message a call died with.
function Get-N { param($R) if ($R -is [string]) { return $R } else { return $R.n } }

# Try-Agent ... -- Invoke-GuestAgent, with a Die turned into its message.
function Try-Agent {
    param([string]$Name, [string]$Command, $Arguments = $null, [int]$TimeoutMs = 10000)
    try { return (Invoke-GuestAgent $Name $Command $Arguments -TimeoutMs $TimeoutMs) }
    catch { return "died: $($_.Exception.Message)" }
}

[Console]::Out.WriteLine("shell    $shell ($($PSVersionTable.PSVersion))")

try {
    # --- the lock ------------------------------------------------------------

    Enter-GuestAgentLock 'lk'
    CheckLike 'the holder writes who it is' "virutil pid $PID*since*" `
        (Read-GuestAgentLockHolder (Get-GuestAgentLockPath 'lk'))
    Enter-GuestAgentLock 'lk'
    Exit-GuestAgentLock 'lk'
    $r = Wait-LockChild (Start-LockChild 'lk' -WaitS 0)
    Check 're-entrant: one exit of two leaves it held' 1 $r.Code
    Exit-GuestAgentLock 'lk'
    $r = Wait-LockChild (Start-LockChild 'lk' -WaitS 0)
    Check 'and the second exit lets it go' 0 $r.Code

    # A waiter that waits more than a moment is told who holds it, once, and
    # gets it when the holder is done.
    $a = Start-LockChild 'lw' -Hold
    Wait-Output $a 'got*'
    $bc = Start-LockChild 'lw' -WaitS 60
    Wait-Output $bc 'waiting for*' -Err
    Stop-LockChild $a
    $b = Wait-LockChild $bc
    $null = Wait-LockChild $a
    Check 'a waiter gets the lock once the holder lets go' 0 $b.Code
    CheckLike 'and was told who held it' "waiting for lw's guest agent: held by virutil pid $($a.Proc.Id), ?sync lw?, since *" $b.Err
    Check 'once' 1 @($b.Err -split "`n" | Where-Object { $_ -like 'waiting for*' }).Count

    # A wait that runs out fails, naming the holder.
    $a = Start-LockChild 'lt' -Hold
    Wait-Output $a 'got*'
    $b = Wait-LockChild (Start-LockChild 'lt' -WaitS 1)
    Check 'a wait that runs out fails' 1 $b.Code
    CheckLike 'naming the holder and the knob' "*gave up after 1s waiting for lt's guest agent*held by virutil pid $($a.Proc.Id)*VIRUTILS_AGENT_WAIT*" ($b.Err -replace "`r?`n", ' ')
    Stop-LockChild $a; $null = Wait-LockChild $a

    # A holder that dies without letting go leaves no lock behind.
    $a = Start-LockChild 'lk2' -Hold
    Wait-Output $a 'got*'
    $a.Proc.Kill(); $null = $a.Proc.WaitForExit(5000)
    $b = Wait-LockChild (Start-LockChild 'lk2' -WaitS 0)
    Check 'a killed holder frees the lock at once' 0 $b.Code

    $env:VIRUTILS_AGENT_WAIT = 'soon'
    CheckLike 'a VIRUTILS_AGENT_WAIT that is not a number is refused' '*whole number of seconds*' `
        $(try { Enter-GuestAgentLock 'bad'; 'took it' } catch { $_.Exception.Message })
    [Environment]::SetEnvironmentVariable('VIRUTILS_AGENT_WAIT', $null)

    # --- the round trip ------------------------------------------------------

    $null = Start-Fake 'fa'
    Check 'a round trip returns its own reply' 7 (Get-N (Try-Agent 'fa' 'guest-echo' @{ n = 7 }))
    Check 'and leaves no lock held' 0 $script:GuestAgentLocks.Count
    CheckLike 'an agent error is reported as one' "died: fa's guest agent refused guest-nope*" (Try-Agent 'fa' 'guest-nope')

    # The late reply: its caller gives up, the reply lands on the next caller's
    # connection, and the sync there throws it away.
    CheckLike 'a reply that does not come in time fails the call' "died: fa's guest agent did not answer guest-slow within 300ms" `
        (Try-Agent 'fa' 'guest-slow' @{ ms = 1200; n = 1 } -TimeoutMs 300)
    Check 'and the next call reads its own reply, not that one' 2 (Get-N (Try-Agent 'fa' 'guest-echo' @{ n = 2 }))

    $null = Start-Fake 'fs' @('-StaleOnConnect', '3')
    Check 'replies left over from an earlier client are drained' 3 (Get-N (Try-Agent 'fs' 'guest-echo' @{ n = 3 }))

    # virtio-win's qemu-ga 7.6.2, the one a Windows XP guest runs, refuses a
    # request carrying an "id"; so none is sent.
    $null = Start-Fake 'fn' @('-RejectId')
    Check 'an agent that refuses an id still works' 4 (Get-N (Try-Agent 'fn' 'guest-echo' @{ n = 4 }))

    # Waiting for an agent that is not up yet: one connection for the whole
    # wait, because with nobody reading the port qemu cannot see a dropped one.
    $log = Start-Fake 'fb' @('-BootDelayMs', '3000')
    Check 'Test-GuestAgent waits for an agent to come up' $true (Test-GuestAgent 'fb' 15)
    Check 'over one connection' 1 (Get-Connects $log)

    New-FakeDomain 'fz' (Get-FreePort)
    Check 'Test-GuestAgent with nothing listening is false' $false (Test-GuestAgent 'fz' 1)
    CheckLike 'and a call says the agent is not answering' "died: fz's QEMU guest agent is not answering*" (Try-Agent 'fz' 'guest-ping')

    # --- several runs at once ------------------------------------------------
    #
    # Each loop is its own process running `virutil exec cmd` in turn, and the
    # fake's exec output is the argv it was given, so a crossed reply shows up
    # as another loop's text.
    $log = Start-Fake 'fc'
    $loop = Join-Path $scratch 'exec-loop.ps1'
    [IO.File]::WriteAllText($loop, @'
param([string]$Shell, [string]$Virutil, [string]$Name, [string]$Tag, [int]$Count)
for ($i = 1; $i -le $Count; $i++) {
    $want = "/c echo $Tag-$i"
    $got = & $Shell -NoProfile -ExecutionPolicy Bypass -File $Virutil exec cmd $Name "echo $Tag-$i" 2>$null
    $code = $LASTEXITCODE
    $text = (@($got) | ForEach-Object { "$_" }) -join ' | '
    if ($code -eq 0 -and $text -eq $want) { "ok $Tag-$i" } else { "BAD $Tag-$i exit=$code got=[$text]" }
}
'@)
    $procs = foreach ($t in 'A', 'B', 'C') {
        $o = Join-Path $scratch "loop-$t.out"
        $p = Start-Process -FilePath $shell -WindowStyle Hidden -PassThru -RedirectStandardOutput $o `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $loop, $shell, $virutil, 'fc', $t, 8)
        [pscustomobject]@{ Proc = $p; Out = $o; Tag = $t }
    }
    foreach ($p in $procs) { $p.Proc.WaitForExit() }
    $lines = @($procs | ForEach-Object { Get-Content -LiteralPath $_.Out })
    $bad = @($lines | Where-Object { $_ -notlike 'ok *' })
    Check 'three concurrent exec loops: every call answered' 24 @($lines | Where-Object { $_ -like 'ok *' }).Count
    Check 'with its own output, and none timed out' '' ($bad -join '; ')

    # --- the live half -------------------------------------------------------

    if (-not $liveVm) {
        Skipped 'no live guest: name one with -Vm VM or VIRUTILS_TEST_VM=VM -- never a domain someone else has leased'
    } else {
        $env:VIRUTILS_DIR = $liveDir
        if (-not $liveDir) { Remove-Item Env:\VIRUTILS_DIR }
        [Console]::Out.WriteLine("guest    $liveVm")
        & $shell -NoProfile -ExecutionPolicy Bypass -File $virutil exec ping $liveVm 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Skipped "$liveVm's agent does not answer"
        } else {
            $liveLoop = Join-Path $scratch 'live-loop.ps1'
            [IO.File]::WriteAllText($liveLoop, @'
param([string]$Shell, [string]$Virutil, [string]$Name, [string]$Tag, [int]$Count)
for ($i = 1; $i -le $Count; $i++) {
    $got = & $Shell -NoProfile -ExecutionPolicy Bypass -File $Virutil exec cmd $Name "echo $Tag-$i" 2>$null
    $code = $LASTEXITCODE
    $text = ((@($got) | ForEach-Object { "$_" }) -join ' | ').Trim()
    if ($code -eq 0 -and $text -eq "$Tag-$i") { "ok $Tag-$i" } else { "BAD $Tag-$i exit=$code got=[$text]" }
}
'@)
            $have = & $shell -NoProfile -ExecutionPolicy Bypass -File $virutil exec cmd $liveVm 'robocopy /? >nul 2>&1 && echo yes' 2>$null
            $doPush = ("$have".Trim() -eq 'yes')
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $procs = foreach ($t in 'L1', 'L2', 'L3') {
                $o = Join-Path $scratch "live-$t.out"
                $p = Start-Process -FilePath $shell -WindowStyle Hidden -PassThru -RedirectStandardOutput $o `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $liveLoop, $shell, $virutil, $liveVm, $t, 10)
                [pscustomobject]@{ Proc = $p; Out = $o }
            }
            $push = $null
            if ($doPush) {
                $src = Join-Path $scratch 'push-src'
                New-Item -ItemType Directory -Force -Path $src | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $src 'blob.bin'), (New-Object byte[] (4MB)))
                $po = Join-Path $scratch 'push.out'; $pe = Join-Path $scratch 'push.err'
                $push = Start-Process -FilePath $shell -WindowStyle Hidden -PassThru -RedirectStandardOutput $po -RedirectStandardError $pe `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $virutil, 'push', $liveVm, $src, 'C:\virutil-agent-test')
            }
            foreach ($p in $procs) { $p.Proc.WaitForExit() }
            $lines = @($procs | ForEach-Object { Get-Content -LiteralPath $_.Out })
            $bad = @($lines | Where-Object { $_ -notlike 'ok *' })
            Check "live: three concurrent exec loops, every call answered ($([int]$sw.Elapsed.TotalSeconds)s)" 30 @($lines | Where-Object { $_ -like 'ok *' }).Count
            Check 'live: each with its own output, none timed out' '' ($bad -join '; ')
            # The UAT failure itself: one run polling a long guest command,
            # another run's call in the middle of it. This used to wait 2s
            # behind the first run's held channel and report the agent dead.
            $ho = Join-Path $scratch 'hold.out'
            $holder = Start-Process -FilePath $shell -WindowStyle Hidden -PassThru -RedirectStandardOutput $ho `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $virutil, 'exec', 'cmd', $liveVm, 'ping -n 15 127.0.0.1 >nul & echo held')
            $null = $holder.Handle
            Start-Sleep -Seconds 6
            $mid = & $shell -NoProfile -ExecutionPolicy Bypass -File $virutil exec cmd $liveVm 'echo mid' 2>$null
            Check 'live: a call during another run''s long command is answered' 'mid' ("$mid".Trim())
            $holder.WaitForExit()
            Check '  and that run finishes too' 'held' ((Read-Shared $ho).Trim())
            if ($null -ne $push) {
                $push.WaitForExit()
                Check 'live: a push alongside them succeeds' 0 $push.ExitCode
                & $shell -NoProfile -ExecutionPolicy Bypass -File $virutil exec cmd $liveVm 'rmdir /s /q C:\virutil-agent-test' 2>&1 | Out-Null
            } else {
                Skipped "live push: $liveVm has no robocopy"
            }
        }
    }

    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine("$($script:Pass) passed, $($script:Fail) failed, $($script:Skip) skipped")
} finally {
    Close-GuestAgentChannels
    foreach ($p in $script:Fakes) { try { $p.Kill() } catch { } }
    foreach ($p in $script:Fakes) { try { $null = $p.WaitForExit(5000) } catch { } }
    # [IO.Directory]::Delete, not Remove-Item: see Remove-VirutilsFile.
    if (Test-Path -LiteralPath $scratch) {
        for ($i = 0; $i -lt 20; $i++) {
            try { [IO.Directory]::Delete($scratch, $true); break } catch { Start-Sleep -Milliseconds 250 }
        }
    }
}

exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
