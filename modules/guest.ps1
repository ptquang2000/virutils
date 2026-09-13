# guest -- the helpers every module shares: the agent channel, what OS is on the
# other side, and the path normalisation the transfers use. The counterpart of
# modules/guest.
#
# The one real difference from the bash tree is the channel. There the agent is
# reached with `virsh qemu-agent-command`, which is libvirt doing the framing;
# here there is no libvirt, so this talks the QMP-style line protocol to
# qemu-ga directly over the virtio-serial chardev that modules/domain.ps1 gives
# every domain it creates. That is *simpler* than the libvirt path rather than
# harder -- there is nothing in the way -- and it is why the agent channel was
# the first thing this driver needed.

# --- numbers a person can read ----------------------------------------------
#
# These exist because a log line is read by someone deciding whether a transfer
# is going well, and "50000000 bytes" does not answer that question as fast as
# "47.7 MiB" does. Binary units throughout, to match what Windows reports for
# the same file. Character for character what modules/guest prints.

function Format-Bytes {
    param([double]$Bytes = 0)
    $units = @('B', 'KiB', 'MiB', 'GiB', 'TiB')
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt 4) { $Bytes /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:d} {1}' -f [int]$Bytes, $units[$i]) }
    return ('{0:f1} {1}' -f $Bytes, $units[$i])
}

function Format-Duration {
    param([double]$Ms = 0)
    if ($Ms -lt 1000)  { return ('{0:d}ms' -f [int]$Ms) }
    if ($Ms -lt 60000) { return ('{0:f1}s' -f ($Ms / 1000)) }
    return ('{0:d}m{1:d2}s' -f [int]($Ms / 60000), [int](($Ms % 60000) / 1000))
}

# Nothing when the interval is too short to divide by, rather than a number
# invented from a rounding artefact.
function Format-Rate {
    param([double]$Bytes = 0, [double]$Ms = 0)
    if ($Ms -le 0) { return '' }
    $r = $Bytes * 1000 / $Ms
    $units = @('B', 'KiB', 'MiB', 'GiB')
    $i = 0
    while ($r -ge 1024 -and $i -lt 3) { $r /= 1024; $i++ }
    return ('{0:f1} {1}/s' -f $r, $units[$i])
}

# --- the guest agent --------------------------------------------------------
#
# Every far-side operation in this tool runs through qemu-ga. The channel is one
# duplex named pipe per domain, created by qemu with
#
#   -chardev pipe,id=qga0,path=<Get-GuestAgentPipe VM>
#   -device  virtio-serial
#   -device  virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
#
# and spoken as newline-delimited JSON: one object out, one object back.

# The pipe name is derived from the domain name and nothing else, so there is no
# per-VM record to keep in step with the launcher. qemu prefixes it with
# \\.\pipe\ itself, so what goes on the command line is the bare name and what
# a client opens is the same name.
function Get-GuestAgentPipe {
    param([Parameter(Mandatory)][string]$Vm)
    return "virutil-$Vm-qga"
}

# --- one channel for the whole run ------------------------------------------
#
# **qemu's chardev does not go back to listening once a client has come and
# gone.** Measured on this host: with a real qemu carrying exactly the arguments
# domain create writes, a `pipe` chardev accepts one connection and refuses
# every later one, and a `socket` chardev accepts two and then refuses. Neither
# recovers with time.
#
# So a connection per command is wrong: `exec` polls guest-exec-status in a
# loop, and the second poll would find the channel gone. One channel is opened
# lazily, kept for the life of the run, and closed once at the end.
#
# **The probe was taken with no guest behind the port, and that is a real
# confound** -- with nothing on the guest side the virtserialport is never
# opened, and qemu's chardev may not run its ordinary disconnect handling at
# all. Whether a *second* virutil run can reach the same guest is therefore
# unknown, and it is the first thing to measure once a guest exists. Holding one
# channel is the right shape either way, which is why it is not being waited on.
$script:GuestAgentChannels = @{}

# Get-GuestAgentChannel VM -- the run's channel to VM, opened on first use.
# $null if it cannot be opened; the caller says what that means.
function Get-GuestAgentChannel {
    param([Parameter(Mandatory)][string]$Vm, [int]$TimeoutMs = 2000)
    if ($script:GuestAgentChannels.ContainsKey($Vm)) {
        return $script:GuestAgentChannels[$Vm]
    }
    $pipe = Open-GuestAgent $Vm -TimeoutMs $TimeoutMs
    if ($null -ne $pipe) { $script:GuestAgentChannels[$Vm] = $pipe }
    return $pipe
}

# Close-GuestAgentChannels -- called once by virutil.ps1 however the run ends.
# The channel is one per qemu process rather than one per command, so leaving it
# open past the run would be leaving it open for good.
function Close-GuestAgentChannels {
    foreach ($k in @($script:GuestAgentChannels.Keys)) {
        try { $script:GuestAgentChannels[$k].Dispose() } catch { }
    }
    $script:GuestAgentChannels = @{}
}

# Reset-GuestAgentChannel VM -- forget a channel that has gone bad, so a later
# call opens a fresh one rather than writing into a dead stream. Whether that
# fresh open can succeed is the unknown above.
function Reset-GuestAgentChannel {
    param([Parameter(Mandatory)][string]$Vm)
    if ($script:GuestAgentChannels.ContainsKey($Vm)) {
        try { $script:GuestAgentChannels[$Vm].Dispose() } catch { }
        $script:GuestAgentChannels.Remove($Vm)
    }
}

# Open-GuestAgent VM [-TimeoutMs N] -- a connected, synchronised channel, or
# $null. The caller closes it.
#
# The synchronise is not optional politeness. The channel survives the host
# process that last used it, so a reply nobody read -- from a run that was
# interrupted, or from a guest that answered late -- is still sitting in the
# buffer, and the next command would read that stale reply as its own. The
# documented fix is guest-sync-delimited: an 0xFF byte, which qemu-ga treats as
# "discard what you were parsing", then a request carrying an id, and everything
# before the answering 0xFF is thrown away.
function Open-GuestAgent {
    param([Parameter(Mandatory)][string]$Vm, [int]$TimeoutMs = 2000)

    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
        '.', (Get-GuestAgentPipe $Vm),
        [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect($TimeoutMs)
    } catch {
        $pipe.Dispose()
        return $null
    }

    $id = Get-Random -Minimum 1 -Maximum ([int]::MaxValue)
    # The delimiter is a raw 0xFF byte and is prepended as one. Putting U+00FF
    # in the string instead would encode as two bytes (0xC3 0xBF), which is not
    # the byte qemu-ga looks for, and the sync would silently never happen.
    $req = @([byte]0xFF) + [Text.Encoding]::UTF8.GetBytes(
        "{""execute"":""guest-sync-delimited"",""arguments"":{""id"":$id}}`n")
    try {
        $pipe.Write($req, 0, $req.Length)
        $pipe.Flush()
        if (-not (Wait-GuestAgentDelimiter $pipe $TimeoutMs)) { $pipe.Dispose(); return $null }
        $line = Read-GuestAgentLine $pipe $TimeoutMs
        if ($null -eq $line) { $pipe.Dispose(); return $null }
        # The id has to match, or this is still an older run's reply and the
        # sync has not actually caught up.
        $reply = $line | ConvertFrom-Json
        if ($reply.return -ne $id) { $pipe.Dispose(); return $null }
    } catch {
        $pipe.Dispose()
        return $null
    }
    return $pipe
}

# One byte, or $null if none arrived before DEADLINE.
#
# ReadAsync and Wait rather than a plain Read, and this is the difference
# between a timeout and a hang: NamedPipeClientStream honours no ReadTimeout, so
# a synchronous Read for a byte the guest is never going to send blocks forever
# and no deadline checked around it is ever reached. The pipe is opened
# Asynchronous for exactly this. A read left outstanding when the wait expires
# is cancelled by the Dispose that every timeout path here leads to.
function Read-GuestAgentByte {
    param($Pipe, [long]$Deadline)
    $remaining = $Deadline - [Environment]::TickCount64
    if ($remaining -le 0) { return $null }
    $buf = New-Object byte[] 1
    $task = $Pipe.ReadAsync($buf, 0, 1)
    if (-not $task.Wait([int]$remaining)) { return $null }
    if ($task.Result -eq 0) { return $null }
    return $buf[0]
}

# Everything up to and including the 0xFF that answers a sync, discarded.
function Wait-GuestAgentDelimiter {
    param($Pipe, [int]$TimeoutMs)
    $deadline = [Environment]::TickCount64 + $TimeoutMs
    while ($true) {
        $b = Read-GuestAgentByte $Pipe $deadline
        if ($null -eq $b) { return $false }
        if ($b -eq 0xFF) { return $true }
    }
}

# One newline-terminated JSON object, as a string, or $null on timeout. A byte
# at a time because the reply is a line: a fixed-size read would either block
# for bytes that are not coming or swallow the start of the next reply.
function Read-GuestAgentLine {
    param($Pipe, [int]$TimeoutMs)
    $deadline = [Environment]::TickCount64 + $TimeoutMs
    $out = New-Object System.IO.MemoryStream
    while ($true) {
        $b = Read-GuestAgentByte $Pipe $deadline
        if ($null -eq $b) { return $null }
        if ($b -eq 0x0A) { return [Text.Encoding]::UTF8.GetString($out.ToArray()) }
        $out.WriteByte($b)
    }
}

# Invoke-GuestAgent VM COMMAND [ARGUMENTS] -- one round trip, the `return`
# member of the reply. Dies on an agent-level error rather than handing a caller
# an object with no `return` in it.
#
# TimeoutMs is the wait for *this* reply, not for the command: guest-exec
# returns a pid immediately and it is guest-exec-status that is polled, so
# nothing here ever waits out a long-running guest process.
function Invoke-GuestAgent {
    param(
        [Parameter(Mandatory)][string]$Vm,
        [Parameter(Mandatory)][string]$Command,
        $Arguments = $null,
        [int]$TimeoutMs = 10000
    )

    $pipe = Get-GuestAgentChannel $Vm
    if ($null -eq $pipe) {
        Die @(
            "$Vm's QEMU guest agent is not answering on \\.\pipe\$(Get-GuestAgentPipe $Vm)."
            'The agent is what runs anything inside the guest, so nothing can'
            'proceed without it. Check that the domain is running, and that'
            'qemu-ga is running in the guest -- on a Windows guest that is the'
            "'QEMU Guest Agent' service, installed by virtio-win-guest-tools."
        )
    }

    # Not disposed here. The channel belongs to the run, not to this command --
    # see Get-GuestAgentChannel for why closing it would be closing it for good.
    try {
        $req = @{ execute = $Command }
        if ($null -ne $Arguments) { $req['arguments'] = $Arguments }
        $json = ($req | ConvertTo-Json -Depth 10 -Compress) + "`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $pipe.Write($bytes, 0, $bytes.Length)
        $pipe.Flush()
    } catch {
        Reset-GuestAgentChannel $Vm
        Die "$Vm's guest agent channel dropped while sending $Command`: $($_.Exception.Message)"
    }

    $line = Read-GuestAgentLine $pipe $TimeoutMs
    if ($null -eq $line) {
        Reset-GuestAgentChannel $Vm
        Die "$Vm's guest agent did not answer $Command within $($TimeoutMs)ms"
    }
    $reply = $line | ConvertFrom-Json
    if ($reply.PSObject.Properties.Name -contains 'error') {
        Die "$Vm's guest agent refused $Command`: $($reply.error.desc)"
    }
    # A command with nothing to return -- guest-ping -- answers {"return": {}},
    # so an absent member is a protocol surprise rather than an empty result.
    if ($reply.PSObject.Properties.Name -notcontains 'return') {
        Die "$Vm's guest agent answered $Command with neither a result nor an error"
    }
    return $reply.return
}

# Test-GuestAgent VM [SECONDS] -- true once the agent answers, waiting up to
# SECONDS for it. guest-ping, not the channel state: the pipe connects with
# nothing listening behind it.
#
# The retry is over the *held* channel rather than over fresh connections. A
# connect-per-attempt loop would spend the one connection qemu's chardev grants
# on the first attempt and then have nothing left to retry with -- which is
# exactly the failure Get-GuestAgentChannel exists to avoid, and it would be
# hidden here behind what looks like patience.
function Test-GuestAgent {
    param([Parameter(Mandatory)][string]$Vm, [int]$Seconds = 0)
    for ($i = 0; ; $i++) {
        $pipe = Get-GuestAgentChannel $Vm -TimeoutMs 500
        if ($null -ne $pipe) {
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes("{""execute"":""guest-ping""}`n")
                $pipe.Write($bytes, 0, $bytes.Length); $pipe.Flush()
                if ($null -ne (Read-GuestAgentLine $pipe 2000)) { return $true }
            } catch {
                Reset-GuestAgentChannel $Vm
            }
        }
        if ($i -ge $Seconds) { return $false }
        Start-Sleep -Seconds 1
    }
}

# --- which OS is on the other side ------------------------------------------
#
# push and pull ask rather than being flagged, and the asking is free: the
# transport they would use already requires the agent to drive the copy, so
# there is a round trip to spend either way. A --linux flag is one more thing to
# get wrong on a command whose failure mode is "the guest was told to run
# robocopy and does not have it".

$script:GuestOsDefault = 'windows'

# Get-GuestOs VM -- 'windows' or 'linux'.
#
# One source here where the bash driver has two: it can fall back to the
# libosinfo id virt-install wrote into the domain XML, and there is no domain
# XML on this host -- the launcher .cmd is the domain. So it is the agent, then
# the historical default.
#
# Anything that is not Windows is driven as Linux: /bin/sh and rsync, which is
# also true of the BSDs even though this vocabulary has no name for them. The
# alternative -- an allow-list of distribution ids -- would refuse to work on a
# guest that would have been fine.
function Get-GuestOs {
    param([Parameter(Mandatory)][string]$Vm)

    # guest-get-osinfo arrived in QEMU 5.1, so an older qemu-ga answers with an
    # error; that is not a reason to stop, only a reason to fall back.
    $id = $null
    try { $id = (Invoke-GuestAgent $Vm 'guest-get-osinfo').id } catch { $id = $null }

    if ($id) {
        if ($id -in @('mswindows', 'windows')) { return 'windows' }
        return 'linux'
    }

    Warn @(
        "could not tell what OS $Vm runs: its agent does not answer"
        'guest-get-osinfo (it predates QEMU 5.1). Assuming'
        "$($script:GuestOsDefault), which is what this has always done."
    )
    return $script:GuestOsDefault
}

# --- guest-relative paths ---------------------------------------------------
#
# A path a caller gave for the far side, normalised into one relative to the
# guest's root: no drive letter, no leading slash, no empty or '.' components,
# and never a '..'. '..' is refused rather than resolved away, because every use
# of these names a path under a root virutil owns, and '..' would leave it.
#
# Two flavours, and the difference between them is the one thing that cannot be
# shared: on Windows a backslash is a separator, and on Linux it is a legal
# character in a filename, so flipping it there would turn one name into two.

# ConvertTo-GuestRelative PATH WHAT ORIGINAL -- the component walk both flavours
# share. ORIGINAL is carried separately so the error names the path as the
# caller wrote it rather than as it looked halfway through being rewritten.
function ConvertTo-GuestRelative {
    param([string]$Path, [string]$What, [string]$Original)
    $out = @()
    foreach ($comp in $Path.Split('/')) {
        if ($comp -eq '' -or $comp -eq '.') { continue }
        if ($comp -eq '..') { Die "$What may not contain '..': $Original" }
        $out += $comp
    }
    return ($out -join '/')
}

# Relative to C:\.
function ConvertTo-GuestWindowsPath {
    param([string]$Path, [string]$What = 'path')
    $s = $Path -replace '^[Cc]:', ''
    $s = $s.Replace('\', '/')
    return ConvertTo-GuestRelative $s $What $Path
}

# Relative to /.
function ConvertTo-GuestPosixPath {
    param([string]$Path, [string]$What = 'path')
    return ConvertTo-GuestRelative $Path $What $Path
}
