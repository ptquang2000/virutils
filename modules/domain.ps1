# domain -- the domain lifecycle, on a Windows host running QEMU natively.
#
# There is no libvirt here, so there is no domain to define. `create` writes the
# disk, the UEFI nvram and a per-VM `.cmd` launcher holding every qemu argument,
# frozen; **the launcher is the domain**. Everything else in this file reads it
# back: `list` is the launchers in the image directory, `start` runs one,
# `shutdown` and `port` go over the QEMU monitor the launcher opened.
#
# That is one file per domain and no second record to drift out of step with it.
# The alternative -- a JSON sidecar naming the monitor port and the forwards --
# would be a state file that can disagree with the machine it describes, and the
# launcher already holds every one of those facts because qemu needs them.
#
# Four settings differ from the Linux driver, each measured on this host rather
# than assumed. They are not preferences and must not be "fixed" back toward the
# Linux original; see docs/contract.md section 9. Each is written out below with
# what it was measured against, because this comment is now the only record of
# it -- the bisect that found them was in a handoff note that is gone.
#
#   -cpu Skylake-Client, not host-passthrough. Under WHPX both `host` and `max`
#   hang OVMF in CpuMpPei, before any display output; every named model boots.
#   Skylake-Client is the oldest one carrying the SSE4.2, POPCNT and AES that
#   Windows 11 requires.
#
#   threads=1. An SMT topology hangs MP init the same way, at any vcpu count.
#
#   cache=writeback, not cache=none. On Windows cache=none opens the image
#   unbuffered and qemu then cannot read its own qcow2 header back: "Image is
#   not in qcow2 format".
#
#   -vga std, not virtio. Windows Setup has no virtio-gpu driver, and under WHPX
#   virtio-vga never brought the display up at all.

$script:DomainCpu = 'Skylake-Client'

function Get-DomainUsage {
    @(
        'usage: virutil domain create VM ISO [OPTIONS]'
        '       virutil domain delete VM'
        '       virutil domain list'
        '       virutil domain start    VM [-G]'
        '       virutil domain shutdown VM'
        '       virutil domain addr     VM'
        '       virutil domain port     VM [SPEC] [-c PORT]'
        ''
        'port options (SPEC is PORT, or HOSTPORT:GUESTPORT when the two differ;'
        'with no SPEC it lists the open forwards for VM):'
        '  -c, --close PORT  close the forward on host PORT'
        ''
        'create options:'
        '  -s, --size GiB    disk size (default 64)'
        "  -m, --memory MiB  guest RAM (default: half the host's)"
        "  -c, --vcpus N     virtual CPUs (default: half the host's, max 8)"
        '  -o, --osinfo ID   accepted and ignored: there is no libosinfo here'
        '  -v, --virtio ISO  virtio-win ISO to attach as a second cdrom, or'
        '                    "none" (default: found beside ISO)'
        '  -p, --port SPEC   a port forward, repeatable (default 13389:3389)'
        '  -N, --no-start    create it without starting it'
        ''
        "The disk is always $($script:VirutilsImageDir)\VM.qcow2;"
        'VIRUTILS_IMAGE_DIR moves it.'
        ''
        'start options:'
        '  -G, --no-gui      not honoured here: qemu under WHPX has no headless'
        '                    console to detach from, and -display none would'
        '                    leave the guest with no way in at all'
        ''
        'delete takes no options. It never asks, and it removes the disk, the'
        "nvram and the launcher. There is no backing chain to walk: snapshot"
        'is not ported to this driver yet.'
        ''
        '  -h, --help        this message'
        ''
        'create reads these from the environment:'
        "  VIRUTILS_DIR           $($script:VirutilsRoot)"
        "  VIRUTILS_IMAGE_DIR     $($script:VirutilsImageDir)"
        '  VIRUTILS_VIRTIO        (auto)       virtio-win ISO path, or "none"'
        ''
        'VIRUTILS_OSINFO, VIRUTILS_NETWORK and VIRUTILS_FIRMWARE are in the'
        'contract but have no meaning on this host: there is no libosinfo, no'
        'libvirt network, and WHPX will not boot Windows 11 without UEFI.'
        ''
        'The same names spelled with the singular VIRUTIL_ prefix are still'
        'read, second, and say so once when they are.'
    )
}

function Domain-Main {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { Usage (Get-DomainUsage) 1 }
    $cmd = $Arguments[0]
    if ($cmd -in @('-h', '--help')) { Usage (Get-DomainUsage) 0 }

    $rest = Get-RestArgs $Arguments 1

    switch ($cmd) {
        'create'   { New-Domain      $rest }
        'delete'   { Remove-Domain   $rest }
        'list'     { Show-DomainList $rest }
        'start'    { Start-Domain    $rest }
        'shutdown' { Stop-Domain     $rest }
        'addr'     { Show-DomainAddr $rest }
        'port'     { Set-DomainPort  $rest }
        default    { Die "virutil domain: unknown command: $cmd (see: virutil domain -h)" }
    }
}

# Write-IgnoredEnvWarnings -- say so when a contract variable this host cannot
# act on has actually been set.
#
# Section 4 of the contract says a variable in its table must be *accepted* by
# both drivers, not that both can act on it, and that this driver "reads them,
# says they are ignored, and carries on". Saying it is the part that is easy to
# leave out: three variables read into three fields nothing consults is
# indistinguishable, from outside, from a driver that honoured them.
#
# Only a value that came from the environment is worth a line. The defaults are
# this file's own and warning about them would be warning about nothing.
function Write-IgnoredEnvWarnings {
    foreach ($name in @('OSINFO', 'NETWORK', 'FIRMWARE')) {
        $set = $null
        foreach ($spelling in @("VIRUTILS_$name", "VIRUTIL_$name")) {
            $v = [Environment]::GetEnvironmentVariable($spelling)
            if ($v) { $set = "$spelling=$v"; break }
        }
        if (-not $set) { continue }

        switch ($name) {
            'OSINFO' {
                Warn @("$set is set and is ignored here: there is no libosinfo"
                       'on this host and nothing consults an os id.')
            }
            'NETWORK' {
                Warn @("$set is set and is ignored here: there is no libvirt"
                       'network to name. The guest gets user-mode NAT, and the'
                       'only way in is a port forward -- see -p, and'
                       "'virutil domain port'.")
            }
            'FIRMWARE' {
                # Not merely ignored: asking for BIOS here asks for a machine
                # Windows 11 will not install on, so it is worth more than a
                # shrug.
                if ($script:VirutilsFirmware -eq 'bios') {
                    Warn @("$set is set and cannot be honoured here: this"
                           'driver builds a UEFI machine because Windows 11'
                           'will not install without one. Carrying on with'
                           'UEFI.')
                } else {
                    Warn "$set is set and is ignored here: UEFI is the only firmware this driver builds."
                }
            }
        }
    }
}

# Get-FlagValue ARGS INDEX FLAG -- the argument a flag takes, or a usage error
# naming the flag. Without this a trailing `-s` reads past the end of the array
# and, under StrictMode, fails as an index error that names no flag at all.
function Get-FlagValue {
    param([string[]]$Arguments, [int]$Index, [string]$Flag)
    if ($Index -ge $Arguments.Count) { Die "virutil domain: $Flag needs a value" }
    return $Arguments[$Index]
}

# --- where a domain lives ---------------------------------------------------

function Get-DomainDisk     { param([string]$Vm) Join-Path $script:VirutilsImageDir "$Vm.qcow2" }
function Get-DomainNvram    { param([string]$Vm) Join-Path $script:VirutilsImageDir "${Vm}_VARS.fd" }
function Get-DomainLauncher { param([string]$Vm) Join-Path $script:VirutilsImageDir "$Vm.cmd" }
function Get-DomainOvmfLog  { param([string]$Vm) Join-Path $script:VirutilsImageDir "$Vm-ovmf.log" }

function Test-Domain {
    param([string]$Vm)
    return (Test-Path -LiteralPath (Get-DomainLauncher $Vm))
}

function Assert-Domain {
    param([string]$Vm)
    if (-not $Vm) { Usage (Get-DomainUsage) 1 }
    if (-not (Test-Domain $Vm)) {
        Die "no such domain: $Vm (see: virutil domain list)"
    }
}

# --- reading the launcher back ----------------------------------------------
#
# The launcher is one `start "" "qemu.exe" ^` and the argument list, one flag
# per line. Everything below reads a fact back out of it rather than keeping a
# copy somewhere else.

function Get-DomainLauncherText {
    param([string]$Vm)
    return (Get-Content -LiteralPath (Get-DomainLauncher $Vm) -Raw)
}

# The TCP port the launcher told qemu to open its monitor on. Allocated once at
# create time and written into the launcher, so two domains never collide -- the
# fixed 55555 of the first draft meant the second VM's monitor silently failed
# to bind and every monitor command went to the first one.
function Get-DomainMonitorPort {
    param([string]$Vm)
    # The optional quote is not cosmetic: the launcher quotes any value holding
    # a comma, and this one always holds ",server,nowait".
    $m = [regex]::Match((Get-DomainLauncherText $Vm), '-monitor\s+"?tcp:127\.0\.0\.1:(\d+)')
    if (-not $m.Success) {
        Die @(
            "$Vm's launcher opens no QEMU monitor, so there is no handle on the"
            'running guest: shutdown and port both go over it. Recreate the'
            "domain, or add -monitor tcp:127.0.0.1:<port>,server,nowait to"
            "$(Get-DomainLauncher $Vm) by hand."
        )
    }
    return [int]$m.Groups[1].Value
}

# The forwards, as @{ Host = <int>; Guest = <int> }.
function Get-DomainForwards {
    param([string]$Vm)
    $out = @()
    foreach ($m in [regex]::Matches((Get-DomainLauncherText $Vm), 'hostfwd=tcp::(\d+)-:(\d+)')) {
        $out += @{ Host = [int]$m.Groups[1].Value; Guest = [int]$m.Groups[2].Value }
    }
    return $out
}

# --- the QEMU monitor -------------------------------------------------------
#
# The only handle on a running guest: sendkey, system_powerdown, hostfwd_add,
# hostfwd_remove. It answers on loopback and nowhere else.

# Invoke-DomainMonitor VM COMMAND -- send one line, return what came back, or
# $null when nothing is listening (which is how "not running" is told).
function Invoke-DomainMonitor {
    param([string]$Vm, [string]$Command, [int]$TimeoutMs = 2000)

    $port = Get-DomainMonitorPort $Vm
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $connect = $tcp.ConnectAsync('127.0.0.1', $port)
        if (-not $connect.Wait($TimeoutMs)) { return $null }
    } catch {
        return $null
    }
    try {
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $w = New-Object IO.StreamWriter($stream)
        $w.AutoFlush = $true
        $w.WriteLine($Command)

        # The monitor is a prompt, not a request/response protocol: it echoes a
        # banner, the command, and "(qemu)" again, with no framing to read to.
        # So this drains whatever arrives within the timeout and hands it back
        # for a caller to look through, rather than pretending to parse it.
        $buf = New-Object byte[] 8192
        $sb = New-Object Text.StringBuilder
        try {
            while ($true) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
            }
        } catch { }
        return $sb.ToString()
    } finally {
        $tcp.Close()
    }
}

# Test-DomainRunning VM -- is there a guest behind that monitor? Asked of the
# monitor rather than of the process table: a qemu whose monitor does not answer
# is not a domain anything here can drive, whatever the process list says.
function Test-DomainRunning {
    param([string]$Vm)
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $port = Get-DomainMonitorPort $Vm
        $connect = $tcp.ConnectAsync('127.0.0.1', $port)
        if (-not $connect.Wait(500)) { return $false }
        return $tcp.Connected
    } catch {
        return $false
    } finally {
        $tcp.Close()
    }
}

# --- list -------------------------------------------------------------------

function Show-DomainList {
    param([string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $script:VirutilsImageDir)) { return }

    $rows = @()
    foreach ($f in Get-ChildItem -LiteralPath $script:VirutilsImageDir -Filter '*.cmd' |
                   Sort-Object Name) {
        $vm = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $state = if (Test-DomainRunning $vm) { 'running' } else { 'shut off' }
        $rows += [pscustomobject]@{ Name = $vm; State = $state }
    }
    if ($rows.Count -eq 0) { return }

    # virsh's own shape, so the two drivers read alike.
    [Console]::Out.WriteLine((' {0,-24} {1}' -f 'Name', 'State'))
    [Console]::Out.WriteLine('-' * 40)
    foreach ($r in $rows) {
        [Console]::Out.WriteLine((' {0,-24} {1}' -f $r.Name, $r.State))
    }
}

# --- start / shutdown -------------------------------------------------------

function Start-Domain {
    param([string[]]$Arguments)
    $vm = $null
    foreach ($a in $Arguments) {
        if ($a -in @('-G', '--no-gui')) {
            Warn @(
                '-G is not honoured on this host: qemu under WHPX has no'
                'headless console to detach from, and -display none would leave'
                'the guest with no way in at all. Starting it with its display.'
            )
            continue
        }
        if ($a.StartsWith('-')) {
            Die @(
                "virutil domain start: $a is not a flag this driver has."
                '-s, -m and -c rewrite a libvirt domain config, and there is no'
                'domain config here -- the launcher is the domain. Edit'
                "$($script:VirutilsImageDir)\VM.cmd, or recreate it."
            )
        }
        if ($null -eq $vm) { $vm = $a } else { Usage (Get-DomainUsage) 1 }
    }
    Assert-Domain $vm

    if (Test-DomainRunning $vm) { Die "$vm is already running" }

    Start-Process -FilePath $env:ComSpec `
        -ArgumentList '/c', (Get-DomainLauncher $vm) -WindowStyle Hidden | Out-Null
    Say "$vm started"
}

function Stop-Domain {
    param([string[]]$Arguments)
    $vm = if ($Arguments.Count -ge 1) { $Arguments[0] } else { $null }
    Assert-Domain $vm

    if (-not (Test-DomainRunning $vm)) { Die "$vm is not running" }

    # ACPI, as `virsh shutdown` is: the guest is asked and shuts itself down.
    # A guest that ignores it stays up, which is the same thing that happens on
    # the other driver and for the same reason.
    Invoke-DomainMonitor $vm 'system_powerdown' | Out-Null
    Say "$vm is being shut down"
}

# --- addr -------------------------------------------------------------------

# This is the one command in the grammar with no answer on this host, and
# saying so is better than either failing or inventing one.
#
# Under user-mode NAT the guest's own address is 10.0.2.15 on a network slirp
# makes up inside the qemu process. Nothing on the host can route to it: the
# host is not on that network, and there is no bridge, tap or libvirt network
# that would put it there. What the host *does* have is the forwards, which are
# the only way in, so those are what this prints -- and it says plainly that the
# guest address is not reachable, rather than printing 10.0.2.15 and letting
# someone spend an afternoon pinging it.
function Show-DomainAddr {
    param([string[]]$Arguments)
    $vm = if ($Arguments.Count -ge 1) { $Arguments[0] } else { $null }
    Assert-Domain $vm

    $fwd = Get-DomainForwards $vm
    Warn @(
        "$vm is on user-mode NAT, so it has no address this host can reach."
        'Its own address is 10.0.2.15 on a network that exists only inside the'
        'qemu process; the host reaches it at 127.0.0.1 through the forwards'
        'below, and the guest reaches the host at 10.0.2.2. There is no'
        "equivalent of the bash driver's domifaddr here."
    )
    if ($fwd.Count -eq 0) {
        [Console]::Out.WriteLine('no forwards')
        return
    }
    foreach ($f in $fwd) {
        [Console]::Out.WriteLine(('127.0.0.1:{0} -> guest:{1}' -f $f.Host, $f.Guest))
    }
}

# --- port -------------------------------------------------------------------

# A forward is two things at once and both are kept in step: a live redirection
# in the running qemu, added or removed over the monitor, and a line in the
# launcher, so it is still there after the next boot. Doing only the first would
# lose the forward on reboot; doing only the second would not open it now.
function Set-DomainPort {
    param([string[]]$Arguments)

    $vm = $null; $spec = $null; $close = $null
    $i = 0
    while ($i -lt $Arguments.Count) {
        $a = $Arguments[$i]
        if ($a -in @('-c', '--close')) {
            $i++
            if ($i -ge $Arguments.Count) { Usage (Get-DomainUsage) 1 }
            $close = [int]$Arguments[$i]
        } elseif ($a -eq '-h' -or $a -eq '--help') {
            Usage (Get-DomainUsage) 0
        } elseif ($a.StartsWith('-')) {
            Die "virutil domain port: unknown flag: $a"
        } elseif ($null -eq $vm) {
            $vm = $a
        } elseif ($null -eq $spec) {
            $spec = $a
        } else {
            Usage (Get-DomainUsage) 1
        }
        $i++
    }
    Assert-Domain $vm

    if ($null -ne $close) { Close-DomainPort $vm $close; return }
    if ($null -eq $spec)  { Show-DomainPorts $vm; return }

    $parts = $spec.Split(':')
    $hostPort = [int]$parts[0]
    $guestPort = if ($parts.Count -gt 1) { [int]$parts[1] } else { $hostPort }

    if (Get-DomainForwards $vm | Where-Object { $_.Host -eq $hostPort }) {
        Die "$vm already forwards host port $hostPort (see: virutil domain port $vm)"
    }

    Add-LauncherForward $vm $hostPort $guestPort
    if (Test-DomainRunning $vm) {
        $reply = Invoke-DomainMonitor $vm "hostfwd_add tcp::${hostPort}-:${guestPort}"
        Assert-MonitorOk $reply "open $hostPort"
    }
    Say "$vm`: 127.0.0.1:$hostPort -> guest:$guestPort"
}

function Show-DomainPorts {
    param([string]$Vm)
    $fwd = Get-DomainForwards $Vm
    if ($fwd.Count -eq 0) { [Console]::Out.WriteLine('no forwards'); return }
    foreach ($f in $fwd) {
        [Console]::Out.WriteLine(('127.0.0.1:{0} -> guest:{1}' -f $f.Host, $f.Guest))
    }
}

function Close-DomainPort {
    param([string]$Vm, [int]$HostPort)
    $match = @(Get-DomainForwards $Vm | Where-Object { $_.Host -eq $HostPort })
    if ($match.Count -eq 0) { Die "$Vm has no forward on host port $HostPort" }

    Remove-LauncherForward $Vm $HostPort
    if (Test-DomainRunning $Vm) {
        $reply = Invoke-DomainMonitor $Vm "hostfwd_remove tcp::$HostPort"
        Assert-MonitorOk $reply "close $HostPort"
    }
    Say "$Vm`: closed 127.0.0.1:$HostPort"
}

# The monitor answers a refusal in prose on the same stream as its prompt, so
# there is no status to read -- only the absence of a complaint. Checked rather
# than assumed: a hostfwd_add for a port something else already holds fails
# there and would otherwise be reported here as success.
function Assert-MonitorOk {
    param([string]$Reply, [string]$What)
    if ($null -eq $Reply) {
        Die "could not reach the QEMU monitor to $What"
    }
    if ($Reply -match '(?im)^\s*(Could not|could not|error|Error|invalid)') {
        Die @("the QEMU monitor refused to $What`:", $Reply.Trim())
    }
}

function Add-LauncherForward {
    param([string]$Vm, [int]$HostPort, [int]$GuestPort)
    $path = Get-DomainLauncher $Vm
    $text = Get-Content -LiteralPath $path -Raw
    # Appended inside the existing -netdev argument: slirp takes every forward
    # as a comma-separated hostfwd= on the one netdev, so there is exactly one
    # place in the file this can go.
    $new = [regex]::Replace($text, '(-netdev\s+"?user,id=net0)', "`$1,hostfwd=tcp::${HostPort}-:${GuestPort}", 1)
    if ($new -eq $text) {
        Die "could not find the user-mode netdev in $path to add the forward to"
    }
    Set-Content -LiteralPath $path -Value $new -Encoding ASCII -NoNewline
}

function Remove-LauncherForward {
    param([string]$Vm, [int]$HostPort)
    $path = Get-DomainLauncher $Vm
    $text = Get-Content -LiteralPath $path -Raw
    $new = [regex]::Replace($text, ",hostfwd=tcp::$HostPort-:\d+", '', 1)
    Set-Content -LiteralPath $path -Value $new -Encoding ASCII -NoNewline
}

# --- delete -----------------------------------------------------------------

function Remove-Domain {
    param([string[]]$Arguments)
    $vm = if ($Arguments.Count -ge 1) { $Arguments[0] } else { $null }
    Assert-Domain $vm

    if (Test-DomainRunning $vm) {
        Die @(
            "$vm is running. Shut it down first -- 'virutil domain shutdown $vm'"
            '-- so the disk is closed before it is removed.'
        )
    }

    # Named one at a time rather than globbed on the domain name: a glob of
    # "$Vm*" in a shared image directory would take win11-backup.qcow2 with
    # win11, and delete never asks.
    foreach ($f in @((Get-DomainDisk $vm), (Get-DomainNvram $vm), (Get-DomainLauncher $vm),
                     (Get-DomainOvmfLog $vm))) {
        if (Remove-VirutilsFile $f) { Say "removed $f" }
    }
}

# --- create -----------------------------------------------------------------

function New-Domain {
    param([string[]]$Arguments)

    $vm = $null; $iso = $null
    $size = 64; $memory = 0; $vcpus = 0; $virtio = $null
    $ports = @(); $noStart = $false

    # if/elseif rather than `switch -Regex`: a PowerShell switch runs *every*
    # branch whose pattern matches unless each one breaks, so a catch-all '^-'
    # beside '^(-s|--size)$' fires on -s as well and refuses a flag it had just
    # accepted.
    $i = 0
    while ($i -lt $Arguments.Count) {
        $a = $Arguments[$i]
        if     ($a -in @('-h', '--help'))     { Usage (Get-DomainUsage) 0 }
        elseif ($a -in @('-s', '--size'))     { $i++; $size   = [int](Get-FlagValue $Arguments $i $a) }
        elseif ($a -in @('-m', '--memory'))   { $i++; $memory = [int](Get-FlagValue $Arguments $i $a) }
        elseif ($a -in @('-c', '--vcpus'))    { $i++; $vcpus  = [int](Get-FlagValue $Arguments $i $a) }
        elseif ($a -in @('-v', '--virtio'))   { $i++; $virtio = Get-FlagValue $Arguments $i $a }
        elseif ($a -in @('-p', '--port'))     { $i++; $ports += Get-FlagValue $Arguments $i $a }
        elseif ($a -in @('-N', '--no-start')) { $noStart = $true }
        elseif ($a -in @('-o', '--osinfo')) {
            $i++
            [void](Get-FlagValue $Arguments $i $a)
            Warn @(
                '-o is accepted and ignored: there is no libosinfo on this host'
                'and nothing here consults an os id. It is in the grammar so a'
                'command line written for one driver parses under the other.'
            )
        }
        elseif ($a.StartsWith('-')) { Die "virutil domain create: unknown flag: $a" }
        elseif ($null -eq $vm)      { $vm = $a }
        elseif ($null -eq $iso)     { $iso = $a }
        else { Usage (Get-DomainUsage) 1 }
        $i++
    }
    if (-not $vm -or -not $iso) { Usage (Get-DomainUsage) 1 }
    if ($ports.Count -eq 0) { $ports = @('13389:3389') }

    Write-IgnoredEnvWarnings

    $qemu = Get-QemuTools
    if (-not (Test-Path -LiteralPath $iso -PathType Leaf)) { Die "install ISO not found: $iso" }
    $iso = (Resolve-Path -LiteralPath $iso).Path

    $disk     = Get-DomainDisk $vm
    $nvram    = Get-DomainNvram $vm
    $launcher = Get-DomainLauncher $vm
    if (Test-Path -LiteralPath $disk) {
        Die @("disk image already exists: $disk",
              '  remove it, or set VIRUTILS_IMAGE_DIR elsewhere')
    }

    # Half the host's, as the Linux driver does.
    if (-not $memory) {
        $totalMiB = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
        $memory = [Math]::Max(2048, [int]($totalMiB / 2 / 512) * 512)
    }
    if (-not $vcpus) {
        $lp = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
        $vcpus = [Math]::Min(8, [Math]::Max(2, [int]($lp / 2)))
    }

    # virtio-win: found beside the ISO unless named, or refused with 'none'.
    if (-not $virtio) { $virtio = $script:VirutilsVirtio }
    if (-not $virtio) {
        $virtio = Get-ChildItem (Split-Path $iso) -Filter 'virtio-win*.iso' -ErrorAction SilentlyContinue |
                  Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName
    }
    if ($virtio -eq 'none') { $virtio = $null }
    if ($virtio) {
        if (-not (Test-Path -LiteralPath $virtio)) { Die "virtio-win ISO not found: $virtio" }
        $virtio = (Resolve-Path -LiteralPath $virtio).Path
    }

    $monitorPort = Get-FreeLoopbackPort
    New-VirutilsDir $script:VirutilsImageDir | Out-Null

    Say ('{0,-10}{1}' -f 'domain:',   "$vm (whpx, $($script:DomainCpu))")
    Say ('{0,-10}{1}' -f 'cpu:',      "$vcpus vcpus (1 socket x $vcpus cores x 1 thread)")
    Say ('{0,-10}{1}' -f 'memory:',   "$memory MiB")
    Say ('{0,-10}{1}' -f 'disk:',     "$disk ($size GiB)")
    Say ('{0,-10}{1}' -f 'iso:',      $iso)
    if ($virtio) { Say ('{0,-10}{1}' -f 'virtio:', $virtio) }

    # cluster_size=1M keeps a large image's L2 metadata small enough to stay
    # cached; lazy_refcounts trades a `qemu-img check -r all` after an unclean
    # shutdown for faster writes. No preallocation=metadata: on NTFS it writes
    # the whole image out up front.
    & $qemu.Img create -f qcow2 -o cluster_size=1M,lazy_refcounts=on -- $disk "${size}G" | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "could not create $disk" }
    Copy-Item -LiteralPath $qemu.VarsTemplate -Destination $nvram -Force

    $qemuArgs = Get-DomainQemuArgs -Vm $vm -Qemu $qemu -Disk $disk -Nvram $nvram `
        -Iso $iso -Virtio $virtio -Memory $memory -Vcpus $vcpus `
        -Ports $ports -MonitorPort $monitorPort

    Write-DomainLauncher $launcher $qemu.System $qemuArgs $vm
    Say ('{0,-10}{1}' -f 'launcher:', $launcher)
    Say ('{0,-10}{1}' -f 'monitor:',  "127.0.0.1:$monitorPort")
    Say ('{0,-10}{1}' -f 'agent:',    "\\.\pipe\$(Get-GuestAgentPipe $vm)")

    if ($noStart) { return }

    Start-Process -FilePath $qemu.System -ArgumentList $qemuArgs | Out-Null
    Send-BootPrompt $vm

    Say @(
        ''
        'Windows Setup should be on screen. Boot it again later with:'
        "  virutil domain start $vm"
    )
    if ($virtio) {
        Say @(
            "At 'Where do you want to install' the disk is missing until you"
            'Load driver -> the virtio-win CD -> amd64\<version>. virtio-blk has'
            'no inbox driver.'
            ''
            'Install virtio-win-guest-tools.exe off the same CD afterwards: it'
            'carries the QEMU guest agent, and without the agent exec, push and'
            'pull have nothing to drive the guest with.'
        )
    }
    Say "RDP once it is up: mstsc /v:localhost:$(($ports[0] -split ':')[0])"
}

# Windows Setup boots from the CD only if a key is pressed at the "Press any
# key" prompt, and without one the firmware falls through to the UEFI shell --
# which looks exactly like a hang if you are reading a screenshot. Nobody is
# watching the window this early, so the monitor presses it.
function Send-BootPrompt {
    param([string]$Vm)
    $port = Get-DomainMonitorPort $Vm
    $w = $null
    $tcp = $null
    try {
        foreach ($i in 1..40) {
            if ($null -eq $w) {
                try {
                    $tcp = New-Object Net.Sockets.TcpClient('127.0.0.1', $port)
                    $w = New-Object IO.StreamWriter($tcp.GetStream())
                    $w.AutoFlush = $true
                } catch { }
            }
            if ($null -ne $w) { try { $w.WriteLine('sendkey ret') } catch { $w = $null } }
            Start-Sleep -Milliseconds 700
        }
    } finally {
        if ($null -ne $tcp) { $tcp.Close() }
    }
}

# --- the qemu command line --------------------------------------------------

function Get-QemuTools {
    $dir = @(
        (Join-Path $env:USERPROFILE 'scoop\apps\qemu\current')
        'C:\Program Files\qemu'
    ) | Where-Object { Test-Path (Join-Path $_ 'qemu-system-x86_64.exe') } | Select-Object -First 1
    if (-not $dir) { Die 'qemu-system-x86_64.exe not found (scoop install qemu)' }

    $system = Join-Path $dir 'qemu-system-x86_64.exe'
    # -join: on an array, -notmatch filters rather than tests, and a non-empty
    # filtered array is always true.
    if (((& $system -accel help) -join "`n") -notmatch 'whpx') {
        Die 'this qemu has no whpx accelerator'
    }

    $code = Join-Path $dir 'share\edk2-x86_64-code.fd'
    $vars = Join-Path $dir 'share\edk2-i386-vars.fd'
    if (-not (Test-Path $code) -or -not (Test-Path $vars)) {
        Die "no OVMF firmware under $dir\share -- Windows 11 will not install without UEFI"
    }
    return @{ Dir = $dir; System = $system; Img = (Join-Path $dir 'qemu-img.exe')
              Code = $code; VarsTemplate = $vars }
}

# A free loopback port for the monitor. Bound and released rather than scanned:
# asking the OS for port 0 is the only way to be told a port that is actually
# free, and the race between releasing it and qemu binding it is one transfer
# wide and fails loudly if it is lost.
function Get-FreeLoopbackPort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start()
    try { return ([Net.IPEndPoint]$l.LocalEndpoint).Port } finally { $l.Stop() }
}

function Get-DomainQemuArgs {
    param(
        [string]$Vm, $Qemu, [string]$Disk, [string]$Nvram, [string]$Iso,
        [string]$Virtio, [int]$Memory, [int]$Vcpus, [string[]]$Ports, [int]$MonitorPort
    )

    $hostfwd = ($Ports | ForEach-Object {
        $parts = $_ -split ':', 2
        $h = $parts[0]
        $g = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { $h }
        "hostfwd=tcp::${h}-:${g}"
    }) -join ','

    $qemuArgs = @(
        '-name', $Vm
        '-accel', 'whpx'
        # smm=off: WHPX cannot run SMM, and q35 turns it on by default.
        '-machine', 'q35,smm=off,vmport=off'
        '-cpu', $script:DomainCpu
        '-smp', "$Vcpus,sockets=1,cores=$Vcpus,threads=1"
        '-m', "$Memory"
        '-drive', "if=pflash,format=raw,readonly=on,file=$($Qemu.Code)"
        '-drive', "if=pflash,format=raw,file=$Nvram"
        '-drive', "file=$Disk,if=none,id=hd0,format=qcow2,cache=writeback,discard=unmap"
        '-device', "virtio-blk-pci,drive=hd0,num-queues=$Vcpus,bootindex=1"
        '-drive', "file=$Iso,if=none,id=cd0,media=cdrom,readonly=on"
        '-device', 'ide-cd,bus=ide.0,drive=cd0,bootindex=0'
    )
    if ($Virtio) {
        $qemuArgs += '-drive', "file=$Virtio,if=none,id=cd1,media=cdrom,readonly=on"
        $qemuArgs += '-device', 'ide-cd,bus=ide.1,drive=cd1'
    }
    $qemuArgs += @(
        '-netdev', "user,id=net0,$hostfwd"
        '-device', 'virtio-net-pci,netdev=net0'
        '-vga', 'std'
        '-device', 'qemu-xhci,id=xhci'
        '-device', 'usb-tablet'
        '-display', 'gtk'
        '-audiodev', 'none,id=snd0'

        # OVMF's own log, and it is the bisect tool rather than a nicety. Every
        # WHPX failure found on this host presents as a black window with no
        # output at all; what separates them is how far the firmware got, and
        # this is the only place that is written down. A boot reaching the EFI
        # shell writes ~110 KB, one hanging in MP init stops at ~7.8 KB with
        # "CpuMpPei: 5-Level Paging = 0" as its last line, and that size
        # difference is how -cpu, -smp, cache= and -vga were each settled --
        # see the header of this file. `domain delete` takes it away with the
        # rest.
        '-debugcon', "file:$(Get-DomainOvmfLog $Vm)"
        '-global', 'isa-debugcon.iobase=0x402'

        # The guest agent channel, and nothing downstream of domain works
        # without it: exec runs through it, guest_os asks it what OS is there,
        # and push and pull both wait on it before they start. A named pipe
        # rather than the unix socket the Linux driver's libvirt would make --
        # qemu prefixes the path with \\.\pipe\ itself.
        '-chardev', "pipe,id=qga0,path=$(Get-GuestAgentPipe $Vm)"
        '-device', 'virtio-serial'
        '-device', 'virtserialport,chardev=qga0,name=org.qemu.guest_agent.0'

        # The monitor is how the boot prompt gets answered and the only handle
        # on the guest once it is running: sendkey, system_powerdown,
        # hostfwd_add, hostfwd_remove. Its port is per-domain, read back out of
        # the launcher by everything in this file.
        '-monitor', "tcp:127.0.0.1:$MonitorPort,server,nowait"
    )
    return $qemuArgs
}

# The launcher is the domain: the same arguments, frozen, so a later boot is the
# machine Windows activated against.
function Write-DomainLauncher {
    param([string]$Path, [string]$Qemu, [string[]]$QemuArgs, [string]$Vm)

    $pairs = @()
    for ($i = 0; $i -lt $QemuArgs.Count; $i += 2) {
        $flag = $QemuArgs[$i]
        $val  = [string]$QemuArgs[$i + 1]
        if ($val -match '[\s,]') { $val = '"' + $val + '"' }
        $pairs += "$flag $val"
    }
    $quoted = $pairs -join " ^`r`n    "

    $text = @"
@echo off
rem virutil domain: $Vm -- regenerate with: virutil domain create $Vm <iso>
rem This file is the domain. virutil reads the monitor port and the port
rem forwards back out of it; edit it by hand and virutil follows the edit.
start "" "$Qemu" ^
    $quoted
"@
    Set-Content -LiteralPath $Path -Value $text -Encoding ASCII
}
