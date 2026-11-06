<#
.SYNOPSIS
  A passed-through device is a line in the launcher: check the round trip. Then
  emulated sticks, in the launcher and in a real qemu.

.DESCRIPTION
  modules/win/usb.ps1 persists an attach by writing a -device usb-host argument
  into the per-VM .cmd, and reads it back out with a regex. That makes the
  launcher a parsing contract, the same one tests/win/domain.ps1 holds for the
  monitor port and the port forwards -- and the edit has one more thing to get
  right than a forward does: it inserts a whole new argument, which must land
  inside the continuation rather than after the line that ends it.

  An emulated stick persisted with `plug --persist` is the same kind of edit,
  two or three lines at once, and `ports` rewrites the controller's line; both
  are checked the same way, with no qemu. So are `image`'s FAT32 layout and
  the bytes it writes.

  Then a real qemu -- paused, no disk, no guest, the default 4 root ports -- is
  plugged into over its monitor: an image stick, a folder stick and a disk with
  its own SCSI strings; the third lands behind qemu's hub and says so; cycle
  replugs without leaking a drive; unplug frees the backend; a refused plug
  leaves nothing behind. That half skips itself when no qemu is installed.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'modules\win'

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
function CheckTrue { param([string]$Name, $Got) Check $Name $true ([bool]$Got) }

# Dies BODY -- the message and the exit code a thrown virutil error carries, or
# an empty message and $null if BODY returned. As in tests/win/shot.ps1.
function Dies {
    param([scriptblock]$Body)
    try { & $Body | Out-Null; return @{ Msg = ''; Code = $null } }
    catch {
        $e = $_.Exception
        $code = if ($e.Data -and $e.Data.Contains('VirutilCode')) { [int]$e.Data['VirutilCode'] } else { $null }
        return @{ Msg = $e.Message; Code = $code }
    }
}

# Quiet BODY -- run it with stdout and stderr captured; returns @{ Out; Text },
# Out being what BODY returned and Text what it printed.
function Quiet {
    param([scriptblock]$Body)
    $outOrig = [Console]::Out; $errOrig = [Console]::Error
    $buf = New-Object IO.StringWriter
    [Console]::SetOut($buf); [Console]::SetError($buf)
    try { $r = & $Body } finally { [Console]::SetOut($outOrig); [Console]::SetError($errOrig) }
    return @{ Out = $r; Text = $buf.ToString() }
}

$qemuProc = $null

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

    # --- emulated sticks: the launcher -----------------------------------------

    # Fifteen root ports from create, so the hub never comes before the
    # fourteenth device.
    Check 'create gives xhci 15 ports'      15 (Get-LauncherXhci $vm).Ports

    $o = ConvertFrom-QemuOpts 'usb-storage,drive=d0,file=C:\a,,b\c.img,serial=X'
    Check 'the device type is the bare word' 'usb-storage' $o['']
    Check 'a doubled comma is a comma'      'C:\a,b\c.img' $o['file']
    Check 'and the next option still reads' 'X' $o['serial']
    Check 'an HMP argument is quoted, \ doubled' '"C:\\a b\\c"' (ConvertTo-HmpString 'C:\a b\c')

    # win11's own hand-written stick, exactly as its launcher has it: a drive
    # id that is not ID-drv, bus= named, cache= given.
    $path = Get-DomainLauncher $vm
    $hand = @(
        '    -drive "file=C:\Users\x\.virutils\images\win11-usb.qcow2,if=none,id=usbdrv0,format=qcow2,cache=writeback" ^'
        '    -device "usb-storage,bus=xhci.0,drive=usbdrv0,id=usbstick0,serial=MDEVUSBWIN11,removable=on" ^'
    ) -join "`r`n"
    $t = Get-Content -LiteralPath $path -Raw
    Set-Content -LiteralPath $path -Encoding ASCII -NoNewline -Value ([regex]::Replace($t, '(?m)^ *-monitor ', "$hand`r`n    -monitor ", 1))
    $sticks = @(Get-LauncherUsbStorage $vm)
    Check 'a hand-written stick reads back' 'usbstick0' ($sticks | ForEach-Object { $_.Id })
    Check '  with its own drive'            'usbdrv0' $sticks[0].Drive
    Check '  its image and format'          'C:\Users\x\.virutils\images\win11-usb.qcow2 (qcow2)' (Get-UsbStorageBacking $sticks[0])
    Check '  and its serial'                'MDEVUSBWIN11' $sticks[0].Serial

    $before = Get-DomainLauncherText $vm
    $img = New-UsbStorageSpec
    $img.Id = 'stick0'; $img.Drive = 'stick0-drv'; $img.Serial = 'STICK0'
    $img.Image = 'C:\img dir\a,b.img'; $img.Format = 'raw'
    $folder = New-UsbStorageSpec
    $folder.Id = 'seed'; $folder.Drive = 'seed-drv'; $folder.Serial = 'SEED'; $folder.Dir = 'C:\seed'; $folder.Label = 'SEEDED'
    $disk = New-UsbStorageSpec
    $disk.Id = 'evil'; $disk.Drive = 'evil-drv'; $disk.Serial = 'EVIL01'; $disk.Kind = 'disk'
    $disk.Image = 'C:\e.qcow2'; $disk.Format = 'qcow2'; $disk.Vendor = 'OPSWAT'; $disk.Product = 'EVIL STICK'; $disk.Rev = '6.66'
    foreach ($s in $img, $folder, $disk) { Add-LauncherUsbStorage $vm $s }

    $back = @{}
    foreach ($s in Get-LauncherUsbStorage $vm) { $back[$s.Id] = $s }
    Check 'three plugs persist beside it'   'evil seed stick0 usbstick0' (($back.Keys | Sort-Object) -join ' ')
    Check '  an image path with a comma'    'C:\img dir\a,b.img (raw)' (Get-UsbStorageBacking $back['stick0'])
    Check '  a folder, read-only, labelled' 'C:\seed (folder, read-only, label SEEDED)' (Get-UsbStorageBacking $back['seed'])
    Check '  a disk keeps its SCSI strings' 'disk OPSWAT/EVIL STICK/6.66' ('{0} {1}/{2}/{3}' -f $back['evil'].Kind, $back['evil'].Vendor, $back['evil'].Product, $back['evil'].Rev)
    Check '  three lines for the disk'      3 $back['evil'].Lines.Count
    $text = Get-DomainLauncherText $vm
    Check 'the monitor survives them'       44444 (Get-DomainMonitorPort $vm)
    CheckTrue 'the lines are inside the run' ($text -match '(?m)^ *-device "scsi-hd,bus=evil\.0[^\r\n]*\^\r?\n *-monitor ')
    CheckTrue 'the passthrough is untouched' ((Get-DomainUsbIds $vm) -contains '8087:0033')

    foreach ($id in 'stick0', 'seed', 'evil') { Remove-LauncherUsbStorage $vm $back[$id] }
    Check 'removing them gives the file back' $before (Get-DomainLauncherText $vm)

    $r = Dies { Add-LauncherUsbStorage $vm (& { $x = New-UsbStorageSpec; $x.Id = 'p'; $x.Drive = 'p-drv'; $x.Image = 'C:\100%\a.img'; $x.Format = 'raw'; $x }) }
    CheckTrue 'a % path is refused for the launcher' ($r.Msg -match 'expands %')

    # --- emulated sticks: root ports and images ---------------------------------

    $xp = 'xpvm'
    Set-Content -LiteralPath (Get-DomainLauncher $xp) -Encoding ASCII -Value @(
        '@echo off', 'start /b "" "q.exe" ^', '    -usb  ^', '    -device usb-tablet ^', '    -monitor "tcp:127.0.0.1:44445,server,nowait"')
    $r = Dies { Set-DomainUsbPorts @($xp, '15') }
    CheckTrue 'a UHCI launcher is refused by name' ($r.Msg -match 'UHCI')

    $old = 'oldvm'
    Set-Content -LiteralPath (Get-DomainLauncher $old) -Encoding ASCII -Value @(
        '@echo off', 'start /b "" "q.exe" ^', '    -device "qemu-xhci,id=xhci" ^', '    -device usb-tablet ^',
        '    -monitor "tcp:127.0.0.1:44446,server,nowait"')
    Check 'an old launcher has 4 ports'     4 (Get-LauncherXhci $old).Ports
    $shown = (Quiet { Set-DomainUsbPorts @($old) }).Text
    CheckTrue '  and ports says how to get 15' ($shown -match "virutil usb ports $old 15")
    $null = Quiet { Set-DomainUsbPorts @($old, '15') }
    Check 'ports N rewrites the controller' 15 (Get-LauncherXhci $old).Ports
    CheckTrue '  as one quoted -device'     ((Get-DomainLauncherText $old) -match '(?m)^    -device "qemu-xhci,id=xhci,p2=15,p3=15" \^\r?$')
    Check '16 ports is refused'             1 (Dies { Set-DomainUsbPorts @($old, '16') }).Code

    Check 'a 64M FAT32 has 512 B clusters'  1 (Get-Fat32Layout 64MB).SectorsPerCluster
    Check 'a 2G FAT32 has 4 KiB clusters'   8 (Get-Fat32Layout 2GB).SectorsPerCluster
    CheckTrue '33M is too small for FAT32'  ($null -eq (Get-Fat32Layout 33MB))
    CheckTrue '34M is enough'               ($null -ne (Get-Fat32Layout 34MB))
    Check 'a size needs a unit'             1 (Dies { Get-UsbImageSize '64' }).Code

    $imgDir = Join-Path $env:VIRUTILS_DIR 'img'
    New-VirutilsDir $imgDir | Out-Null
    $fat = Join-Path $imgDir 'fat.img'
    $q = Quiet { New-UsbStickImage @($fat, '64M', '--fs', 'fat32', '--label', 'tests') }
    Check 'image prints the path'           $fat $q.Out
    Check '  of exactly SIZE'               64MB (Get-Item -LiteralPath $fat).Length
    $b = [IO.File]::ReadAllBytes($fat)
    Check '  an MBR with a FAT32 LBA entry' '12 2048' ('{0} {1}' -f $b[0x1C2], [BitConverter]::ToUInt32($b, 0x1C6))
    $v = 2048 * 512
    Check '  a FAT32 boot sector there'     'FAT32   ' ([Text.Encoding]::ASCII.GetString($b, $v + 82, 8))
    Check '  labelled'                      'TESTS      ' ([Text.Encoding]::ASCII.GetString($b, $v + 71, 11))
    Check '  its backup at sector 6'        ([Convert]::ToBase64String($b, $v, 512)) ([Convert]::ToBase64String($b, $v + 6 * 512, 512))
    Check '  FSInfo signed'                 '1096897106 2857697280' ('{0} {1}' -f [BitConverter]::ToUInt32($b, $v + 512), [BitConverter]::ToUInt32($b, $v + 512 + 508))
    $l = Get-Fat32Layout 64MB
    Check '  the root cluster ends'         268435455 ([BitConverter]::ToUInt32($b, $v + $l.Reserved * 512 + 8))
    Check '  the label in the root dir'     'TESTS      ' ([Text.Encoding]::ASCII.GetString($b, $v + $l.RootSector * 512, 11))
    $r = Dies { Quiet { New-UsbStickImage @($fat, '64M') } }
    CheckTrue 'image never overwrites'      ($r.Msg -match 'already exists')

    # --- emulated sticks: a real qemu -----------------------------------------

    $qemuDir = @(
        (Join-Path $env:USERPROFILE 'scoop\apps\qemu\current')
        'C:\Program Files\qemu'
    ) | Where-Object { Test-Path (Join-Path $_ 'qemu-system-x86_64.exe') } | Select-Object -First 1
    if (-not $qemuDir) {
        [Console]::Out.WriteLine('skip     a real qemu: none installed')
    } else {
        $live = 'livevm'
        $port = Get-FreeLoopbackPort
        Set-Content -LiteralPath (Get-DomainLauncher $live) -Encoding ASCII -Value @(
            '@echo off', 'start /b "" "q.exe" ^', '    -device "qemu-xhci,id=xhci" ^', '    -device usb-tablet ^',
            "    -monitor `"tcp:127.0.0.1:$port,server,nowait`"")
        # The launcher's machine, run by hand: -S, so no vcpu runs and there is
        # no guest -- only the bus, which is all a plug needs.
        $qemuProc = Start-Process -FilePath (Join-Path $qemuDir 'qemu-system-x86_64.exe') -PassThru -WindowStyle Hidden `
            -ArgumentList '-nodefaults', '-machine', 'q35', '-display', 'none', '-S',
                          '-device', 'qemu-xhci,id=xhci', '-device', 'usb-tablet',
                          '-monitor', "tcp:127.0.0.1:$port,server,nowait"
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-DomainRunning $live) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        CheckTrue 'the throwaway qemu answers'  (Test-DomainRunning $live)

        $seed = Join-Path $imgDir 'seed dir'
        New-VirutilsDir $seed | Out-Null
        Set-Content -LiteralPath (Join-Path $seed 'readme.txt') -Value 'from the host'
        $evil = Join-Path $imgDir 'evil.img'
        $null = Quiet { New-UsbStickImage @($evil, '16M') }
        function Get-Block { Invoke-UsbMonitor $live 'info block' }

        $q = Quiet { Add-DomainUsbStorage @($live, '--image', $fat) }
        Check 'plug prints the id it chose'     'stick0' $q.Out
        $q = Quiet { Add-DomainUsbStorage @($live, '--dir', $seed, '--label', 'SEEDED', '--id', 'seed') }
        Check 'a folder plugs under its --id'   'seed' $q.Out
        $q = Quiet { Add-DomainUsbStorage @($live, '--image', $evil, '--id', 'evil', '--vendor', 'OPSWAT', '--product', 'EVIL STICK', '--rev', '6.66') }
        Check 'a disk plugs'                    'evil' $q.Out
        # tablet, stick0, seed: the default 4 ports have one left, and qemu
        # spends it on a hub.
        CheckTrue '  behind the hub, and says so' ($q.Text -match 'behind the full-speed hub' -and $q.Text -match "usb ports $live 15")

        $sticks = @{}
        foreach ($s in Get-LiveUsbStorage $live) { $sticks[$s.Id] = $s }
        Check 'qemu has all three'              'evil seed stick0' (($sticks.Keys | Sort-Object) -join ' ')
        Check '  an image on a root port'       '2 STICK0 raw' ('{0} {1} {2}' -f $sticks['stick0'].Port, $sticks['stick0'].Serial, $sticks['stick0'].Format)
        Check '  read back as the file'         $fat $sticks['stick0'].Image
        Check '  a folder, labelled'            "$seed SEEDED" ('{0} {1}' -f $sticks['seed'].Dir, $sticks['seed'].Label)
        Check '  the disk attached, on the hub' 'True OPSWAT/EVIL STICK/6.66' ('{0} {1}/{2}/{3}' -f $sticks['evil'].Port.Contains('.'), $sticks['evil'].Vendor, $sticks['evil'].Product, $sticks['evil'].Rev)
        $shown = (Quiet { Show-DomainUsb @($live) }).Text
        CheckTrue 'show has a row per stick'    ($shown -match '(?m)^  evil +disk +port \d+\.1 +serial EVIL +.*evil\.img \(raw\)  \[scsi OPSWAT/EVIL STICK/6\.66; behind')

        Check 'a second stick0 is refused'      1 (Dies { Quiet { Add-DomainUsbStorage @($live, '--image', $fat, '--id', 'stick0') } }).Code
        # qemu here takes no lock on an image, so the same file twice is
        # refused before it gets that far.
        $r = Dies { Quiet { Add-DomainUsbStorage @($live, '--image', $fat, '--id', 'twice') } }
        CheckTrue 'an image already plugged is refused' ($r.Msg -match 'already livevm''s stick stick0')
        # A backend qemu cannot open -- qcow2's magic and then nothing a qcow2
        # header should be: the drive_add fails, and nothing is left.
        $held = Join-Path $imgDir 'held.qcow2'
        [IO.File]::WriteAllBytes($held, [byte[]](@(0x51, 0x46, 0x49, 0xFB) + @(0xFF) * 508))
        $r = Dies { Quiet { Add-DomainUsbStorage @($live, '--image', $held, '--id', 'held') } }
        CheckTrue 'an image qemu cannot open is refused' ($r.Msg -match 'would not open the backend')
        CheckTrue '  and leaves no drive behind' ((Get-Block) -notmatch 'held-drv')
        CheckTrue '  and no device'             ((Invoke-UsbMonitor $live 'info usb') -notmatch 'ID: held')

        $q = Quiet { Invoke-UsbStorageCycle @($live, 'seed', '-n', '3', '--off', '0', '--on', '0') }
        Check 'cycle says each cycle'           3 ([regex]::Matches($q.Text, 'cycle \d/3').Count)
        Check '  and leaves it plugged'         1 @(Get-LiveUsbStorage $live | Where-Object { $_.Id -eq 'seed' -and $_.Port }).Count
        Check '  on one drive, not four'        1 ([regex]::Matches((Get-Block), '(?m)^seed-drv ').Count)
        $q = Quiet { Invoke-UsbStorageCycle @($live, 'evil', '--off', '0') }
        Check 'a disk cycles, attached again'   1 @(Get-LiveUsbStorage $live | Where-Object { $_.Id -eq 'evil' -and $_.Port }).Count

        $null = Quiet { Remove-DomainUsbStorage @($live, 'stick0') }
        CheckTrue 'unplug takes it off the bus' ((Invoke-UsbMonitor $live 'info usb') -notmatch 'ID: stick0')
        CheckTrue '  and frees its drive'       ((Get-Block) -notmatch 'stick0-drv')
        Check 'unplug of no such stick exits 1' 1 (Dies { Quiet { Remove-DomainUsbStorage @($live, 'stick0') } }).Code

        # --persist on a running domain: both halves, and unplug alone leaves
        # the launcher's.
        $null = Quiet { Add-DomainUsbStorage @($live, '--image', $fat, '--id', 'kept', '--persist') }
        Check 'plug --persist writes the launcher' 'kept' (@(Get-LauncherUsbStorage $live) | ForEach-Object { $_.Id })
        $q = Quiet { Remove-DomainUsbStorage @($live, 'kept') }
        CheckTrue 'unplug alone says it comes back' ($q.Text -match 'comes back at the next boot')
        Check '  and keeps it there'            1 @(Get-LauncherUsbStorage $live).Count
        $null = Quiet { Remove-DomainUsbStorage @($live, 'kept', '--persist') }
        Check 'unplug --persist takes it out'   0 @(Get-LauncherUsbStorage $live).Count

        Check 'ports N is refused while running' 1 (Dies { Set-DomainUsbPorts @($live, '15') }).Code
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
