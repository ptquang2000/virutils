# usb -- pass a physical USB device through to a guest, on a Windows host
# running QEMU natively.
#
# The Windows half of the module docs/contract.md section 7 describes, and the
# counterpart of modules/linux/usb: the same four verbs, the same way of naming
# a device, over the QEMU monitor instead of over libvirt. A device is `-device
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
#
# The second half of this file is a different thing on the same bus: **USB
# sticks qemu emulates itself**, plugged and pulled at runtime -- `plug`,
# `unplug`, `cycle`, with `image` to make a blank stick and `ports` to give an
# older launcher room for them. Nothing on the host is involved, so none of the
# libusb business above applies. Three shapes, all bulk-only mass storage:
#
#   --image FILE      usb-storage on FILE (raw, qcow2, vhdx, vmdk), read-write
#   --dir DIR         usb-storage on a vvfat view of DIR: read-only, FAT16
#   --vendor/...      usb-bot + scsi-hd, so the disk has its own SCSI vendor,
#                     product and revision, then `qom-set attached true`:
#                     a hot-plugged usb-bot waits for that before it attaches
#
# They are verbs of their own rather than more ways to `attach`, because an
# attach is live and persistent at once (contract section 7) and a plug is a
# cable: live, and in the launcher only when --persist says so. A test that
# plugs and pulls a stick a hundred times wants none of them left behind in the
# launcher, and a stick that has to be there at boot asks for it.
#
# Everything goes over the HMP monitor every launcher already opens, so a domain
# needs no new socket and no restart to get it. HMP has no blockdev-add, so the
# backend is a legacy `drive_add ... if=none`, and that has one useful property
# measured on this qemu (11.1.0): `device_del` takes a drive_add'ed drive with
# it. The unplug still checks `info block` afterwards and drive_dels anything
# left.
#
# An emulated stick is named by its qemu id, which is also what `show` prints:
# there is no host device to name it by, and qemu's own VID:PID is 46f4:0001
# for every one of them.
#
# Measured on win11 (qemu 11.1.0, WHPX) by the virutil-usb research run: plug
# to disk arrival 10-90 ms on a root port, 20/20 plug/unplug cycles there, and
# 3 of 10 then 4 of 8 plugs never arriving once qemu had chained its full-speed
# hub onto the last root port. Hence `ports` and the hub warning on plug.

function Get-UsbUsage {
    @(
        'usage: virutil usb list'
        '       virutil usb show   VM'
        '       virutil usb attach VM VENDOR:PRODUCT'
        '       virutil usb detach VM VENDOR:PRODUCT'
        '       virutil usb plug   VM (--image FILE | --dir DIR) [OPTIONS]'
        '       virutil usb unplug VM ID [--persist]'
        '       virutil usb cycle  VM ID [-n N] [--off S] [--on S]'
        '       virutil usb ports  VM [N]'
        '       virutil usb image  FILE SIZE [--fs fat32] [--label L]'
        ''
        'Passthrough of a host device (list, attach, detach):'
        ''
        'VENDOR:PRODUCT is lowercase hex, the first column of'
        "'virutil usb list'. It names the device rather than the port it is"
        'plugged into, so it survives moving it between sockets.'
        ''
        'attach and detach act on the running guest and on its launcher, so a'
        'device attached once is still attached after the next boot. attach on'
        'a shut-off domain writes the launcher alone.'
        ''
        'qemu takes the device from Windows through libusb, which cannot open'
        'a device a Windows class driver already owns. Install UsbDk to let it'
        'capture one anyway, or bind WinUSB to the device with Zadig. A device'
        'qemu accepts but the guest never sees is nearly always that.'
        ''
        'Emulated USB sticks (plug, unplug, cycle, image, ports): qemu is the'
        'stick, nothing on the host is plugged anywhere. The guest sees a real'
        'arrival and a real surprise removal, which nothing in it can veto.'
        ''
        'plug options:'
        '  --image FILE      the stick is FILE (raw, qcow2, vhdx or vmdk)'
        '  --dir DIR         the stick is DIR, read-only, as FAT16 (vvfat; keep'
        '                    it under ~500 MB). Threat samples go in an image,'
        '                    never in a host folder: Defender acts on them there'
        '  --id ID           its qemu id, what unplug and cycle name it by'
        '                    (default stick0, stick1, ...)'
        '  --serial S        the USB serial, and the disk serial (default: ID in'
        '                    capitals). The guest keys the device instance on it'
        '  --label L         --dir only: the volume label (11 chars)'
        '  --vendor V        an own SCSI identity: vendor (8 chars), product (16)'
        '  --product P       and revision (4) -- the disk name the guest shows.'
        '  --rev R           Any of them makes it usb-bot + scsi-hd'
        '  --ro              --image only: read-only'
        '  --persist         also write it into the launcher, so it is there at'
        '                    every boot. On a shut-off domain, the launcher alone'
        'plug prints the ID. The VID:PID is always qemu''s 46f4:0001.'
        ''
        'unplug pulls it (device_del), waits until qemu has let go of it and frees'
        'its backend. A plugged stick that is also in the launcher comes back at'
        'the next boot unless --persist takes it out of there too.'
        ''
        'cycle unplugs and replugs a plugged stick N times, the same backend each'
        'time, leaving it plugged:'
        '  -n, --count N     cycles (default 1)'
        '  --off S           seconds unplugged (default 2)'
        '  --on S            seconds plugged between cycles (default 5)'
        ''
        'ports shows, or with N sets, the xHCI root ports in the launcher (1-15,'
        'at the next start; refused while it runs). qemu chains a full-speed hub'
        'onto the last free root port, and the guest dropped hot plugs behind it,'
        "so give a domain made before this driver's 15 more: ports VM 15."
        ''
        'image writes a blank raw stick image of SIZE (64M, 2G), sparse:'
        '  --fs fat32        partitioned and formatted FAT32 (at least 34M);'
        '                    without it the guest formats it (NTFS or anything)'
        '  --label L         the FAT32 volume label (11 chars)'
        ''
        '  -h, --help        this message'
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
        'plug'   { Add-DomainUsbStorage    $rest }
        'unplug' { Remove-DomainUsbStorage $rest }
        'cycle'  { Invoke-UsbStorageCycle  $rest }
        'ports'  { Set-DomainUsbPorts      $rest }
        'image'  { New-UsbStickImage       $rest }
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

    # Emulated sticks get rows of their own under each view: id, kind, port,
    # serial and backing file, which is what plug, unplug and cycle are asked
    # about and what `info usb` alone does not say.
    $running = Test-DomainRunning $vm
    [Console]::Out.WriteLine('=== live ===')
    if ($running) {
        $reply = Invoke-DomainMonitor $vm 'info usb' -UntilPrompt
        Assert-MonitorOk $reply "list $vm's USB devices"
        # The monitor echoes a banner and the command back before the answer;
        # only the Device lines are ours.
        $lines = @($reply -split "`r?`n" | Where-Object { $_ -match '^\s*Device ' })
        if ($lines.Count -eq 0) {
            [Console]::Out.WriteLine('  none')
        } else {
            $lines | ForEach-Object { [Console]::Out.WriteLine($_.TrimEnd()) }
        }
        Write-UsbStorageRows @(Get-LiveUsbStorage $vm) -Live
    } else {
        [Console]::Out.WriteLine('  not running')
    }

    [Console]::Out.WriteLine('=== persistent ===')
    $ids = @(Get-DomainUsbIds $vm)
    $sticks = @(Get-LauncherUsbStorage $vm)
    if ($ids.Count -eq 0 -and $sticks.Count -eq 0) {
        [Console]::Out.WriteLine('  none')
    } else {
        $ids | ForEach-Object { [Console]::Out.WriteLine("  $_") }
        Write-UsbStorageRows $sticks
    }
}

# One aligned row per stick. Live rows carry the port, and a port with a dot in
# it is behind qemu's hub, which is said on the row rather than left to be
# decoded.
function Write-UsbStorageRows {
    param([object[]]$Sticks, [switch]$Live)
    if (-not $Sticks -or $Sticks.Count -eq 0) { return }
    $rows = foreach ($s in $Sticks) {
        $port = if ($Live) { if ($s.Port) { "port $($s.Port)" } else { 'not attached' } } else { '' }
        $note = @()
        if ($s.Kind -eq 'disk') { $note += "scsi $($s.Vendor)/$($s.Product)/$($s.Rev)" }
        if ($Live -and $s.Port -and $s.Port.Contains('.')) { $note += "behind qemu's full-speed hub" }
        [pscustomobject]@{
            Id = $s.Id; Kind = $s.Kind; Port = $port
            Serial = $(if ($s.Serial) { "serial $($s.Serial)" } else { 'no serial' })
            Backing = (Get-UsbStorageBacking $s)
            Note = $(if ($note) { '  [' + ($note -join '; ') + ']' } else { '' })
        }
    }
    $wId = ($rows | ForEach-Object { $_.Id.Length } | Measure-Object -Maximum).Maximum
    $wPort = ($rows | ForEach-Object { $_.Port.Length } | Measure-Object -Maximum).Maximum
    $wSer = ($rows | ForEach-Object { $_.Serial.Length } | Measure-Object -Maximum).Maximum
    foreach ($r in $rows) {
        $line = '  ' + $r.Id.PadRight($wId) + '  ' + $r.Kind.PadRight(7)
        if ($Live) { $line += '  ' + $r.Port.PadRight($wPort) }
        $line += '  ' + $r.Serial.PadRight($wSer) + '  ' + $r.Backing + $r.Note
        [Console]::Out.WriteLine($line)
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

# --- emulated storage: what a stick is --------------------------------------
#
# A stick is an ordered map rather than an object, read the same way from the
# three places one can be described: the plug command line, the launcher, and
# a running qemu's `info qtree` + `info block`. `cycle` replugs from the third,
# so a stick someone wrote into a launcher by hand cycles like one plug made.

function New-UsbStorageSpec {
    [ordered]@{
        Id = $null; Kind = 'storage'; Serial = $null; Removable = $true
        Drive = $null; Image = $null; Format = $null; ReadOnly = $false
        Dir = $null; Label = $null
        Vendor = $null; Product = $null; Rev = $null
        Port = $null; Lines = @()
    }
}

# ConvertFrom-QemuOpts 'usb-storage,drive=d,serial=S' -- the options as an
# ordered map, with the leading bare word (the device type) under ''. A doubled
# comma is qemu's escape for a comma inside a value, so a path holding one
# reads back whole.
function ConvertFrom-QemuOpts {
    param([string]$Text)
    $parts = @()
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq ',') {
            if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq ',') { [void]$sb.Append(','); $i++; continue }
            $parts += $sb.ToString()
            [void]$sb.Clear()
            continue
        }
        [void]$sb.Append($c)
    }
    $parts += $sb.ToString()
    $opts = [ordered]@{}
    foreach ($p in $parts) {
        $eq = $p.IndexOf('=')
        if ($eq -lt 0) { $opts[''] = $p } else { $opts[$p.Substring(0, $eq)] = $p.Substring($eq + 1) }
    }
    return $opts
}

function ConvertTo-QemuOptValue { param([string]$Value) $Value.Replace(',', ',,') }

function Test-QemuOptOn { param($Value) return ([string]$Value -in @('on', 'true', 'yes')) }

# One HMP argument. The monitor splits its line on spaces unless the argument
# is quoted, and inside the quotes a backslash escapes, so a Windows path goes
# in with its backslashes doubled. Measured: unquoted, a scsi-hd product with a
# space in it was "extraneous characters at the end of line".
function ConvertTo-HmpString {
    param([string]$Text)
    return '"' + $Text.Replace('\', '\\').Replace('"', '\"') + '"'
}

# The drive half: what drive_add takes live and -drive takes in the launcher,
# the same string both ways. vvfat is always read-only here: its writable mode
# writes through to the host folder, which is the last thing a stick of test
# files should do.
function Get-UsbStorageDriveOpts {
    param($Spec)
    if ($Spec.Dir) {
        $o = "if=none,id=$($Spec.Drive),driver=vvfat,dir=$(ConvertTo-QemuOptValue $Spec.Dir)"
        if ($Spec.Label) { $o += ",label=$(ConvertTo-QemuOptValue $Spec.Label)" }
        return $o + ',readonly=on'
    }
    $o = "file=$(ConvertTo-QemuOptValue $Spec.Image),if=none,id=$($Spec.Drive),format=$($Spec.Format)"
    if ($Spec.ReadOnly) { $o += ',readonly=on' }
    return $o
}

# The device half, one string per -device. A disk is two: the usb-bot that is
# the USB side, and the scsi-hd on its bus that carries the SCSI identity.
function Get-UsbStorageDeviceOpts {
    param($Spec)
    $serial = if ($Spec.Serial) { ",serial=$(ConvertTo-QemuOptValue $Spec.Serial)" } else { '' }
    $removable = if ($Spec.Removable) { ',removable=on' } else { '' }
    if ($Spec.Kind -eq 'disk') {
        $scsi = "scsi-hd,bus=$($Spec.Id).0,drive=$($Spec.Drive)"
        if ($Spec.Vendor)  { $scsi += ",vendor=$(ConvertTo-QemuOptValue $Spec.Vendor)" }
        if ($Spec.Product) { $scsi += ",product=$(ConvertTo-QemuOptValue $Spec.Product)" }
        if ($Spec.Rev)     { $scsi += ",ver=$(ConvertTo-QemuOptValue $Spec.Rev)" }
        return @("usb-bot,id=$($Spec.Id)$serial", "$scsi$serial$removable")
    }
    return @("usb-storage,drive=$($Spec.Drive),id=$($Spec.Id)$serial$removable")
}

function Get-UsbStorageBacking {
    param($Spec)
    if ($Spec.Dir) {
        $label = if ($Spec.Label) { ", label $($Spec.Label)" } else { '' }
        return "$($Spec.Dir) (folder, read-only$label)"
    }
    if ($Spec.Image) {
        $ro = if ($Spec.ReadOnly) { ', read-only' } else { '' }
        return "$($Spec.Image) ($($Spec.Format)$ro)"
    }
    return '(no backend)'
}

# Set-UsbStorageBackend SPEC OPTS -- the backend fields, from a drive's options.
function Set-UsbStorageBackend {
    param($Spec, $Opts)
    if ($Opts['driver'] -eq 'vvfat') {
        $Spec.Dir = $Opts['dir']; $Spec.Label = $Opts['label']
    } else {
        $Spec.Image = $Opts['file']
        $Spec.Format = if ($Opts['format']) { $Opts['format'] } else { 'raw' }
        $Spec.ReadOnly = (Test-QemuOptOn $Opts['readonly']) -or (Test-QemuOptOn $Opts['read-only'])
    }
}

# The image's format from its first bytes, so qemu is never left to probe a raw
# image -- which it refuses to write sector 0 of when it does.
function Get-UsbImageFormat {
    param([string]$Path)
    $head = New-Object byte[] 8
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { [void]$fs.Read($head, 0, 8) } finally { $fs.Close() }
    $ascii = [Text.Encoding]::ASCII.GetString($head)
    if ($head[0] -eq 0x51 -and $head[1] -eq 0x46 -and $head[2] -eq 0x49 -and $head[3] -eq 0xFB) { return 'qcow2' }
    if ($ascii -eq 'vhdxfile') { return 'vhdx' }
    if ($ascii.StartsWith('KDMV')) { return 'vmdk' }
    return 'raw'
}

# --- emulated storage: the launcher side -------------------------------------

# Every -drive and -device line in the launcher, its options parsed, and the
# line itself so a removal takes exactly what was there.
function Get-LauncherQemuLines {
    param([string]$Vm)
    $out = @()
    foreach ($m in [regex]::Matches((Get-DomainLauncherText $Vm),
                                    '(?m)^[ \t]*-(drive|device)[ \t]+(.*?)[ \t]*\^?[ \t]*\r?$')) {
        $val = $m.Groups[2].Value
        if ($val.Length -ge 2 -and $val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $out += @{ Flag = $m.Groups[1].Value; Opts = (ConvertFrom-QemuOpts $val); Line = $m.Value.TrimEnd("`r") }
    }
    return $out
}

# The sticks the launcher plugs at boot: every usb-storage and usb-bot with an
# id, whoever wrote it -- win11's hand-added usbstick0 reads back like a plug.
function Get-LauncherUsbStorage {
    param([string]$Vm)
    $lines = @(Get-LauncherQemuLines $Vm)
    $drives = @{}
    foreach ($l in $lines) { if ($l.Flag -eq 'drive' -and $l.Opts['id']) { $drives[$l.Opts['id']] = $l } }
    foreach ($l in $lines) {
        if ($l.Flag -ne 'device' -or $l.Opts[''] -notin @('usb-storage', 'usb-bot') -or -not $l.Opts['id']) { continue }
        $s = New-UsbStorageSpec
        $s.Id = $l.Opts['id']
        $s.Serial = $l.Opts['serial']
        $s.Lines = @($l.Line)
        $scsi = $l.Opts
        if ($l.Opts[''] -eq 'usb-bot') {
            $s.Kind = 'disk'
            $scsi = $null
            foreach ($c in $lines) {
                if ($c.Flag -eq 'device' -and $c.Opts[''] -eq 'scsi-hd' -and $c.Opts['bus'] -eq "$($s.Id).0") {
                    $scsi = $c.Opts; $s.Lines += $c.Line; break
                }
            }
            if ($scsi) { $s.Vendor = $scsi['vendor']; $s.Product = $scsi['product']; $s.Rev = $scsi['ver'] }
        }
        if ($scsi) {
            $s.Removable = Test-QemuOptOn $scsi['removable']
            $s.Drive = $scsi['drive']
        }
        if ($s.Drive -and $drives.ContainsKey($s.Drive)) {
            Set-UsbStorageBackend $s $drives[$s.Drive].Opts
            $s.Lines += $drives[$s.Drive].Line
        }
        $s
    }
}

# Into the launcher before -monitor, as Add-LauncherUsb does and for the same
# reason. The launcher is cmd and ASCII: a % would be expanded and anything past
# ASCII written as '?', so a path holding either is refused rather than mangled.
function Add-LauncherUsbStorage {
    param([string]$Vm, $Spec)
    $path = Get-DomainLauncher $Vm
    $backing = if ($Spec.Dir) { $Spec.Dir } else { $Spec.Image }
    if ($backing -match '[%"]' -or $backing -match '[^\x20-\x7E]') {
        Die @(
            "$backing cannot go into $path`: the launcher is a cmd file, which"
            'expands % and is written as ASCII. Move it to a plain path to --persist it.'
        )
    }
    $add = "    -drive `"$(Get-UsbStorageDriveOpts $Spec)`" ^`r`n"
    foreach ($d in Get-UsbStorageDeviceOpts $Spec) { $add += "    -device `"$d`" ^`r`n" }
    $text = Get-Content -LiteralPath $path -Raw
    $new = [regex]::Replace($text, '(?m)^ *-monitor ', ($add.Replace('$', '$$') + '    -monitor '), 1)
    if ($new -eq $text) {
        Die @("could not find the -monitor argument in $path to add $($Spec.Id) before."
              'Add these to the launcher by hand:', $add.TrimEnd())
    }
    Set-Content -LiteralPath $path -Value $new -Encoding ASCII -NoNewline
}

function Remove-LauncherUsbStorage {
    param([string]$Vm, $Spec)
    $path = Get-DomainLauncher $Vm
    $text = Get-Content -LiteralPath $path -Raw
    foreach ($line in $Spec.Lines) {
        $text = [regex]::Replace($text, '(?m)^' + [regex]::Escape($line) + '\r?\n', '', 1)
    }
    Set-Content -LiteralPath $path -Value $text -Encoding ASCII -NoNewline
}

# --- emulated storage: the running qemu --------------------------------------

# What the monitor said, without its banner, the echoed command and prompts.
function Get-MonitorAnswer {
    param([string]$Reply)
    $clean = $Reply -replace '\x1b\[[0-9;]*[A-Za-z]', ''
    return (@($clean -split "`r?`n" | Where-Object {
        $_ -and $_ -notmatch '^QEMU .* monitor' -and $_ -notmatch '^\(qemu\)'
    }) -join "`n").Trim()
}

function Invoke-UsbMonitor {
    param([string]$Vm, [string]$Command, [int]$TimeoutMs = 5000)
    $r = Invoke-DomainMonitor $Vm $Command -TimeoutMs $TimeoutMs -UntilPrompt
    if ($null -eq $r) { Die "could not reach $Vm's QEMU monitor (is it running? virutil domain list)" }
    return $r
}

# The sticks in the running qemu, read from `info qtree` (type, id, serial,
# port, the scsi-hd's drive and identity) and `info block` (what each drive
# is). qemu's word, not the launcher's: a stick plugged by hand on the monitor
# shows here too.
function Get-LiveUsbStorage {
    param([string]$Vm)
    $qtree = @((Invoke-UsbMonitor $Vm 'info qtree') -split "`r?`n")
    $blocks = @{}
    foreach ($line in ((Invoke-UsbMonitor $Vm 'info block') -split "`r?`n")) {
        $m = [regex]::Match($line, '^(\S+) \(#block\d+\): (.+) \(([^()]*)\)\s*$')
        if ($m.Success) { $blocks[$m.Groups[1].Value] = @{ File = $m.Groups[2].Value; Format = $m.Groups[3].Value } }
    }

    for ($i = 0; $i -lt $qtree.Count; $i++) {
        $m = [regex]::Match($qtree[$i], '^(\s*)dev: (usb-storage|usb-bot), id "([^"]*)"')
        if (-not $m.Success -or -not $m.Groups[3].Value) { continue }
        $indent = $m.Groups[1].Value.Length
        $s = New-UsbStorageSpec
        $s.Id = $m.Groups[3].Value
        if ($m.Groups[2].Value -eq 'usb-bot') { $s.Kind = 'disk' }
        # The device's own properties come first, then its scsi-hd child's,
        # deeper in; a serial is on both, and the first is the USB one.
        $inScsi = $false
        $scsi = @{}
        for ($j = $i + 1; $j -lt $qtree.Count; $j++) {
            $l = $qtree[$j]
            if (-not $l.Trim()) { continue }
            if (($l.Length - $l.TrimStart().Length) -le $indent) { break }
            if ($l -match '^\s*dev: scsi-hd') { if ($inScsi) { break }; $inScsi = $true; continue }
            $p = [regex]::Match($l, '^\s*([\w-]+) = "?(.*?)"?\s*$')
            if ($inScsi) {
                if ($p.Success) { $scsi[$p.Groups[1].Value] = $p.Groups[2].Value }
            } elseif ($l -match '^\s*addr [^,]+, port ([\d.]+),.*, attached\s*$') {
                $s.Port = $Matches[1]
            } elseif ($p.Success -and $p.Groups[1].Value -eq 'serial' -and $p.Groups[2].Value) {
                $s.Serial = $p.Groups[2].Value
            }
        }
        $s.Drive = $scsi['drive']
        $s.Removable = Test-QemuOptOn $scsi['removable']
        if ($s.Kind -eq 'disk') { $s.Vendor = $scsi['vendor']; $s.Product = $scsi['product']; $s.Rev = $scsi['ver'] }
        if ($s.Drive -and $blocks.ContainsKey($s.Drive)) {
            $b = $blocks[$s.Drive]
            if ($b.File.StartsWith('json:')) {
                # A vvfat drive: {"driver": "vvfat", "dir": ...}, or nested
                # under "file" when a raw format layer sits on top of it.
                $j = $b.File.Substring(5) | ConvertFrom-Json
                if ($j.PSObject.Properties['file'] -and $j.file -isnot [string]) { $j = $j.file }
                $s.Dir = $j.dir
                if ($j.PSObject.Properties['label']) { $s.Label = $j.label }
            } else {
                $s.Image = $b.File
                $s.Format = ($b.Format -split ',')[0].Trim()
                $s.ReadOnly = $b.Format -match 'read-only'
            }
        }
        $s
    }
}

# The port `info usb` puts an id on, or $null. A dot in it means behind a hub.
function Get-UsbStoragePort {
    param([string]$Vm, [string]$Id)
    $m = [regex]::Match((Invoke-UsbMonitor $Vm 'info usb'), "(?m)Port ([\d.]+),[^\r\n]*ID: $([regex]::Escape($Id))\s*$")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Write-UsbHubWarning {
    param([string]$Vm, [string]$Id, [string]$Port)
    if (-not $Port -or -not $Port.Contains('.')) { return }
    Warn @(
        "$Id is on port $Port, behind the full-speed hub qemu chains onto the last"
        'free root port. The guest dropped hot plugs there (3 of 10, then 4 of 8,'
        'in one run). Give the domain more root ports, at its next start:'
        "  virutil usb ports $Vm $($script:UsbRootPorts)"
    )
}

# Invoke-UsbStoragePlug VM SPEC -- the backend, the device(s), and for a disk
# the attach a hot-plugged usb-bot waits for. Returns the port. A failure takes
# back whatever half went in, so a refused plug leaves qemu as it found it.
function Invoke-UsbStoragePlug {
    param([string]$Vm, $Spec)
    $what = "$($Spec.Id) ($(Get-UsbStorageBacking $Spec))"
    $r = Invoke-UsbMonitor $Vm ('drive_add 0 ' + (ConvertTo-HmpString (Get-UsbStorageDriveOpts $Spec))) 15000
    if ($r -notmatch '(?m)^OK\s*$') {
        Die @("the QEMU monitor would not open the backend of $what`:", (Get-MonitorAnswer $r))
    }
    $added = $false
    try {
        foreach ($d in Get-UsbStorageDeviceOpts $Spec) {
            $r = Invoke-UsbMonitor $Vm ('device_add ' + (ConvertTo-HmpString $d))
            Assert-MonitorOk $r "plug $what"
            $added = $true
        }
        if ($Spec.Kind -eq 'disk') {
            $r = Invoke-UsbMonitor $Vm "qom-set /machine/peripheral/$($Spec.Id) attached true"
            Assert-MonitorOk $r "attach $($Spec.Id) to the bus"
        }
    } catch {
        if ($added) { Invoke-DomainMonitor $Vm "device_del $($Spec.Id)" -UntilPrompt | Out-Null }
        Invoke-DomainMonitor $Vm "drive_del $($Spec.Drive)" -UntilPrompt | Out-Null
        throw
    }
    return (Get-UsbStoragePort $Vm $Spec.Id)
}

# Invoke-UsbStorageUnplug VM SPEC -- device_del, then wait until `info usb` no
# longer has it, then free its drive if qemu has not already. Returns the ms
# qemu took to let go.
function Invoke-UsbStorageUnplug {
    param([string]$Vm, $Spec, [int]$TimeoutMs = 10000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-UsbMonitor $Vm "device_del $($Spec.Id)"
    Assert-MonitorOk $r "unplug $($Spec.Id)"
    $idLine = "(?m)ID: $([regex]::Escape($Spec.Id))\s*$"
    while ((Invoke-UsbMonitor $Vm 'info usb') -match $idLine) {
        if ($sw.ElapsedMilliseconds -gt $TimeoutMs) {
            Die "qemu still lists $($Spec.Id) on $Vm's bus $($TimeoutMs / 1000) s after device_del"
        }
        Start-Sleep -Milliseconds 50
    }
    $ms = $sw.ElapsedMilliseconds
    if ($Spec.Drive -and (Invoke-UsbMonitor $Vm 'info block') -match "(?m)^$([regex]::Escape($Spec.Drive)) \(") {
        $r = Invoke-UsbMonitor $Vm "drive_del $($Spec.Drive)"
        Assert-MonitorOk $r "free $($Spec.Id)'s backend $($Spec.Drive)"
    }
    return $ms
}

# --- emulated storage: the commands ------------------------------------------

# An image is one writer's. **qemu on Windows takes no image lock**: measured,
# the same raw file plugged twice into one running qemu was accepted both
# times, two disks over one file, which is a corrupted filesystem the moment the
# guest writes to either. So it is checked here, against what can be read
# without touching anyone else's domain: this domain's own live sticks, and
# every launcher's -drive files, which covers another domain's disk, its sticks
# and its cdroms. Another running domain's hot-plugged sticks are not asked
# about -- that would mean taking its monitor from whoever is using it.
function Assert-UsbImageFree {
    param([string]$Vm, [string]$Image, [bool]$Running)
    if ($Running) {
        foreach ($s in Get-LiveUsbStorage $Vm) {
            if ($s.Image -and $s.Image -eq $Image) { Die "$Image is already $Vm's stick $($s.Id): one image, one stick" }
        }
    }
    foreach ($d in Get-DomainNames) {
        foreach ($l in Get-LauncherQemuLines $d) {
            if ($l.Flag -eq 'drive' -and $l.Opts['file'] -and $l.Opts['file'] -eq $Image) {
                Die "$Image is in $d's launcher ($($l.Opts['id'])): one image, one writer"
            }
        }
    }
}

function Get-UsbFlagValue {
    param([string[]]$Arguments, [int]$Index, [string]$Flag)
    if ($Index -ge $Arguments.Count) { Die "virutil usb: $Flag needs a value" }
    return $Arguments[$Index]
}

# A value that goes onto a qemu command line and into a cmd file: printable
# ASCII, and none of the characters either of those treats specially.
function Assert-UsbText {
    param([string]$Value, [string]$What, [int]$Max)
    if ($Value.Length -lt 1 -or $Value.Length -gt $Max -or $Value -match '[^\x20-\x7E]' -or $Value -match '[",\\%]') {
        Die "$What must be 1 to $Max printable ASCII characters, without , `" \ or %: got '$Value'"
    }
}

function Add-DomainUsbStorage {
    param([string[]]$Arguments)
    $vm = $null; $persist = $false
    $s = New-UsbStorageSpec
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = $Arguments[$i]
        if     ($a -eq '--image')   { $i++; $s.Image   = Get-UsbFlagValue $Arguments $i $a }
        elseif ($a -eq '--dir')     { $i++; $s.Dir     = Get-UsbFlagValue $Arguments $i $a }
        elseif ($a -eq '--id')      { $i++; $s.Id      = Get-UsbFlagValue $Arguments $i $a }
        elseif ($a -eq '--serial')  { $i++; $s.Serial  = Get-UsbFlagValue $Arguments $i $a }
        elseif ($a -eq '--label')   { $i++; $s.Label   = Get-UsbFlagValue $Arguments $i $a }
        elseif ($a -eq '--vendor')  { $i++; $s.Vendor  = Get-UsbFlagValue $Arguments $i $a }
        elseif ($a -eq '--product') { $i++; $s.Product = Get-UsbFlagValue $Arguments $i $a }
        elseif ($a -eq '--rev')     { $i++; $s.Rev     = Get-UsbFlagValue $Arguments $i $a }
        elseif ($a -eq '--ro')      { $s.ReadOnly = $true }
        elseif ($a -eq '--persist') { $persist = $true }
        elseif ($a.StartsWith('-')) { Die "virutil usb plug: $a is not a flag this driver has (see: virutil usb -h)" }
        elseif ($null -eq $vm)      { $vm = $a }
        else { Usage (Get-UsbUsage) 1 }
    }
    if (-not $vm) { Usage (Get-UsbUsage) 1 }
    Assert-Domain $vm

    if ([bool]$s.Image -eq [bool]$s.Dir) { Die 'virutil usb plug: give the stick one backend, --image FILE or --dir DIR' }
    if ($s.Image) {
        if (-not (Test-Path -LiteralPath $s.Image -PathType Leaf)) { Die "no such image: $($s.Image) (virutil usb image makes one)" }
        $s.Image = (Resolve-Path -LiteralPath $s.Image).ProviderPath
        $s.Format = Get-UsbImageFormat $s.Image
        if ($s.Label) { Die '--label is for --dir: an image carries its own volume label' }
    } else {
        if (-not (Test-Path -LiteralPath $s.Dir -PathType Container)) { Die "no such folder: $($s.Dir)" }
        $s.Dir = (Resolve-Path -LiteralPath $s.Dir).ProviderPath.TrimEnd('\')
        if ($s.ReadOnly) { Die '--ro is for --image: a --dir stick is always read-only' }
        if ($s.Label -and $s.Label -notmatch '^[A-Za-z0-9 _-]{1,11}$') {
            Die "--label is a FAT volume label: 1 to 11 letters, digits, space, _ or -; got '$($s.Label)'"
        }
    }
    if ($s.Vendor -or $s.Product -or $s.Rev) {
        $s.Kind = 'disk'
        # SCSI INQUIRY's own field widths.
        if ($s.Vendor)  { Assert-UsbText $s.Vendor  '--vendor'  8 }
        if ($s.Product) { Assert-UsbText $s.Product '--product' 16 }
        if ($s.Rev)     { Assert-UsbText $s.Rev     '--rev'     4 }
    }

    $running = Test-DomainRunning $vm
    $taken = @(Get-LauncherUsbStorage $vm | ForEach-Object { $_.Id })
    if ($running) { $taken += @(Get-LiveUsbStorage $vm | ForEach-Object { $_.Id }) }
    if ($s.Id) {
        if ($s.Id -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$' -or $s.Id -like 'usb-*') {
            Die "--id is a qemu id: a letter, then up to 31 letters, digits, _ or -, and not usb-* (passthrough's); got '$($s.Id)'"
        }
        if ($s.Id -in $taken) { Die "$vm already has a stick $($s.Id) (see: virutil usb show $vm)" }
    } else {
        $n = 0
        while ("stick$n" -in $taken) { $n++ }
        $s.Id = "stick$n"
    }
    $s.Drive = "$($s.Id)-drv"
    if ($s.Image) { Assert-UsbImageFree $vm $s.Image $running }
    if (-not $s.Serial) { $s.Serial = $s.Id.ToUpperInvariant() }
    if ($s.Serial -notmatch '^[A-Za-z0-9._-]{1,32}$') {
        Die "--serial: 1 to 32 letters, digits, ., _ or -; got '$($s.Serial)'"
    }

    if (-not $running -and -not $persist) {
        Die "$vm is not running, so there is nothing to plug $($s.Id) into. --persist writes it into the launcher for the next boot."
    }
    if ($running) {
        $port = Invoke-UsbStoragePlug $vm $s
        Say "$vm`: plugged $($s.Id) on port $port, serial $($s.Serial), $(Get-UsbStorageBacking $s)"
        Write-UsbHubWarning $vm $s.Id $port
    }
    if ($persist) {
        Add-LauncherUsbStorage $vm $s
        if ($running) { Say "$vm`: $($s.Id) is in the launcher too, so it is there at every boot" }
        else { Say "$vm is not running: $($s.Id) added to its launcher for the next boot" }
    }
    $s.Id
}

function Remove-DomainUsbStorage {
    param([string[]]$Arguments)
    $vm = $null; $id = $null; $persist = $false
    foreach ($a in $Arguments) {
        if ($a -eq '--persist') { $persist = $true }
        elseif ($a.StartsWith('-')) { Die "virutil usb unplug: $a is not a flag this driver has (see: virutil usb -h)" }
        elseif ($null -eq $vm) { $vm = $a }
        elseif ($null -eq $id) { $id = $a }
        else { Usage (Get-UsbUsage) 1 }
    }
    if (-not $id) { Usage (Get-UsbUsage) 1 }
    Assert-Domain $vm

    $persisted = @(Get-LauncherUsbStorage $vm | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    $live = $null
    if (Test-DomainRunning $vm) {
        $live = @(Get-LiveUsbStorage $vm | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    }
    if (-not $live -and -not ($persist -and $persisted)) {
        if ($persisted) {
            Die "$id is not plugged into $vm now, only written in its launcher: unplug --persist takes it out of there"
        }
        Die "$vm has no emulated stick $id, live or in its launcher (see: virutil usb show $vm)"
    }

    if ($live) {
        $ms = Invoke-UsbStorageUnplug $vm $live
        Say "$vm`: unplugged $id (gone from the bus in $ms ms)"
    }
    if ($persisted -and $persist) {
        Remove-LauncherUsbStorage $vm $persisted
        Say "$vm`: $id is out of the launcher too"
    } elseif ($persisted) {
        Say "$id is still in $vm's launcher and comes back at the next boot (unplug --persist takes it out)"
    } elseif ($persist) {
        Say "$id was not in $vm's launcher; nothing to take out of it"
    }
}

function Invoke-UsbStorageCycle {
    param([string[]]$Arguments)
    $vm = $null; $id = $null; $count = 1; $off = 2.0; $on = 5.0
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = $Arguments[$i]
        if ($a -in @('-n', '--count')) { $i++; $count = [int](Get-UsbFlagValue $Arguments $i $a) }
        elseif ($a -eq '--off') { $i++; $off = [double](Get-UsbFlagValue $Arguments $i $a) }
        elseif ($a -eq '--on')  { $i++; $on  = [double](Get-UsbFlagValue $Arguments $i $a) }
        elseif ($a.StartsWith('-')) { Die "virutil usb cycle: $a is not a flag this driver has (see: virutil usb -h)" }
        elseif ($null -eq $vm) { $vm = $a }
        elseif ($null -eq $id) { $id = $a }
        else { Usage (Get-UsbUsage) 1 }
    }
    if (-not $id) { Usage (Get-UsbUsage) 1 }
    if ($count -lt 1 -or $off -lt 0 -or $on -lt 0) { Die 'virutil usb cycle: -n is 1 or more, --off and --on 0 or more seconds' }
    Assert-Domain $vm
    if (-not (Test-DomainRunning $vm)) { Die "$vm is not running: there is nothing plugged to cycle" }
    $spec = @(Get-LiveUsbStorage $vm | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    if (-not $spec) { Die "$vm has no emulated stick $id plugged (see: virutil usb show $vm)" }
    if (-not $spec.Image -and -not $spec.Dir) {
        Die "info block does not say what $id's drive $($spec.Drive) is, so it could not be plugged back"
    }

    $warned = $false
    for ($c = 1; $c -le $count; $c++) {
        $ms = Invoke-UsbStorageUnplug $vm $spec
        Start-Sleep -Milliseconds ([int]($off * 1000))
        $port = Invoke-UsbStoragePlug $vm $spec
        Say "$vm`: cycle $c/$count -- $id unplugged ($ms ms), plugged on port $port"
        if (-not $warned -and $port -and $port.Contains('.')) { Write-UsbHubWarning $vm $id $port; $warned = $true }
        if ($c -lt $count) { Start-Sleep -Milliseconds ([int]($on * 1000)) }
    }
}

# --- root ports ---------------------------------------------------------------

# The launcher's qemu-xhci, as @{ Text; Opts; Ports }, or $null for a launcher
# with none (the winxp profile's UHCI).
function Get-LauncherXhci {
    param([string]$Vm)
    $m = [regex]::Match((Get-DomainLauncherText $Vm), '-device\s+"?(qemu-xhci[^"\s]*)"?')
    if (-not $m.Success) { return $null }
    $opts = ConvertFrom-QemuOpts $m.Groups[1].Value
    $p2 = if ($opts['p2']) { [int]$opts['p2'] } else { 4 }
    $p3 = if ($opts['p3']) { [int]$opts['p3'] } else { 4 }
    # One port per index, USB2 and USB3 at once: the max, not the sum.
    # Measured: p2=15,p3=15 numbered ports 1 to 15 and put the hub on 15.
    return @{ Text = $m.Value; Opts = $opts; Ports = [Math]::Max($p2, $p3) }
}

function Set-DomainUsbPorts {
    param([string[]]$Arguments)
    if ($Arguments.Count -lt 1 -or $Arguments.Count -gt 2) { Usage (Get-UsbUsage) 1 }
    $vm = $Arguments[0]
    Assert-Domain $vm
    $x = Get-LauncherXhci $vm
    if (-not $x) {
        if ((Get-DomainLauncherText $vm) -match '(?m)^\s*-usb\b') {
            Die "$vm has the winxp profile's UHCI controller: two ports, fixed, and XP has no xHCI driver to give it more."
        }
        Die "$vm's launcher has no -device qemu-xhci to give ports to"
    }

    if ($Arguments.Count -eq 1) {
        $boot = @(Get-LauncherQemuLines $vm | Where-Object { $_.Flag -eq 'device' -and $_.Opts[''] -like 'usb-*' } |
                  ForEach-Object { if ($_.Opts['id']) { $_.Opts['id'] } else { $_.Opts[''] } })
        [Console]::Out.WriteLine("$vm`: $($x.Ports) xHCI root ports")
        [Console]::Out.WriteLine("  qemu chains a full-speed hub onto the last free one, so $($x.Ports - 1) devices fit on root ports")
        [Console]::Out.WriteLine("  the launcher plugs $($boot.Count) at boot: $($boot -join ', ')")
        if (Test-DomainRunning $vm) {
            $devs = @((Invoke-UsbMonitor $vm 'info usb') -split "`r?`n" | Where-Object { $_ -match '^\s*Device ' })
            $hub = @($devs | Where-Object { $_ -match 'Port \d+\.' }).Count
            $root = @($devs | Where-Object { $_ -match 'Port \d+,' -and $_ -notmatch 'USB Hub' }).Count
            [Console]::Out.WriteLine("  live: $root on root ports, $hub behind a hub")
        }
        if ($x.Ports -lt $script:UsbRootPorts) {
            [Console]::Out.WriteLine("  more, at the next start: virutil usb ports $vm $($script:UsbRootPorts)")
        }
        return
    }

    $n = 0
    if (-not [int]::TryParse($Arguments[1], [ref]$n) -or $n -lt 1 -or $n -gt 15) {
        Die "virutil usb ports: N is 1 to 15 (qemu-xhci's own limit), got '$($Arguments[1])'"
    }
    if (Test-DomainRunning $vm) {
        Die "$vm is running. Root ports are the controller's and change at a start: shut it down, then run this again."
    }
    $opts = $x.Opts
    $opts['p2'] = "$n"; $opts['p3'] = "$n"
    $spec = @($opts.Keys | ForEach-Object { if ($_ -eq '') { $opts[$_] } else { "$_=$(ConvertTo-QemuOptValue $opts[$_])" } }) -join ','
    $path = Get-DomainLauncher $vm
    $text = Get-Content -LiteralPath $path -Raw
    Set-Content -LiteralPath $path -Value $text.Replace($x.Text, "-device `"$spec`"") -Encoding ASCII -NoNewline
    Say "$vm`: $n xHCI root ports from its next start (was $($x.Ports)); the guest enumerates the new ones once"
}

# --- a blank stick ------------------------------------------------------------

# Get-UsbImageSize '64M' -- bytes. A whole number of MiB, so the partition
# below lands on its 1 MiB boundary and the image is whole sectors.
function Get-UsbImageSize {
    param([string]$Text)
    $m = [regex]::Match($Text, '^(\d+)([KMGT])(i?B)?$', 'IgnoreCase')
    if (-not $m.Success) { Die "SIZE is a number and a unit, like 64M or 2G; got '$Text'" }
    $mult = @{ K = 1KB; M = 1MB; G = 1GB; T = 1TB }[$m.Groups[2].Value.ToUpperInvariant()]
    $bytes = [int64]$m.Groups[1].Value * $mult
    if ($bytes -lt 2MB -or $bytes % 1MB -ne 0) { Die "SIZE must be a whole number of MiB, at least 2M; got '$Text'" }
    return $bytes
}

# The FAT32 layout of a BYTES image holding one partition at 1 MiB, as
# Microsoft's FAT spec lays it out: 32 reserved sectors, two FATs, the root
# directory at cluster 2, the cluster size from the volume's size. $null when
# the volume is too small to be FAT32 at all (under 65525 clusters).
function Get-Fat32Layout {
    param([int64]$Bytes)
    $start = 2048
    $sectors = [int64]($Bytes / 512) - $start
    $volume = $sectors * 512
    $spc = if     ($volume -le 64MB)  { 1 }
           elseif ($volume -le 128MB) { 2 }
           elseif ($volume -le 256MB) { 4 }
           elseif ($volume -le 8GB)   { 8 }
           elseif ($volume -le 16GB)  { 16 }
           elseif ($volume -le 32GB)  { 32 }
           else                       { 64 }
    $reserved = 32
    # The spec's own FATSz computation, which may overshoot by a sector or two
    # and never undershoots.
    $per = [int64]((256 * $spc + 2) / 2)
    $fatSize = [int64][Math]::Floor(($sectors - $reserved + $per - 1) / $per)
    $clusters = [int64][Math]::Floor(($sectors - $reserved - 2 * $fatSize) / $spc)
    if ($clusters -lt 65525) { return $null }
    return @{
        Start = $start; Sectors = $sectors; SectorsPerCluster = $spc; Reserved = $reserved
        FatSize = $fatSize; Clusters = $clusters; RootSector = $reserved + 2 * $fatSize
    }
}

# Write-Fat32Image PATH BYTES LABEL -- an MBR with one FAT32 (LBA) partition,
# and that partition formatted: boot sector and FSInfo with their backups at 6
# and 7, both FATs' first three entries, and the label in the root directory.
# Everything else is the zeros the image already holds, which is what an empty
# FAT and an empty directory are.
function Write-Fat32Image {
    param([string]$Path, [int64]$Bytes, [string]$Label)
    $l = Get-Fat32Layout $Bytes
    $rng = [Random]::new()
    $labelBytes = [Text.Encoding]::ASCII.GetBytes($(if ($Label) { $Label } else { 'NO NAME' }).PadRight(11))
    function Put32 { param([byte[]]$To, [int]$At, [int64]$Value) [BitConverter]::GetBytes([uint32]$Value).CopyTo($To, $At) }
    function Put16 { param([byte[]]$To, [int]$At, [int64]$Value) [BitConverter]::GetBytes([uint16]$Value).CopyTo($To, $At) }

    $mbr = New-Object byte[] 512
    Put32 $mbr 0x1B8 $rng.Next()                            # disk signature
    $e = 0x1BE
    # CHS fields at their maximum, so a reader goes by the LBA ones; 0C is
    # FAT32 with LBA.
    $mbr[$e + 1] = 0xFE; $mbr[$e + 2] = 0xFF; $mbr[$e + 3] = 0xFF
    $mbr[$e + 4] = 0x0C
    $mbr[$e + 5] = 0xFE; $mbr[$e + 6] = 0xFF; $mbr[$e + 7] = 0xFF
    Put32 $mbr ($e + 8) $l.Start
    Put32 $mbr ($e + 12) $l.Sectors
    $mbr[510] = 0x55; $mbr[511] = 0xAA

    $boot = New-Object byte[] 512
    $boot[0] = 0xEB; $boot[1] = 0x58; $boot[2] = 0x90
    [Text.Encoding]::ASCII.GetBytes('MSWIN4.1').CopyTo($boot, 3)
    Put16 $boot 11 512
    $boot[13] = [byte]$l.SectorsPerCluster
    Put16 $boot 14 $l.Reserved
    $boot[16] = 2                                           # FATs
    $boot[21] = 0xF8                                        # fixed media
    Put16 $boot 24 63
    Put16 $boot 26 255
    Put32 $boot 28 $l.Start                                 # hidden sectors
    Put32 $boot 32 $l.Sectors
    Put32 $boot 36 $l.FatSize
    Put32 $boot 44 2                                        # root cluster
    Put16 $boot 48 1                                        # FSInfo sector
    Put16 $boot 50 6                                        # backup boot sector
    $boot[64] = 0x80; $boot[66] = 0x29
    Put32 $boot 67 $rng.Next()                              # volume serial
    $labelBytes.CopyTo($boot, 71)
    [Text.Encoding]::ASCII.GetBytes('FAT32   ').CopyTo($boot, 82)
    $boot[510] = 0x55; $boot[511] = 0xAA

    $info = New-Object byte[] 512
    Put32 $info 0 0x41615252
    Put32 $info 484 0x61417272
    Put32 $info 488 ($l.Clusters - 1)                       # free: all but the root's
    Put32 $info 492 3                                       # next free
    Put32 $info 508 0xAA550000L                             # L: as int32 it is negative

    # FAT[0] the media byte, FAT[1] the clean-shutdown end mark, FAT[2] the
    # root directory's one cluster, ending there.
    $fat = New-Object byte[] 12
    Put32 $fat 0 0x0FFFFFF8
    Put32 $fat 4 0x0FFFFFFF
    Put32 $fat 8 0x0FFFFFFF

    $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
    try {
        $put = {
            param([int64]$Sector, [byte[]]$Data)
            [void]$fs.Seek($Sector * 512, 'Begin')
            $fs.Write($Data, 0, $Data.Length)
        }
        $v = [int64]$l.Start
        & $put 0 $mbr
        & $put $v $boot
        & $put ($v + 1) $info
        & $put ($v + 6) $boot
        & $put ($v + 7) $info
        & $put ($v + $l.Reserved) $fat
        & $put ($v + $l.Reserved + $l.FatSize) $fat
        if ($Label) {
            $entry = New-Object byte[] 32
            $labelBytes.CopyTo($entry, 0)
            $entry[11] = 0x08                               # ATTR_VOLUME_ID
            & $put ($v + $l.RootSector) $entry
        }
    } finally {
        $fs.Close()
    }
}

function New-UsbStickImage {
    param([string[]]$Arguments)
    $file = $null; $size = $null; $fsType = 'none'; $label = $null
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = $Arguments[$i]
        if     ($a -eq '--fs')    { $i++; $fsType = (Get-UsbFlagValue $Arguments $i $a).ToLowerInvariant() }
        elseif ($a -eq '--label') { $i++; $label  = Get-UsbFlagValue $Arguments $i $a }
        elseif ($a.StartsWith('-')) { Die "virutil usb image: $a is not a flag this driver has (see: virutil usb -h)" }
        elseif ($null -eq $file) { $file = $a }
        elseif ($null -eq $size) { $size = $a }
        else { Usage (Get-UsbUsage) 1 }
    }
    if (-not $size) { Usage (Get-UsbUsage) 1 }
    $bytes = Get-UsbImageSize $size
    if ($fsType -notin @('none', 'fat32')) {
        Die "--fs is fat32, or leave it out for a blank image the guest formats (NTFS, exFAT: Format-Volume there); got '$fsType'"
    }
    if ($label) {
        if ($fsType -ne 'fat32') { Die '--label needs --fs fat32: a blank image has no volume to label' }
        $label = $label.ToUpperInvariant()
        if ($label -notmatch '^[A-Z0-9 _-]{1,11}$') { Die "--label is 1 to 11 letters, digits, space, _ or -; got '$label'" }
    }
    if ($fsType -eq 'fat32' -and -not (Get-Fat32Layout $bytes)) {
        Die "$size is too small for FAT32, which needs 65525 clusters: 34M is the least. Leave out --fs, or make it bigger."
    }
    $path = [IO.Path]::GetFullPath($file, (Get-Location).ProviderPath)
    if (Test-Path -LiteralPath $path) { Die "$path already exists, and image never writes over a file" }
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { Die "no such folder: $parent" }

    # Sparse, so a 16G stick costs what is written to it. fsutil does that for
    # the file's owner with no elevation; if it cannot, the image is merely
    # full-size on disk.
    $fs = [IO.File]::Open($path, 'CreateNew', 'ReadWrite', 'None')
    $fs.Close()
    & fsutil.exe sparse setflag $path *> $null
    if ($LASTEXITCODE -ne 0) { Warn "could not mark $path sparse, so it takes its full $size on disk" }
    $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
    try { $fs.SetLength($bytes) } finally { $fs.Close() }

    if ($fsType -eq 'fat32') {
        Write-Fat32Image $path $bytes $label
        $l = if ($label) { " labelled $label" } else { '' }
        Say "created $path`: $size, one FAT32 partition$l"
    } else {
        Say "created $path`: $size, blank -- the guest partitions and formats it"
    }
    $path
}
