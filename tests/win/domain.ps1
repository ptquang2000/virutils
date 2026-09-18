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

    # --- create has no vcpu count -------------------------------------------
    #
    # `-c` is published in contract section 2 and was honoured here until
    # recently, so the refusal has to name the flag rather than fall through to
    # "unknown flag". It also has to fire before create touches the ISO, or a
    # command line that is wrong in two ways reports the wrong one first.
    $said = ''
    try { New-Domain @('win11', 'C:\nonexistent.iso', '-c', '4') } catch { $said = ($_.Exception.Message) }
    Check 'create refuses -c'                $true ($said -match '-c is not accepted here')
    Check 'and not as an unknown flag'       $false ($said -match 'unknown flag')
    Check 'and before the ISO is looked at'  $false ($said -match 'install ISO not found')
    Check 'and it says where the count goes' $true ($said -match 'domain start win11 -c N')

    $said = ''
    try { New-Domain @('win11', 'C:\nonexistent.iso', '--vcpus', '4') } catch { $said = ($_.Exception.Message) }
    Check 'the long spelling too'            $true ($said -match '--vcpus is not accepted here')

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
