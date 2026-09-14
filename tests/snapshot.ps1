<#
.SYNOPSIS
  The snapshot round trip against a real qcow2: create, list, revert, delete.

.DESCRIPTION
  modules/snapshot.ps1 has no state of its own -- a snapshot lives inside the
  domain's own disk image and is read back out of `qemu-img snapshot -l`, so
  that output is a parsing contract the same way the launcher is one for
  tests/domain.ps1 and tests/usb.ps1.

  A real qemu-img against a real (tiny, empty) qcow2, and no guest: everything
  under test here is what the module does on a shut-off domain, which on this
  host is every writing verb it has. Skipped, loudly, where there is no qemu.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path (Split-Path -Parent $here) 'modules'

$env:VIRUTILS_DIR = Join-Path ([IO.Path]::GetTempPath()) ("virutil-test-" + [Guid]::NewGuid().ToString('N'))

. (Join-Path $moduleDir 'parser.ps1')
. (Join-Path $moduleDir 'paths.ps1')
. (Join-Path $moduleDir 'payload.ps1')
. (Join-Path $moduleDir 'guest.ps1')
. (Join-Path $moduleDir 'domain.ps1')
. (Join-Path $moduleDir 'snapshot.ps1')

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

# Fails is the other half of every check here: this module's job is as much
# refusing an operation as doing one, and a refusal that does not happen is a
# snapshot silently not taken.
function Fails {
    param([string]$Name, [scriptblock]$Block, [string]$Match)
    try {
        & $Block | Out-Null
        [Console]::Out.WriteLine("FAIL     $Name")
        [Console]::Out.WriteLine('         wanted a refusal, got none')
        $script:Fail++
    } catch {
        if ($_.Exception.Message -match $Match) {
            [Console]::Out.WriteLine("ok       $Name")
            $script:Pass++
        } else {
            [Console]::Out.WriteLine("FAIL     $Name")
            [Console]::Out.WriteLine("         wanted /$Match/, got [$($_.Exception.Message)]")
            $script:Fail++
        }
    }
}

try {
    $qemuImg = $null
    try { $qemuImg = (Get-QemuTools).Img } catch { }
    if (-not $qemuImg) {
        [Console]::Out.WriteLine('skip     no qemu on this host -- snapshot was not exercised')
        exit 0
    }

    New-VirutilsDir $script:VirutilsImageDir | Out-Null

    $vm = 'testvm'
    $disk = Get-DomainDisk $vm

    # A launcher makes it a domain as far as the driver is concerned, and a
    # monitor port nothing listens on makes it a shut-off one.
    $qemuArgs = Get-DomainQemuArgs -Vm $vm `
        -Qemu @{ Code = 'C:\q\share\edk2-x86_64-code.fd' } `
        -Disk $disk -Nvram (Get-DomainNvram $vm) `
        -Iso 'C:\iso\win.iso' -Virtio '' -Memory 2048 -Vcpus 2 `
        -Ports @('13389:3389') -MonitorPort 44444
    Write-DomainLauncher (Get-DomainLauncher $vm) 'C:\q\qemu-system-x86_64.exe' $qemuArgs $vm

    Fails 'a missing disk is named, not qemu-img''s error' `
        { Assert-SnapshotDomain $vm } "disk is missing"

    & $qemuImg create -f qcow2 -o cluster_size=1M -- $disk 64M | Out-Null

    Check 'a fresh image has no snapshots' 0 (@(Get-SnapshotNames $vm).Count)

    # The names this driver is willing to write. A name with a space in it
    # would mean one thing to qemu-img and another to the HMP monitor, which
    # is why it is refused rather than quoted.
    Check 'a plain name is taken'       'snap-1' (Read-SnapshotName 'snap-1')
    Fails 'a name with a space is not'  { Read-SnapshotName 'two words' } 'not a name'
    Fails 'a name with a quote is not'  { Read-SnapshotName 'a"b' }       'not a name'
    Fails 'an empty name is not'        { Read-SnapshotName '' }          'not a name'

    New-DomainSnapshot @($vm, 'first')
    $names = @(Get-SnapshotNames $vm)
    Check 'a snapshot can be created'   1 $names.Count
    Check 'and reads back as it went in' 'first' $names[0]

    Fails 'a duplicate name is refused' `
        { New-DomainSnapshot @($vm, 'first') } 'already exists'

    New-DomainSnapshot @($vm)
    $names = @(Get-SnapshotNames $vm)
    Check 'the default name is dated'   $true (($names -join ' ') -match 'snap-\d{8}-\d{6}')
    Check 'both snapshots are there'    2 $names.Count

    Restore-DomainSnapshot @($vm, 'first')
    Check 'a revert keeps both records' 2 (@(Get-SnapshotNames $vm).Count)

    Fails 'reverting to a missing one is refused' `
        { Restore-DomainSnapshot @($vm, 'nosuch') } 'no such snapshot'
    Fails 'deleting a missing one is refused' `
        { Remove-DomainSnapshot @($vm, 'nosuch') } 'no such snapshot'

    Remove-DomainSnapshot @($vm, 'first')
    $names = @(Get-SnapshotNames $vm)
    Check 'a snapshot can be deleted'   1 $names.Count
    Check 'and it was the named one'    $false ($names -contains 'first')

    # There is no file outside the qcow2 to leak, and that is the whole reason
    # this module has no sweep: the image directory holds the disk, the nvram,
    # the launcher and the ovmf log, and nothing a snapshot added.
    $extra = @(Get-ChildItem -LiteralPath $script:VirutilsImageDir |
               Where-Object { $_.Name -notin @("$vm.qcow2", "${vm}_VARS.fd", "$vm.cmd", "$vm-ovmf.log") })
    Check 'a snapshot leaves no files behind' 0 $extra.Count

    Fails 'an unknown domain is refused' `
        { Show-DomainSnapshots @('nosuchvm') } 'no such domain'

    # The guard that matters most, because nothing underneath it will catch a
    # miss: qemu on Windows takes no lock on its image, and `qemu-img snapshot
    # -c` against the disk of a running domain was measured returning exit 0
    # and writing into it. A handle held open here stands in for the live qemu
    # -- including the case the monitor cannot see, a qemu running with nothing
    # answering on its monitor port.
    $held = [IO.File]::Open($disk, 'Open', 'ReadWrite', 'Read')
    try {
        Fails 'create is refused while the disk is open' `
            { New-DomainSnapshot @($vm, 'held') } 'has .* disk open'
        Fails 'revert is refused while the disk is open' `
            { Restore-DomainSnapshot @($vm, 'first') } 'has .* disk open'
        Fails 'delete is refused while the disk is open' `
            { Remove-DomainSnapshot @($vm, 'first') } 'has .* disk open'
    } finally { $held.Close() }

    Check 'and it is writable again once released' $false (Test-DiskInUse $disk)

    [Console]::Out.WriteLine("`n$script:Pass passed, $script:Fail failed")
    if ($script:Fail -gt 0) { exit 1 }
} finally {
    Remove-Item -Recurse -Force -LiteralPath $script:VirutilsRoot -ErrorAction SilentlyContinue
}
