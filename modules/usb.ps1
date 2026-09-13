# usb -- pass a physical USB device through to a guest, on a Windows host
# running QEMU natively.
#
# The Windows half of the module docs/contract.md section 7 describes, and the
# counterpart of modules/usb: the same four verbs, the same way of naming a
# device, over the QEMU monitor instead of over libvirt. A device is `-device
# usb-host,vendorid=...,productid=...` on the qemu command line, hot-plugged
# with device_add and taken away again with device_del.
#
# What is on neither driver is the WSL case, where the device is plugged into
# Windows and the domain is inside the Linux kernel's view. Getting it across is
# a usbipd recipe in the README rather than a command; see section 7.
#
# A device is named by VENDOR:PRODUCT, lowercase hex, and never by a bus path.
# A qemu `hostbus.hostaddr` pair would work too, but it names a *port* and so
# changes when the device moves sockets, which is the property that made the
# old bash module's busids so easy to get wrong.
#
# An attach is two things at once, exactly as `domain port` is: a device_add in
# the running qemu, and a line in the launcher so it is still there after the
# next boot. Doing only the first would lose it on reboot; doing only the second
# would not attach it now. A persisted usb-host whose device is unplugged does
# not stop the domain from booting -- qemu waits for it to appear -- so there is
# no equivalent of libvirt's startupPolicy to set.
#
# **Whether qemu can claim the device is a Windows question, not a virutil
# one.** qemu reaches USB through libusb, and libusb cannot open a device that a
# Windows class driver already owns. Installing UsbDk lets it capture one
# anyway; short of that the device needs WinUSB bound to it (Zadig). A
# device_add that qemu accepts and a guest that then sees nothing is almost
# always this.

function Get-UsbUsage {
    @(
        'usage: virutil usb list'
        '       virutil usb show   VM'
        '       virutil usb attach VM VENDOR:PRODUCT'
        '       virutil usb detach VM VENDOR:PRODUCT'
        ''
        'VENDOR:PRODUCT is lowercase hex, the first column of'
        "'virutil usb list'. It names the device rather than the port it is"
        'plugged into, so it survives moving it between sockets.'
        ''
        'attach and detach act on the running guest and on its launcher, so a'
        'device attached once is still attached after the next boot. attach on'
        'a shut-off domain writes the launcher alone.'
        ''
        '  -h, --help        this message'
        ''
        'qemu takes the device from Windows through libusb, which cannot open'
        'a device a Windows class driver already owns. Install UsbDk to let it'
        'capture one anyway, or bind WinUSB to the device with Zadig. A device'
        'qemu accepts but the guest never sees is nearly always that.'
    )
}

function Usb-Main {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { Usage (Get-UsbUsage) 1 }
    $cmd = $Arguments[0]
    if ($cmd -in @('-h', '--help')) { Usage (Get-UsbUsage) 0 }

    $rest = Get-RestArgs $Arguments 1

    switch ($cmd) {
        'list'   { Show-UsbHostDevices $rest }
        'show'   { Show-DomainUsb     $rest }
        'attach' { Add-DomainUsb      $rest }
        'detach' { Remove-DomainUsb   $rest }
        default  { Die "virutil usb: unknown command: $cmd (see: virutil usb -h)" }
    }
}

# --- naming a device --------------------------------------------------------

# Read-UsbId ARG -- VENDOR:PRODUCT, lowercased. qemu and Windows both spell
# hardware ids in hex but disagree on case, so everything past here is lower.
function Read-UsbId {
    param([string]$Arg)
    if ($Arg -notmatch '^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$') {
        Die "expected a VENDOR:PRODUCT (e.g. 0951:1666, see: virutil usb list), got '$Arg'"
    }
    return $Arg.ToLowerInvariant()
}

# The qemu device id for one hardware id. Hyphens rather than colons: a qemu id
# is [A-Za-z][A-Za-z0-9._-]*, and device_del takes this and nothing else.
function Get-UsbQemuId {
    param([string]$Id)
    return 'usb-' + $Id.Replace(':', '-')
}

function Get-UsbQemuSpec {
    param([string]$Id)
    return 'usb-host,vendorid=0x{0},productid=0x{1},id={2}' -f
           $Id.Split(':')[0], $Id.Split(':')[1], (Get-UsbQemuId $Id)
}

# --- list -------------------------------------------------------------------

# The host's USB devices, as VENDOR:PRODUCT plus the name Windows knows them
# by. Read from PnP rather than from qemu's own `info usbhost`, which needs a
# running domain to ask -- listing what is plugged in should not require a VM.
#
# One physical device can be several PnP entities (a composite device enumerates
# an interface each), and they all carry the same VID/PID, so the list is
# deduplicated on the id.
function Show-UsbHostDevices {
    param([string[]]$Arguments)

    $seen = @{}
    $rows = @()
    foreach ($d in Get-CimInstance -ClassName Win32_PnPEntity) {
        $m = [regex]::Match([string]$d.PNPDeviceID, '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})')
        if (-not $m.Success) { continue }
        $id = ('{0}:{1}' -f $m.Groups[1].Value, $m.Groups[2].Value).ToLowerInvariant()
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $rows += [pscustomobject]@{ Id = $id; Name = $d.Name }
    }
    if ($rows.Count -eq 0) { Say 'no USB devices found'; return }
    foreach ($r in ($rows | Sort-Object Id)) {
        [Console]::Out.WriteLine(('{0}  {1}' -f $r.Id, $r.Name))
    }
}

# --- the launcher side ------------------------------------------------------

# The devices this domain's launcher passes through, as VENDOR:PRODUCT. The
# optional quote is the same one Get-DomainMonitorPort allows for: the launcher
# quotes any value holding a comma, and this one always does.
function Get-DomainUsbIds {
    param([string]$Vm)
    $out = @()
    $pattern = '-device\s+"?usb-host,vendorid=0x([0-9a-fA-F]{4}),productid=0x([0-9a-fA-F]{4})'
    foreach ($m in [regex]::Matches((Get-DomainLauncherText $Vm), $pattern)) {
        $out += ('{0}:{1}' -f $m.Groups[1].Value, $m.Groups[2].Value).ToLowerInvariant()
    }
    return $out
}

# Added immediately before -monitor, which every launcher this driver writes
# ends with, so the new pair lands inside the continuation and not after the
# line that closes it.
function Add-LauncherUsb {
    param([string]$Vm, [string]$Id)
    $path = Get-DomainLauncher $Vm
    $text = Get-Content -LiteralPath $path -Raw
    $line = '-device "{0}" ^' -f (Get-UsbQemuSpec $Id)
    $new = [regex]::Replace($text, '(?m)^ *-monitor ', "    $line`r`n    -monitor ", 1)
    if ($new -eq $text) {
        Die @(
            "could not find the -monitor argument in $path to add the device before."
            'Add it to the launcher by hand:'
            "    -device `"$(Get-UsbQemuSpec $Id)`" ^"
        )
    }
    Set-Content -LiteralPath $path -Value $new -Encoding ASCII -NoNewline
}

function Remove-LauncherUsb {
    param([string]$Vm, [string]$Id)
    $path = Get-DomainLauncher $Vm
    $text = Get-Content -LiteralPath $path -Raw
    $v, $p = $Id.Split(':')
    $new = [regex]::Replace(
        $text, "(?m)^ *-device \`"?usb-host,vendorid=0x$v,productid=0x$p[^\r\n]*\r?\n", '', 1)
    Set-Content -LiteralPath $path -Value $new -Encoding ASCII -NoNewline
}

# --- show -------------------------------------------------------------------

# A device in the launcher but not in the running guest is the one that
# surprises you at the next boot, so neither view is ever shown without the
# other -- the same reason the bash driver printed live and persistent together.
function Show-DomainUsb {
    param([string[]]$Arguments)
    $vm = if ($Arguments.Count -gt 0) { $Arguments[0] } else { Usage (Get-UsbUsage) 1 }
    Assert-Domain $vm

    [Console]::Out.WriteLine('=== live ===')
    if (Test-DomainRunning $vm) {
        $reply = Invoke-DomainMonitor $vm 'info usb'
        Assert-MonitorOk $reply "list $vm's USB devices"
        # The monitor echoes a banner and the command back before the answer;
        # only the Device lines are ours.
        $lines = @($reply -split "`r?`n" | Where-Object { $_ -match '^\s*Device ' })
        if ($lines.Count -eq 0) {
            [Console]::Out.WriteLine('  none')
        } else {
            $lines | ForEach-Object { [Console]::Out.WriteLine($_.TrimEnd()) }
        }
    } else {
        [Console]::Out.WriteLine('  not running')
    }

    [Console]::Out.WriteLine('=== persistent ===')
    $ids = @(Get-DomainUsbIds $vm)
    if ($ids.Count -eq 0) {
        [Console]::Out.WriteLine('  none')
    } else {
        $ids | ForEach-Object { [Console]::Out.WriteLine("  $_") }
    }
}

# --- attach, detach ---------------------------------------------------------

function Add-DomainUsb {
    param([string[]]$Arguments)
    if ($Arguments.Count -lt 2) { Usage (Get-UsbUsage) 1 }
    $vm = $Arguments[0]
    $id = Read-UsbId $Arguments[1]
    Assert-Domain $vm

    if ((Get-DomainUsbIds $vm) -contains $id) {
        Die "$vm already passes through $id (see: virutil usb show $vm)"
    }

    Add-LauncherUsb $vm $id
    if (Test-DomainRunning $vm) {
        $reply = Invoke-DomainMonitor $vm "device_add $(Get-UsbQemuSpec $id)"
        Assert-MonitorOk $reply "attach $id"
        Say "$vm`: attached $id"
    } else {
        Say "$vm is not running: $id added to its launcher for the next boot"
    }
}

function Remove-DomainUsb {
    param([string[]]$Arguments)
    if ($Arguments.Count -lt 2) { Usage (Get-UsbUsage) 1 }
    $vm = $Arguments[0]
    $id = Read-UsbId $Arguments[1]
    Assert-Domain $vm

    # The launcher is the record, but a device_add on a running guest that was
    # never persisted is still worth removing, so a miss here is not fatal on
    # its own -- only a miss on both sides is.
    $persisted = (Get-DomainUsbIds $vm) -contains $id
    if ($persisted) { Remove-LauncherUsb $vm $id }

    $live = $false
    if (Test-DomainRunning $vm) {
        $reply = Invoke-DomainMonitor $vm "device_del $(Get-UsbQemuId $id)"
        # "Device 'usb-...' not found" is the ordinary answer for a device this
        # boot never attached, and is not a failure of this command.
        if ($null -eq $reply) { Die "could not reach the QEMU monitor to detach $id" }
        if ($reply -notmatch '(?i)not found') {
            Assert-MonitorOk $reply "detach $id"
            $live = $true
        }
    }

    if (-not $persisted -and -not $live) {
        Die "$vm does not pass through $id, live or persistent (see: virutil usb show $vm)"
    }
    Say "$vm`: detached $id"
}
