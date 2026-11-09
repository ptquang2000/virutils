<#
.SYNOPSIS
  The launcher is the domain: check that reading one back works.

.DESCRIPTION
  modules/win/domain.ps1 keeps no state beside the per-VM .cmd launcher -- the
  monitor port and every port forward are read back out of it, and `port` edits
  it in place. That makes the launcher a parsing contract with itself, and this
  is what holds it: a launcher is written, read back, edited, and read again.

  No qemu and no guest. What is under test is the file, which is where every
  fact about a domain lives on this host.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'modules\win'

# A scratch root, so the test never looks at a real domain and never leaves one.
$env:VIRUTILS_DIR = Join-Path ([IO.Path]::GetTempPath()) ("virutil-test-" + [Guid]::NewGuid().ToString('N'))

. (Join-Path $moduleDir 'parser.ps1')
. (Join-Path $moduleDir 'paths.ps1')
. (Join-Path $moduleDir 'payload.ps1')
. (Join-Path $moduleDir 'guest.ps1')
. (Join-Path $moduleDir 'domain.ps1')

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, $Want, $Got)
    if ("$Want" -eq "$Got") {
        [Console]::Out.WriteLine("ok       $Name")
        $script:Pass++
    } else {
        [Console]::Out.WriteLine("FAIL     $Name")
        [Console]::Out.WriteLine("         wanted [$Want], got [$Got]")
        $script:Fail++
    }
}

try {
    New-VirutilsDir $script:VirutilsImageDir | Out-Null

    $vm = 'testvm'
    $qemuArgs = Get-DomainQemuArgs -Vm $vm `
        -Qemu @{ Code = 'C:\q\share\edk2-x86_64-code.fd' } `
        -Disk (Get-DomainDisk $vm) -Nvram (Get-DomainNvram $vm) `
        -Iso 'C:\iso\win.iso' -Virtio '' -Memory 8192 -Vcpus 4 `
        -Ports @('13389:3389', '2222:22') -MonitorPort 44444 -AgentPort 44445

    Write-DomainLauncher (Get-DomainLauncher $vm) 'C:\q\qemu-system-x86_64.exe' $qemuArgs $vm

    Check 'the launcher is the domain'   $true              (Test-Domain $vm)
    Check 'the monitor port reads back'  44444              (Get-DomainMonitorPort $vm)
    Check 'the agent port reads back'    44445              (Get-GuestAgentPort $vm)

    # The channel that makes everything else possible has to actually be on the
    # command line; without it there is no qemu-ga, and exec, guest_os, push and
    # pull all stop before they start.
    $line = ($qemuArgs -join ' ')
    Check 'the agent chardev is present' $true ($line -match 'virtserialport,chardev=qga0,name=org\.qemu\.guest_agent\.0')
    # wait=off or qemu blocks on the command line waiting for a client, which
    # is the whole reason the pipe chardev was replaced.
    Check 'the agent chardev is wait=off' $true ($line -match 'socket,id=qga0,.*server=on,wait=off')
    Check 'virtio-serial is present'     $true ($line -match '-device virtio-serial')
    # Without it the RTC is UTC, Windows reads it as local time, and the guest
    # runs off by its zone's UTC offset.
    Check 'a local-time RTC'             $true ($line -match '-rtc base=localtime')

    $fwd = Get-DomainForwards $vm
    Check 'both forwards read back'      2     $fwd.Count
    Check 'first forward, host port'     13389 $fwd[0].Host
    Check 'first forward, guest port'    3389  $fwd[0].Guest
    Check 'second forward, host port'    2222  $fwd[1].Host

    # A domain whose monitor nothing answers on is shut off, whatever else is
    # true of it.
    Check 'a launcher alone is shut off' $false (Test-DomainRunning $vm)

    Add-LauncherForward $vm 18080 80
    $fwd = Get-DomainForwards $vm
    Check 'a forward can be added'       3 $fwd.Count
    Check 'the added forward is found'   1 (@($fwd | Where-Object { $_.Host -eq 18080 -and $_.Guest -eq 80 }).Count)

    Remove-LauncherForward $vm 18080
    $fwd = Get-DomainForwards $vm
    Check 'a forward can be removed'     2 $fwd.Count
    Check 'the right one went'           0 (@($fwd | Where-Object { $_.Host -eq 18080 }).Count)
    Check 'the others are untouched'     2 (@($fwd | Where-Object { $_.Host -in @(13389, 2222) }).Count)

    # The monitor port has to survive an edit: `port` rewrites the file, and a
    # rewrite that lost it would leave a domain nothing could shut down.
    Check 'the monitor survives an edit' 44444 (Get-DomainMonitorPort $vm)

    # --- setting a value it already has -------------------------------------
    #
    # `domain start VM -c 1` is the documented way through a Windows install --
    # once per reboot the firmware wedges at -- so every start after the first
    # asks for the count the launcher already carries. Rewriting to the same
    # bytes is success, not a launcher that failed to match: the version that
    # compared the result instead of the pattern died with "could not find -smp"
    # and left the domain unstarted, which is the whole install stuck.
    $lp = Get-DomainLauncher $vm
    Set-LauncherVcpus $vm 1
    $once = Get-Content -LiteralPath $lp -Raw
    Check 'vcpus are written'            $true ($once -match '-smp "1,sockets=1,cores=1,threads=1"')
    Check 'and num-queues follows'       $true ($once -match 'num-queues=1,')
    Set-LauncherVcpus $vm 1
    Check 'and setting 1 again is a no-op' $once (Get-Content -LiteralPath $lp -Raw)

    Set-LauncherMemory $vm 8192
    Check 'memory is written'            $true ((Get-Content -LiteralPath $lp -Raw) -match '(?m)^\s*-m 8192\b')
    Set-LauncherMemory $vm 8192
    Check 'and setting it again is a no-op' $true ((Get-Content -LiteralPath $lp -Raw) -match '(?m)^\s*-m 8192\b')

    # The other half of the contract still holds: a launcher that does not
    # carry the shape these expect is an edited launcher, and is refused rather
    # than rewritten blind.
    $edited = Join-Path $script:VirutilsImageDir 'edited.cmd'
    Set-Content -LiteralPath $edited -Value "rem no smp here`r`n" -Encoding ASCII
    $refused = $false
    try { Set-LauncherVcpus 'edited' 2 } catch { $refused = $true }
    Check 'a launcher with no -smp is refused' $true $refused

    # --- create takes a vcpu count, and defaults to one an install can use ---
    #
    # This used to assert the opposite -- that create refused `-c` by name --
    # and the refusal was wrong: Windows 11 Setup will not install on one vcpu,
    # so a domain created at one could never be installed. `-c` is a plain flag
    # again and the default is 2. Both spellings still have to reach the ISO
    # check rather than dying as "unknown flag", which is what proves they were
    # parsed rather than ignored.
    $said = ''
    try { New-Domain @('win11', 'C:\nonexistent.iso', '-c', '4') } catch { $said = ($_.Exception.Message) }
    Check 'create accepts -c'           $true  ($said -match 'install ISO not found')
    Check 'and not as an unknown flag'  $false ($said -match 'unknown flag')
    Check 'and does not refuse it'      $false ($said -match 'not accepted here')

    $said = ''
    try { New-Domain @('win11', 'C:\nonexistent.iso', '--vcpus', '4') } catch { $said = ($_.Exception.Message) }
    Check 'the long spelling too'       $true  ($said -match 'install ISO not found')
    Check 'and is not refused either'   $false ($said -match 'not accepted here')

    # --- the boot order a half-finished install depends on -------------------
    #
    # OVMF rewrites BootOrder from qemu's bootindex on every boot, so whatever
    # is bootindex=0 wins even after Windows has written its own boot entry.
    # With the CD at 0 a restart booted the installer again instead of the
    # install, which made the "start it again and Setup resumes" advice untrue.
    # An empty disk is not bootable, so disk-first still reaches the installer
    # on a first start.
    $args = Get-DomainQemuArgs -Vm 'bootorder' -Qemu @{
            System = 'qemu-system-x86_64w.exe'; Img = 'qemu-img.exe'
            Code = 'code.fd'; VarsTemplate = 'vars.fd'; Display = 'gtk'
        } -Disk 'd.qcow2' -Nvram 'n.fd' -Iso 'i.iso' -Virtio $null `
          -Memory 4096 -Vcpus 2 -Ports @('13389:3389') `
          -MonitorPort 24000 -AgentPort 24001
    $line = ($args -join ' ')
    Check 'the disk boots first'   $true ($line -match 'virtio-blk-pci[^ ]*bootindex=0')
    Check 'and the install ISO second' $true ($line -match 'ide-cd,bus=ide\.0,drive=cd0,bootindex=1')

    # --- ports that stopped being bindable ----------------------------------
    #
    # The two loopback ports are frozen into the launcher at create time, and on
    # this host they can stop being bindable with nobody touching the file:
    # Hyper-V reserves a fresh set of ranges at every boot. qemu then dies on
    # its own command line and the domain is "shut off" a moment after it was
    # started. `domain start` re-picks them first; this is that.
    #
    # An in-use port stands in for a reserved one. The two fail differently at
    # the socket -- WSAEADDRINUSE against WSAEACCES -- and Test-LoopbackPortFree
    # exists precisely because both mean the same thing here, so binding one is
    # a faithful stand-in and needs no hypervisor to arrange.
    Check 'the band is below the ephemeral range' $true ($script:DomainPortBandEnd -lt 49152)

    $held = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $held.Start()
    $heldPort = ([Net.IPEndPoint]$held.LocalEndpoint).Port
    try {
        Check 'a held port is not free' $false (Test-LoopbackPortFree $heldPort)

        $rv = 'repairvm'
        $rargs = Get-DomainQemuArgs -Vm $rv `
            -Qemu @{ Code = 'C:\q\share\edk2-x86_64-code.fd' } `
            -Disk (Get-DomainDisk $rv) -Nvram (Get-DomainNvram $rv) `
            -Iso 'C:\iso\win.iso' -Virtio '' -Memory 4096 -Vcpus 2 `
            -Ports @('13389:3389') -MonitorPort $heldPort -AgentPort 44445
        Write-DomainLauncher (Get-DomainLauncher $rv) 'C:\q\qemu-system-x86_64.exe' $rargs $rv

        Repair-DomainPorts $rv
        $moved = Get-DomainMonitorPort $rv
        Check 'the unbindable monitor port moved'   $true ($moved -ne $heldPort)
        Check 'and it moved into the band'          $true ($moved -ge $script:DomainPortBandStart -and $moved -le $script:DomainPortBandEnd)
        Check 'and it is one qemu can have'         $true (Test-LoopbackPortFree $moved)
        # The agent port was fine, so it is left where it was: repair moves what
        # is broken and nothing else.
        Check 'the bindable agent port stayed'      44445 (Get-GuestAgentPort $rv)
        # ...and so do the forwards, which are the user's and qemu's to complain
        # about.
        # @(): one forward comes back as the hashtable itself, not a list.
        $rfwd = @(Get-DomainForwards $rv)
        Check 'the forwards are untouched'          13389 $rfwd[0].Host

        # Nothing to do twice: a second pass over a healthy launcher leaves the
        # bytes alone, or every start would hand the domain new ports.
        $before = Get-Content -LiteralPath (Get-DomainLauncher $rv) -Raw
        Repair-DomainPorts $rv
        Check 'a healthy launcher is left alone' $before (Get-Content -LiteralPath (Get-DomainLauncher $rv) -Raw)
    } finally {
        $held.Stop()
    }

    # --- a forward two domains both want -------------------------------------
    #
    # create used to write 13389 for every domain made without -p, so of two
    # such domains only one could run: the second qemu died at startup on
    # "Could not set up host forwarding rule". create now skips a port another
    # launcher forwards, and start refuses a forward someone already holds,
    # naming who and what to type.
    #
    # slirp binds a forward on 0.0.0.0, and Windows lets 127.0.0.1 bind beside
    # that -- which is why the forward test is not the loopback one, and why
    # the holder here is on Any.
    $any = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, 0)
    $any.Start()
    $anyPort = ([Net.IPEndPoint]$any.LocalEndpoint).Port
    # A listening "monitor" is all Test-DomainRunning asks for.
    $mon = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $mon.Start()
    $monPort = ([Net.IPEndPoint]$mon.LocalEndpoint).Port
    # A port nothing holds, for a forward that exists only on paper.
    $pick = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, 0)
    $pick.Start()
    $paperPort = ([Net.IPEndPoint]$pick.LocalEndpoint).Port
    $pick.Stop()
    try {
        Check 'a port held on 0.0.0.0 is not a free forward' $false (Test-HostPortFree $anyPort)
        Check 'though the loopback test would call it free'  $true  (Test-LoopbackPortFree $anyPort)

        foreach ($d in @(
                @{ Vm = 'paper';  Port = $paperPort; Monitor = 44446 }
                @{ Vm = 'holder'; Port = $anyPort;   Monitor = $monPort }
                @{ Vm = 'second'; Port = $anyPort;   Monitor = 44447 })) {
            $dargs = Get-DomainQemuArgs -Vm $d.Vm `
                -Qemu @{ Code = 'C:\q\share\edk2-x86_64-code.fd' } `
                -Disk (Get-DomainDisk $d.Vm) -Nvram (Get-DomainNvram $d.Vm) `
                -Iso 'C:\iso\win.iso' -Virtio '' -Memory 4096 -Vcpus 2 `
                -Ports @("$($d.Port):3389") -MonitorPort $d.Monitor -AgentPort 44445
            Write-DomainLauncher (Get-DomainLauncher $d.Vm) 'C:\q\qemu-system-x86_64.exe' $dargs $d.Vm
        }
        Check 'every launcher is a domain' $true ('holder' -in (Get-DomainNames))

        # Held on paper only: bindable now, and still not one to hand out.
        Check 'a forward on paper is bindable'           $true (Test-HostPortFree $paperPort)
        Check 'and is still skipped for a new domain'    $true ((Get-FreeForwardPort $paperPort) -ne $paperPort)
        Check 'a held port is skipped too'               $true ((Get-FreeForwardPort $anyPort) -ne $anyPort)

        $ok = $true
        try { Assert-DomainForwardsFree 'paper' } catch { $ok = $false }
        Check 'a domain whose forwards are free may start' $true $ok

        $said = ''
        try { Assert-DomainForwardsFree 'second' } catch { $said = $_.Exception.Message }
        Check 'start refuses a forward a running domain holds' $true ($said -match 'holder is running')
        Check 'and says how to move it'          $true ($said -match "domain port second -c $anyPort\b")
        Check 'to a port it can have'            $true ($said -match "domain port second (\d+):3389" -and
                                                        (Test-HostPortFree ([int]$Matches[1])))

        # Nothing running claims it: the port is still held, by someone else.
        $mon.Stop()
        $said = ''
        try { Assert-DomainForwardsFree 'second' } catch { $said = $_.Exception.Message }
        Check 'a holder that is not a domain is named as such' $true ($said -match 'something else on this host')
    } finally {
        $any.Stop()
        $mon.Stop()
    }

    # --- the legacy profile, -o winxp ----------------------------------------
    #
    # XP has inbox drivers for none of what the default profile builds, so the
    # profile is a different machine; but everything the rest of this driver
    # reads back out of a launcher has to read back the same.
    $xv = 'xpvm'
    $xargs = Get-DomainQemuArgs -Vm $xv -Qemu @{ Code = 'C:\q\share\edk2-x86_64-code.fd' } `
        -Disk (Get-DomainDisk $xv) -Nvram (Get-DomainNvram $xv) -Iso 'C:\iso\xp.iso' `
        -Virtio '' -Memory 1024 -Vcpus 1 -Ports @('13390:3389') `
        -MonitorPort 44450 -AgentPort 44451 -Legacy -Floppy (Get-DomainFloppy $xv)
    $xline = ($xargs -join ' ')
    Check 'winxp: a pc machine'               $true  ($xline -match '-machine pc,smm=off')
    Check 'winxp: no UEFI firmware'           $false ($xline -match 'pflash')
    Check 'winxp: an IDE disk, booted first'  $true  ($xline -match 'ide-hd,bus=ide\.0,unit=0,drive=hd0,bootindex=0')
    Check 'winxp: the CD second'              $true  ($xline -match 'ide-cd,bus=ide\.1,unit=0,drive=cd0,bootindex=1')
    Check 'winxp: nothing virtio'             $false ($xline -match 'virtio')
    Check 'winxp: an inbox NIC'               $true  ($xline -match 'rtl8139,netdev=net0')
    Check 'winxp: cirrus'                     $true  ($xline -match '-vga cirrus')
    Check 'winxp: no xhci'                    $false ($xline -match 'xhci')
    Check 'winxp: local-time RTC'             $true  ($xline -match '-rtc base=localtime')
    Check 'winxp: the agent on an ISA serial' $true  ($xline -match 'isa-serial,chardev=qga0')
    Check 'winxp: the answer floppy is A:'    $true  ($xline -match 'if=floppy,index=0')
    Write-DomainLauncher (Get-DomainLauncher $xv) 'C:\q\qemu-system-x86_64w.exe' $xargs $xv
    Check 'winxp: the monitor port reads back' 44450 (Get-DomainMonitorPort $xv)
    Check 'winxp: the agent port reads back'   44451 (Get-GuestAgentPort $xv)
    Check 'winxp: the forward reads back'      13390 (@(Get-DomainForwards $xv)[0].Host)
    Set-LauncherVcpus $xv 1
    Check 'winxp: -c rewrites its -smp'        $true ((Get-DomainLauncherText $xv) -match '-smp "1,sockets=1,cores=1,threads=1"')
    Set-LauncherMemory $xv 2048
    Check 'winxp: -m rewrites its memory'      $true ((Get-DomainLauncherText $xv) -match '(?m)^\s*-m 2048')

    # -u belongs to the legacy profile, and is refused by name without it --
    # after parsing, before the ISO is looked at.
    $said = ''
    try { New-Domain @('w11', 'C:\nonexistent.iso', '-u', 'C:\x.sif') } catch { $said = $_.Exception.Message }
    Check '-u without -o winxp is refused'     $true  ($said -match '-u is for -o winxp only')
    $said = ''
    try { New-Domain @('xp', 'C:\nonexistent.iso', '-o', 'winxp', '--unattend', 'C:\nonexistent.sif') } catch { $said = $_.Exception.Message }
    Check 'a missing answer file is named'     $true  ($said -match 'answer file not found')
    $said = ''
    try { New-Domain @('xp', 'C:\nonexistent.iso', '-o', 'winxp') } catch { $said = $_.Exception.Message }
    Check '-o winxp parses through to the ISO' $true  ($said -match 'install ISO not found')

    # The floppy is a file the domain owns, so delete takes it.
    Set-Content -LiteralPath (Get-DomainFloppy $xv) -Value 'x'
    Remove-Domain @($xv) *> $null
    Check 'delete takes the answer floppy'     $false (Test-Path -LiteralPath (Get-DomainFloppy $xv))
    Check 'and the launcher'                   $false (Test-Domain $xv)

    # --- deleting through an 8.3 short path ---------------------------------
    #
    # Remove-Item cannot do it, -LiteralPath notwithstanding, which broke
    # `domain delete` on this very host: %TEMP% here is an 8.3 alias. See
    # Remove-VirutilsFile in modules/win/paths.ps1.
    Check 'a missing file is not an error' $false (Remove-VirutilsFile (Join-Path $script:VirutilsImageDir 'nope'))
    $probe = Join-Path $script:VirutilsImageDir 'probe.tmp'
    Set-Content -LiteralPath $probe -Value 'x'
    Check 'an existing file is removed'    $true  (Remove-VirutilsFile $probe)
    Check 'and is really gone'             $false (Test-Path -LiteralPath $probe)

    # Only where the host actually has a short-name alias to delete through --
    # which is what makes this a regression test rather than a restatement.
    $shortTemp = $env:TEMP
    if ($shortTemp -and $shortTemp -ne [IO.Path]::GetTempPath().TrimEnd('')) {
        $d = Join-Path $shortTemp ('virutil-83-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($d)
        try {
            $f = Join-Path $d 'x.txt'
            Set-Content -LiteralPath $f -Value 'x'
            Check 'removed through an 8.3 short path' $true (Remove-VirutilsFile $f)
        } finally { [IO.Directory]::Delete($d, $true) }
    } else {
        [Console]::Out.WriteLine('skip     removed through an 8.3 short path (no short %TEMP% here)')
    }

    # --- which launcher a start takes ----------------------------------------
    #
    # Get-DomainStartLaunch is the whole decision, and it is pure: the task as
    # read, and this user's SID.
    $sid  = Get-DomainStartUserSid
    $want = Get-DomainStartTaskAction
    $good = @{ Enabled = $true; Path = $want.Path; Arguments = $want.Arguments; User = 'me'; Sid = $sid; Priority = 4 }
    Check 'no task: WMI, nothing to say'       'wmi|'   ((Get-DomainStartLaunch $null $sid).Via + '|' + (Get-DomainStartLaunch $null $sid).Why)
    Check 'a usable task: the task'            'task'   (Get-DomainStartLaunch $good $sid).Via
    $t = $good.Clone(); $t.Enabled = $false
    Check 'a disabled task: WMI'               'wmi'    (Get-DomainStartLaunch $t $sid).Via
    Check 'and it says so'                     $true    (((Get-DomainStartLaunch $t $sid).Why -join ' ') -match 'disabled')
    $t = $good.Clone(); $t.Sid = 'S-1-5-21-0-0-0-1'; $t.User = 'someone'
    Check 'another user''s task: WMI'          'wmi'    (Get-DomainStartLaunch $t $sid).Via
    $t = $good.Clone(); $t.Arguments = $want.Arguments.Replace($script:VirutilsImageDir, 'C:\elsewhere')
    Check 'a task for another image dir: WMI'  'wmi'    (Get-DomainStartLaunch $t $sid).Via
    Check 'and it says to set up again'        $true    (((Get-DomainStartLaunch $t $sid).Why -join ' ') -match 'virutil domain setup')

    # The action runs launchers from the image dir, named by $(Arg0), and
    # nothing else; cmd under conhost --headless, with AutoRun off.
    Check 'the action is conhost'              (Join-Path $env:WINDIR 'System32\conhost.exe') $want.Path
    Check 'headless, cmd /d /c'                $true    ($want.Arguments -match '^--headless ".*\\cmd\.exe" /d /c ')
    Check 'the launcher is $(Arg0) in the image dir' $true ($want.Arguments.EndsWith("`"`"$(Join-Path $script:VirutilsImageDir '$(Arg0).cmd')`"`""))

    # A name that could leave the image dir or the quotes never reaches the
    # scheduler.
    foreach ($bad in @('..\x', 'a"b', 'a&b', 'a/b', 'a%b')) {
        $threw = $false
        try { Start-DomainStartTask $bad } catch { $threw = $_.Exception.Message -match 'cannot go through the task' }
        Check "the task refuses the name $bad"  $true $threw
    }

    # What a start says when WMI is refused and there is no task: the ASR rule
    # by id, and the one command that fixes it.
    $msg = (Get-DomainStartFailure -Vm 'nosuch' -ReturnValue 2 -Launch @{ Via = 'wmi'; Why = '' } -TaskError $null) -join "`n"
    Check 'access denied is named'             $true ($msg -match 'returned 2 \(access denied\)')
    Check 'the ASR rule is named'              $true ($msg -match 'D1E49AAC-8F56-4280-B9BA-993A6D77406C')
    Check 'and the fix'                        $true ($msg -match '(?m)^  virutil domain setup$')
    $msg = (Get-DomainStartFailure -Vm 'nosuch' -ReturnValue 2 -Launch @{ Via = 'task'; Why = '' } -TaskError 'starting the scheduled task failed: no desktop') -join "`n"
    Check 'a failed task start is said too'    $true ($msg -match 'no desktop')
    Check 'without telling a set-up host to set up' $false ($msg -match '(?m)^  virutil domain setup$')

    # --- the launcher runs outside the caller's process tree -------------------
    #
    # A child of this process would share its job object, and a terminal that
    # closes a pane ends that job: closing one psmux window killed three running
    # guests. The launchers here stand in for real ones -- no qemu: each writes
    # a marker and leaves a ping running behind it the way a real one leaves
    # qemu behind its `start /b`, then exits. Each launcher is checked on its own,
    # where this host lets it run at all.

    # The stand-in's ping, found by an address no other ping on this host uses.
    function New-StandIn {
        param([string]$Launcher, [string]$Marker)
        $n = Get-Random -Minimum 2 -Maximum 254
        Set-Content -LiteralPath $Launcher -Encoding ASCII -Value @"
@echo off
echo ran> "$Marker"
start "" /b "%SystemRoot%\System32\PING.EXE" -n 60 127.0.0.$n
"@
        return "127.0.0.$n"
    }
    function Get-StandIn {
        param([string]$Addr)
        @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" |
            Where-Object { $_.CommandLine -and $_.CommandLine.EndsWith(" $Addr") })
    }
    function Wait-StandIn {
        param([string]$Addr, [string]$Marker)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 15000) {
            if ((Test-Path -LiteralPath $Marker) -and (Get-StandIn $Addr)) { return (Get-StandIn $Addr)[0] }
            Start-Sleep -Milliseconds 250
        }
        return $null
    }
    # Is PID one of this process's descendants? Walk up from it.
    function Test-OurDescendant {
        param([int]$ProcessId)
        $seen = @{}
        $p = $ProcessId
        while ($p -and -not $seen.ContainsKey($p)) {
            if ($p -eq $PID) { return $true }
            $seen[$p] = $true
            $x = Get-CimInstance Win32_Process -Filter "ProcessId=$p"
            if (-not $x) { return $false }
            $p = [int]$x.ParentProcessId
        }
        return $false
    }
    function Stop-StandIn {
        param([string]$Addr)
        Get-StandIn $Addr | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }

    # WMI, from a directory with a space in it, which the cmd /c quoting has to
    # carry. Where Defender's ASR rule blocks WMI process creation, Create
    # returns 2 and there is nothing to run; that is said and skipped, since
    # the failure message above is what such a host gets.
    $savedImageDir = $script:VirutilsImageDir
    $script:VirutilsImageDir = Join-Path $savedImageDir 'with space'
    New-VirutilsDir $script:VirutilsImageDir | Out-Null
    $sv = 'startvm'
    $marker = Join-Path $script:VirutilsImageDir 'started.txt'
    $addr = New-StandIn (Get-DomainLauncher $sv) $marker
    try {
        $rv = Start-DomainProcessWmi $sv
        if ($rv -eq 2) {
            [Console]::Out.WriteLine('skip     the WMI launcher (Create returned 2: WMI process creation is blocked here)')
        } else {
            Check 'WMI: Create returns 0'           0     $rv
            $ping = Wait-StandIn $addr $marker
            Check 'WMI: the launcher ran'           $true ($null -ne $ping)
            Check 'WMI: not under this process'     $false $(if ($ping) { Test-OurDescendant $ping.ProcessId } else { $true })
            Check 'WMI: in this user''s session'    (Get-Process -Id $PID).SessionId $(if ($ping) { $ping.SessionId })
        }
    } finally {
        Stop-StandIn $addr
        $script:VirutilsImageDir = $savedImageDir
    }

    # The task, when this user has registered it. Its image dir is fixed at
    # setup, so the stand-in goes there -- the real one -- under a name no
    # domain has, and is removed again. What matters beyond "it ran": the
    # stand-in's ping outlives the task instance, whose cmd exits right after
    # `start /b`, as a real launcher's does.
    $task = Get-DomainStartTask
    $taskDir = $null
    if ($task -and $task.Enabled -and $task.Sid -eq $sid -and
        $task.Arguments -match '/c ""(?<dir>.+)\\\$\(Arg0\)\.cmd""$') {
        $taskDir = $Matches['dir']
    }
    if (-not $taskDir) {
        [Console]::Out.WriteLine('skip     the task launcher (virutil domain setup has not run for this user)')
    } else {
        $tv = 'virutil-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $launcher = Join-Path $taskDir "$tv.cmd"
        $marker = Join-Path $env:VIRUTILS_DIR "$tv.txt"
        $addr = New-StandIn $launcher $marker
        try {
            Start-DomainStartTask $tv
            $ping = Wait-StandIn $addr $marker
            Check 'task: the launcher ran'          $true  ($null -ne $ping)
            Check 'task: not under this process'    $false $(if ($ping) { Test-OurDescendant $ping.ProcessId } else { $true })
            Check 'task: in this user''s session'   (Get-Process -Id $PID).SessionId $(if ($ping) { $ping.SessionId })
            # The launcher's cmd is gone by now, and with it the task instance.
            Start-Sleep -Seconds 3
            $cmdLeft = @(Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($launcher) })
            Check 'task: the launcher''s cmd exited' 0 $cmdLeft.Count
            Check 'task: what it started outlives it' $true ((Get-StandIn $addr).Count -gt 0)
        } finally {
            Stop-StandIn $addr
            [IO.File]::Delete($launcher)
        }
    }

    # --- destroy ----------------------------------------------------------------
    #
    # No qemu here either. A stand-in "qemu" is a process of its own: one that
    # answers on the domain's monitor port and exits on `quit`, as qemu does,
    # and one that holds no monitor at all and has to be killed. The process
    # table is read through Get-DomainProcess, which matches qemu's own image
    # name, so it is pointed at the stand-ins for this section.
    $script:StandInQemu = @{}
    function Get-DomainProcess {
        param([string]$Vm)
        $id = $script:StandInQemu[$Vm]
        if ($id) { Get-CimInstance Win32_Process -Filter "ProcessId=$id" }
    }
    function New-DestroyDomain {
        param([string]$Vm, [int]$Monitor)
        $dargs = Get-DomainQemuArgs -Vm $Vm `
            -Qemu @{ Code = 'C:\q\share\edk2-x86_64-code.fd' } `
            -Disk (Get-DomainDisk $Vm) -Nvram (Get-DomainNvram $Vm) `
            -Iso 'C:\iso\win.iso' -Virtio '' -Memory 4096 -Vcpus 1 `
            -Ports @() -MonitorPort $Monitor -AgentPort ($Monitor + 1)
        Write-DomainLauncher (Get-DomainLauncher $Vm) 'C:\q\qemu-system-x86_64.exe' $dargs $Vm
    }
    function Get-UnusedLoopbackPort {
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $l.Start(); $p = ([Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop()
        return $p
    }
    $monitorStandIn = Join-Path $env:VIRUTILS_DIR 'monitor-stand-in.ps1'
    Set-Content -LiteralPath $monitorStandIn -Encoding ASCII -Value @'
param([int]$Port)
$l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
$l.Start()
while ($true) {
    $c = $l.AcceptTcpClient()
    $s = $c.GetStream()
    $w = New-Object IO.StreamWriter($s); $w.AutoFlush = $true
    $w.Write("QEMU stand-in monitor`r`n(qemu) ")
    $line = $null
    try { $line = (New-Object IO.StreamReader($s)).ReadLine() } catch { }
    $c.Close()
    if ($line -eq 'quit') { $l.Stop(); exit 0 }
}
'@
    $self = (Get-Process -Id $PID).Path
    $quitter = $null; $deaf = $null
    try {
        # A guest that answers its monitor: `quit` ends it.
        $qp = Get-UnusedLoopbackPort
        New-DestroyDomain 'quitter' $qp
        $quitter = Start-Process -FilePath $self -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $monitorStandIn, $qp) -WindowStyle Hidden -PassThru
        $script:StandInQemu['quitter'] = $quitter.Id
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-DomainRunning 'quitter') -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 200 }
        Check 'destroy: the stand-in answers its monitor' $true (Test-DomainRunning 'quitter')
        $said = ''
        try { Stop-DomainNow @('quitter') } catch { $said = $_.Exception.Message }
        Check 'destroy: quit over the monitor ends it'  ''     $said
        Check 'destroy: and the process is gone'        $true  ($quitter.WaitForExit(2000))
        Check 'destroy: the domain reads shut off'      $false (Test-DomainRunning 'quitter')

        # A guest with no monitor answering, only a process: it is killed.
        $deaf = Start-Process -FilePath "$env:SystemRoot\System32\PING.EXE" -ArgumentList @('-n', '120', '127.0.0.1') -WindowStyle Hidden -PassThru
        New-DestroyDomain 'deaf' (Get-UnusedLoopbackPort)
        $script:StandInQemu['deaf'] = $deaf.Id
        $said = ''
        try { Stop-DomainNow @('deaf') } catch { $said = $_.Exception.Message }
        Check 'destroy: a qemu with no monitor is killed' ''    $said
        Check 'destroy: and that process is gone too'     $true ($deaf.WaitForExit(2000))

        # Nothing running: said, as shutdown says it.
        $said = ''
        try { Stop-DomainNow @('deaf') } catch { $said = $_.Exception.Message }
        Check 'destroy: a domain that is off is refused' $true ($said -match 'deaf is not running')
    } finally {
        foreach ($p in @($quitter, $deaf)) {
            if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("$($script:Pass) passed, $($script:Fail) failed")
} finally {
    # [IO.Directory]::Delete, not Remove-Item: Remove-Item truncates a path at a
    # `~` segment, and a temp directory on a profile with an 8.3 short name has
    # one. See Remove-VirutilsFile in modules/win/paths.ps1.
    if (Test-Path -LiteralPath $env:VIRUTILS_DIR) {
        [IO.Directory]::Delete($env:VIRUTILS_DIR, $true)
    }
}

exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
