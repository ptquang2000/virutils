<#
.SYNOPSIS
  A passed-through device is a line in the launcher: check the round trip.

.DESCRIPTION
  modules/usb.ps1 persists an attach by writing a -device usb-host argument
  into the per-VM .cmd, and reads it back out with a regex. That makes the
  launcher a parsing contract, the same one tests/domain.ps1 holds for the
  monitor port and the port forwards -- and the edit has one more thing to get
  right than a forward does: it inserts a whole new argument, which must land
  inside the continuation rather than after the line that ends it.

  No qemu, no guest and no device. What is under test is the file.
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
. (Join-Path $moduleDir 'usb.ps1')

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
        -Ports @('13389:3389') -MonitorPort 44444
    Write-DomainLauncher (Get-DomainLauncher $vm) 'C:\q\qemu-system-x86_64.exe' $qemuArgs $vm

    # A device has to land on a USB bus, and the only one a domain has is the
    # xhci every launcher carries. Losing it would make every attach fail at
    # device_add with nothing here to say why.
    Check 'the domain has a USB controller' $true (($qemuArgs -join ' ') -match '-device qemu-xhci,id=xhci')

    Check 'nothing is passed through yet'   0 (@(Get-DomainUsbIds $vm).Count)
    Check 'the qemu id has no colon'        'usb-0951-1666' (Get-UsbQemuId '0951:1666')
    Check 'the spec carries both halves'    'usb-host,vendorid=0x0951,productid=0x1666,id=usb-0951-1666' (Get-UsbQemuSpec '0951:1666')

    Add-LauncherUsb $vm '0951:1666'
    $ids = @(Get-DomainUsbIds $vm)
    Check 'a device can be added'           1 $ids.Count
    Check 'and reads back as it went in'    '0951:1666' $ids[0]

    # The new argument goes before -monitor, so the launcher still ends with
    # the monitor and the line before the last still carries its `^`. A qemu
    # that never sees the rest of its command line is the failure this catches.
    $text = Get-DomainLauncherText $vm
    Check 'the monitor survives the edit'   44444 (Get-DomainMonitorPort $vm)
    Check 'the forwards survive the edit'   1 (@(Get-DomainForwards $vm).Count)
    Check 'the device is inside the run'    $true ($text -match '(?m)^ *-device "usb-host[^\r\n]*\^\r?\n *-monitor ')

    Add-LauncherUsb $vm '8087:0033'
    Check 'a second device can be added'    2 (@(Get-DomainUsbIds $vm).Count)

    Remove-LauncherUsb $vm '0951:1666'
    $ids = @(Get-DomainUsbIds $vm)
    Check 'a device can be removed'         1 $ids.Count
    Check 'the right one went'              '8087:0033' $ids[0]
    Check 'the monitor still reads back'    44444 (Get-DomainMonitorPort $vm)

    # usb-tablet is a -device line too, and a remove that matched on -device
    # alone would take the guest's pointer away with the passthrough.
    Check 'usb-tablet is untouched'         $true ((Get-DomainLauncherText $vm) -match '-device usb-tablet')

    # Case is Windows's to disagree about: PnP spells a hardware id in upper
    # hex and qemu in lower, so everything past Read-UsbId is lower.
    Check 'an id is lowercased'             '0951:1666' (Read-UsbId '0951:1666'.ToUpperInvariant())

    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("$($script:Pass) passed, $($script:Fail) failed")
} finally {
    if (Test-Path -LiteralPath $env:VIRUTILS_DIR) {
        [IO.Directory]::Delete($env:VIRUTILS_DIR, $true)
    }
}

exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
