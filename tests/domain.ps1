<#
.SYNOPSIS
  The launcher is the domain: check that reading one back works.

.DESCRIPTION
  modules/domain.ps1 keeps no state beside the per-VM .cmd launcher -- the
  monitor port and every port forward are read back out of it, and `port` edits
  it in place. That makes the launcher a parsing contract with itself, and this
  is what holds it: a launcher is written, read back, edited, and read again.

  No qemu and no guest. What is under test is the file, which is where every
  fact about a domain lives on this host.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path (Split-Path -Parent $here) 'modules'

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

    # --- deleting through an 8.3 short path ---------------------------------
    #
    # Remove-Item cannot do it, -LiteralPath notwithstanding, which broke
    # `domain delete` on this very host: %TEMP% here is an 8.3 alias. See
    # Remove-VirutilsFile in modules/paths.ps1.
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
    # one. See Remove-VirutilsFile in modules/paths.ps1.
    if (Test-Path -LiteralPath $env:VIRUTILS_DIR) {
        [IO.Directory]::Delete($env:VIRUTILS_DIR, $true)
    }
}

exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
