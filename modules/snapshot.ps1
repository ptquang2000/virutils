# snapshot -- qcow2 internal snapshots for a domain on a Windows host.
#
# The counterpart of modules/snapshot, and the module docs/contract.md section 7
# spent a long time saying would not be ported. It is ported now, and the thing
# that was open -- "what does the memory half do on raw QEMU?" -- has a measured
# answer at last. It is: **there is no memory half on this host, and there
# cannot be one.** WHPX installs a migration blocker, so the qemu that saves a
# VM's state refuses before it reaches any disk. Measured on this host, qemu
# 11.1.0, against a running guest on the same command line domain.ps1 writes:
#
#   (qemu) savevm t1
#   Error: State blocked due to missing dirty memory tracking support,
#   And some system register/state save-restore
#
# That is the accelerator, not the disks -- it fires identically with the UEFI
# nvram as raw pflash and as qcow2, which is worth saying because the *second*
# blocker is a pflash one and looks like the whole story:
#
#   (qemu) loadvm t1
#   Error: Device 'pflash1' is writable but does not support snapshots
#
# Converting the nvram to qcow2 clears that one and changes nothing: savevm
# still stops at the accelerator. So `migrate "exec:..."`, `savevm` and every
# other route to a guest's RAM is closed while the domain runs under WHPX, and
# no amount of plumbing here opens it.
#
# Both halves of that have since been re-measured against a real guest rather
# than the bare OVMF probe the first numbers came from -- a Windows 11 guest
# installing from its own media, running and paused alike -- and they came back
# in the same words. `migrate` was tried as well, since "savevm is blocked" and
# "the guest's RAM is unreachable" are different claims: `migrate -d file:...`
# writes no file, and `info migrate` answers `Outgoing migration blocked:` with
# the same reason, which is the blocker naming itself. The wording is upstream's
# own -- it was written in patch 33 of the WHPX x86 series for qemu 11.1, the
# series that added XSAVE support and kept the blocker anyway because dirty
# memory tracking is still missing -- so the thing to watch, if this is ever to
# change, is dirty memory tracking landing in whpx-all.c.
#
# What is left is the disk half, and section 2 of the contract has been changed
# deliberately to say so: **on a Windows host a snapshot is disk-only, and
# create, revert and delete need the domain shut off.** Not silently -- the one
# thing section 9 forbids is accepting a command and quietly meaning something
# else by it, and a `create` on a running domain that captured no memory would
# be exactly that, found out at `revert`. So a running domain is refused, by
# name, with the reason.
#
# The mechanism is qcow2's own internal snapshots -- `qemu-img snapshot`, four
# flags, one image -- rather than the overlay-per-disk the bash driver gets from
# libvirt. Two consequences a reader should have up front:
#
#   * There are no overlay or memory files. The snapshot lives inside
#     `<image dir>/VM.qcow2`, so `domain delete` takes the snapshots with the
#     disk and there is nothing for a sweep to leak. Most of modules/snapshot --
#     snapshot_sweep, snapshot_kept_files, the whole in-use analysis -- is
#     answering a question this host does not have.
#   * Internal snapshots are a flat list, not a tree: qcow2 records no parent.
#     "delete takes SNAP's descendants with it" is therefore satisfied
#     vacuously, and `list` prints a list where the bash driver prints a tree.
#
# The UEFI nvram is deliberately left out of a snapshot. It is a raw pflash file
# beside the disk and cannot go inside the qcow2, and copying it aside per
# snapshot would add files this module otherwise does not have for the sake of
# boot entries that a revert of the same disk leaves pointing at the same
# loader. If that ever bites, it bites at boot and this comment is the place it
# is written down.

# Get-SnapshotUsage -- the bash module's usage, minus what this host cannot mean.
function Get-SnapshotUsage {
    @(
        'usage: virutil snapshot create VM [SNAP]  (default name snap-<timestamp>)'
        '       virutil snapshot list   VM'
        '       virutil snapshot revert VM SNAP'
        '       virutil snapshot delete VM SNAP'
        ''
        'Snapshots here are qcow2 internal snapshots: they live inside the'
        "domain's own disk image, so there are no overlay or memory files and"
        '`domain delete` takes them with the disk.'
        ''
        'On this host a snapshot is disk-only, and create, revert and delete'
        'need the domain shut off -- shut off, not merely paused: pausing'
        'stops the vCPUs and changes nothing about either half. WHPX blocks'
        "qemu's VM-state save in any run state, so a guest's memory cannot be"
        'captured at all, and qemu holds its image open whether the guest is'
        'running or paused. qemu on Windows does not lock that image, so'
        'virutil checks it is free before it writes. The bash driver on a'
        'Linux host does snapshot memory for a running domain -- see'
        'docs/contract.md section 9.'
        ''
        '  -h, --help  this message'
    )
}

function Snapshot-Main {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { Usage (Get-SnapshotUsage) 1 }
    $cmd = $Arguments[0]
    if ($cmd -in @('-h', '--help')) { Usage (Get-SnapshotUsage) 0 }

    $rest = Get-RestArgs $Arguments 1

    switch ($cmd) {
        'create' { New-DomainSnapshot    $rest }
        'list'   { Show-DomainSnapshots  $rest }
        'revert' { Restore-DomainSnapshot $rest }
        'delete' { Remove-DomainSnapshot $rest }
        default  { Die "virutil snapshot: unknown command: $cmd (see: virutil snapshot -h)" }
    }
}

# --- naming one -------------------------------------------------------------

# Read-SnapshotName ARG -- a tag this driver is willing to write.
#
# qcow2 itself takes almost anything, and the bash driver passes whatever it is
# given straight to virsh. Here the tag travels twice on a command line -- to
# qemu-img, and through the HMP monitor, which is line-oriented and has no
# quoting to speak of -- so a name with a space or a quote in it would mean two
# different things on the two paths. Refused up front instead, since nothing a
# snapshot name is for needs those characters.
function Read-SnapshotName {
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        Die @(
            "'$Name' is not a name this driver will write."
            'A snapshot name starts with a letter or digit and holds letters,'
            'digits, dot, dash and underscore, up to 64 characters.'
        )
    }
    return $Name
}

# --- reading the image ------------------------------------------------------

# Assert-SnapshotDomain VM -- the domain exists and its disk is where section 3
# of the contract says it is. A launcher whose disk has been moved out from
# under it is worth saying plainly rather than letting qemu-img say it.
function Assert-SnapshotDomain {
    param([string]$Vm)
    Assert-Domain $Vm
    $disk = Get-DomainDisk $Vm
    if (-not (Test-Path -LiteralPath $disk)) {
        Die "$Vm's disk is missing: $disk"
    }
    return $disk
}

# Test-DiskInUse DISK -- has anything got this image open?
#
# Asked by opening it exclusively and closing it again, which is the only
# question that actually matters before qemu-img writes: not "is there a domain
# running" but "is anything holding this file". Two reasons it is not enough to
# ask the monitor:
#
#   * **qemu on Windows does not protect the image.** On a Linux host qemu takes
#     an OFD lock and qemu-img refuses a locked image outright; the Windows file
#     backend has no equivalent. Measured here: `qemu-img snapshot -c` against
#     the disk of a running domain returned exit 0 and wrote the snapshot, with
#     the guest live on the same image. So the shut-off rule is virutil's to
#     enforce -- nothing underneath will catch a miss.
#   * **The monitor answers a different question.** Test-DomainRunning asks
#     whether a monitor is listening, and a live qemu whose monitor never came
#     up answers no. That is not hypothetical: a qemu started with the
#     launcher's guest-agent chardev and no client on the pipe was observed
#     running with nothing on its monitor port. Classified "shut off" on the
#     monitor alone, it would have been snapshotted underneath.
#
# Windows answers this precisely -- a sharing violation is a fact about the
# file, not a guess -- and it costs one open.
function Test-DiskInUse {
    param([string]$Disk)
    try {
        $h = [IO.File]::Open($Disk, 'Open', 'ReadWrite', 'None')
        $h.Close()
        return $false
    } catch [IO.IOException] {
        return $true
    }
}

# Assert-SnapshotShutOff VM DISK VERB -- the refusal, in one place because all
# three writing verbs owe the same explanation.
function Assert-SnapshotShutOff {
    param([string]$Vm, [string]$Disk, [string]$Verb)

    # The disk first: it is the question with the expensive wrong answer, and it
    # is true in some cases the monitor's answer is not.
    if (Test-DiskInUse $Disk) {
        Die @(
            "something has $Vm's disk open, so snapshot $Verb cannot run:"
            "  $Disk"
            'Almost always that is the domain itself -- a qemu whose monitor is'
            'not answering still holds its image, and virutil would otherwise'
            'read it as shut off. qemu on Windows does not lock the image, so'
            'writing a snapshot into it underneath a live guest would be'
            'accepted and would corrupt it.'
            ''
            "  virutil domain shutdown $Vm    (or close the qemu window)"
        )
    }

    if (-not (Test-DomainRunning $Vm)) { return }
    Die @(
        "$Vm is running, and snapshot $Verb needs it shut off on this host."
        'Two reasons, and the first one is the one that cannot be worked'
        "around: WHPX blocks qemu's VM-state save, so a running guest's memory"
        'cannot go into a snapshot at all; and the disk that running qemu has'
        'open must not be written by qemu-img underneath it.'
        ''
        "  virutil domain shutdown $Vm"
        ''
        'The bash driver on a Linux host does snapshot a running domain, memory'
        'included. That difference is docs/contract.md section 9, not a bug.'
    )
}

# Invoke-QemuImgSnapshot FLAG [ARG] DISK -- one qemu-img snapshot call, with its
# own output kept for the failure message. qemu-img writes its diagnosis to
# stderr and says something useful ("snapshot not found"), so it is quoted
# rather than replaced.
function Invoke-QemuImgSnapshot {
    param([string]$Flag, [string]$Name, [string]$Disk, [string]$What)

    $img = (Get-QemuTools).Img
    $qemuArgs = @('snapshot', $Flag)
    if ($Name) { $qemuArgs += $Name }
    $qemuArgs += @('--', $Disk)

    $out = & $img @qemuArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Die @("could not $What`:", (($out | ForEach-Object { "  $_" }) -join "`n"))
    }
    return $out
}

# Get-MonitorBody REPLY -- the monitor's answer with its banner, its echo of the
# command and its terminal escapes taken off.
#
# The HMP monitor echoes every character it receives with a cursor-movement
# escape around it, so the reply to `info snapshots` starts with several hundred
# bytes of ESC [ K and ESC [ D before the first real line. Everything up to and
# including the first "(qemu) " prompt is that; what follows is the answer.
function Get-MonitorBody {
    param([string]$Reply)
    $clean = [regex]::Replace([string]$Reply, "`e\[[0-9;]*[A-Za-z]", '')
    $i = $clean.IndexOf('(qemu)')
    if ($i -ge 0) {
        $nl = $clean.IndexOf("`n", $i)
        if ($nl -ge 0) { $clean = $clean.Substring($nl + 1) }
    }
    return $clean
}

# The snapshot table's data rows, as qemu prints them: "ID TAG VM_SIZE DATE ...".
# Read over the monitor when the domain is running -- `info snapshots` is a
# question, and asking it costs the guest nothing -- and out of the image
# directly when it is not. qemu-img is never pointed at a disk a running qemu
# holds open, not even to read: the answer would be whatever was last flushed.
function Get-SnapshotRows {
    param([string]$Vm)

    if (Test-DomainRunning $Vm) {
        $reply = Invoke-DomainMonitor $Vm 'info snapshots'
        Assert-MonitorOk $reply "list $Vm's snapshots"
        $text = Get-MonitorBody $reply
    } else {
        $text = (Invoke-QemuImgSnapshot '-l' '' (Get-DomainDisk $Vm) `
                 "list $Vm's snapshots") -join "`n"
    }

    # A data row starts with the snapshot's numeric id; the "Snapshot list:"
    # banner, the column header and "There is no snapshot available." do not.
    return @($text -split "`r?`n" |
             Where-Object { $_ -match '^\s*\d+\s+\S' } |
             ForEach-Object { $_.TrimEnd() })
}

# The tags alone. The tag is the second column and this driver's own names have
# no spaces in them (Read-SnapshotName), but one written by hand elsewhere might;
# such a tag reads back here truncated at the space, which is a wrong answer for
# a name virutil would refuse to create in the first place.
function Get-SnapshotNames {
    param([string]$Vm)
    return @(Get-SnapshotRows $Vm | ForEach-Object {
        if ($_ -match '^\s*\d+\s+(\S+)') { $Matches[1] }
    })
}

function Test-Snapshot {
    param([string]$Vm, [string]$Name)
    return ((Get-SnapshotNames $Vm) -contains $Name)
}

# --- create -----------------------------------------------------------------

function New-DomainSnapshot {
    param([string[]]$Arguments)

    $vm = if ($Arguments.Count -ge 1) { $Arguments[0] } else { $null }
    if (-not $vm) { Usage (Get-SnapshotUsage) 1 }
    $disk = Assert-SnapshotDomain $vm
    Assert-SnapshotShutOff $vm $disk 'create'

    $snap = if ($Arguments.Count -ge 2) {
        Read-SnapshotName $Arguments[1]
    } else {
        'snap-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    }

    # A tag qcow2 already holds is not an overwrite: qemu-img adds a second
    # snapshot with the same tag and a different id, and `revert` would then
    # have two answers to choose between. The bash driver refuses a duplicate
    # name for the same shape of reason; so does this.
    if (Test-Snapshot $vm $snap) {
        Die @("snapshot '$snap' already exists on $vm",
              "Pick another name, or: virutil snapshot delete $vm $snap")
    }

    Say 'shut off: disk-only snapshot (no memory image -- WHPX blocks one)'
    Invoke-QemuImgSnapshot '-c' $snap $disk "create snapshot '$snap' on $vm" | Out-Null

    # qemu-img exits 0 on a snapshot it did not write in at least one corner --
    # an image already at the qcow2 snapshot limit -- and a create that reports
    # success for a snapshot that is not there is found out at revert, which is
    # the failure this module exists to avoid.
    if (-not (Test-Snapshot $vm $snap)) {
        Die "qemu-img reported success but '$snap' is not in $disk"
    }
    [Console]::Out.WriteLine("created: $snap")
}

# --- list -------------------------------------------------------------------

# A list, not a tree: qcow2 records no parent, so there is no tree to print.
# The columns are qemu's own rather than reformatted, so that what `list` shows
# and what `qemu-img snapshot -l` shows are the same text.
function Show-DomainSnapshots {
    param([string[]]$Arguments)

    $vm = if ($Arguments.Count -ge 1) { $Arguments[0] } else { $null }
    if (-not $vm) { Usage (Get-SnapshotUsage) 1 }
    [void](Assert-SnapshotDomain $vm)

    $rows = @(Get-SnapshotRows $vm)
    if ($rows.Count -eq 0) { Say "no snapshots on $vm"; return }

    [Console]::Out.WriteLine((' {0,-6} {1,-24} {2}' -f 'ID', 'TAG', 'VM_SIZE / DATE / VM_CLOCK'))
    [Console]::Out.WriteLine('-' * 60)
    foreach ($r in $rows) {
        # Whatever qemu put after the tag -- size, date, vm clock -- is carried
        # through as one field rather than re-parsed into columns this module
        # would then have to keep in step with qemu's.
        if ($r -match '^\s*(\d+)\s+(\S+)\s+(.*)$') {
            [Console]::Out.WriteLine((' {0,-6} {1,-24} {2}' -f
                $Matches[1], $Matches[2], $Matches[3].Trim()))
        } else {
            [Console]::Out.WriteLine(" $($r.Trim())")
        }
    }
}

# --- revert -----------------------------------------------------------------

function Restore-DomainSnapshot {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 2) { Usage (Get-SnapshotUsage) 1 }
    $vm = $Arguments[0]
    $snap = Read-SnapshotName $Arguments[1]
    $disk = Assert-SnapshotDomain $vm
    Assert-SnapshotShutOff $vm $disk 'revert'

    if (-not (Test-Snapshot $vm $snap)) { Die "no such snapshot on $vm`: $snap" }

    Invoke-QemuImgSnapshot '-a' $snap $disk "revert $vm to '$snap'" | Out-Null
    [Console]::Out.WriteLine("reverted: $snap")

    # The bash driver's revert hands back a *running* domain -- libvirt restores
    # the memory image and resumes it. There is no memory image here, so there
    # is nothing to resume into and the domain is left as it was found: shut
    # off, with its disk at the snapshot's state. Starting it would be this
    # driver deciding to boot a guest the user did not ask it to boot.
    Say "$vm is shut off with its disk at '$snap' -- virutil domain start $vm"
}

# --- delete -----------------------------------------------------------------

function Remove-DomainSnapshot {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 2) { Usage (Get-SnapshotUsage) 1 }
    $vm = $Arguments[0]
    $snap = Read-SnapshotName $Arguments[1]
    $disk = Assert-SnapshotDomain $vm
    Assert-SnapshotShutOff $vm $disk 'delete'

    if (-not (Test-Snapshot $vm $snap)) { Die "no such snapshot on $vm`: $snap" }

    # No descendants to take with it, and no files to sweep afterwards: an
    # internal snapshot has no children recorded and no existence outside the
    # qcow2. Both of those are half of modules/snapshot on the other driver.
    Invoke-QemuImgSnapshot '-d' $snap $disk "delete snapshot '$snap' from $vm" | Out-Null
    [Console]::Out.WriteLine("deleted: $snap")
}
