# guest -- the helpers every module shares: the agent channel, what OS is on the
# other side, and the path normalisation the transfers use. The counterpart of
# modules/linux/guest.
#
# The one real difference from the bash tree is the channel. There the agent is
# reached with `virsh qemu-agent-command`, which is libvirt doing the framing;
# here there is no libvirt, so this talks the QMP-style line protocol to
# qemu-ga directly over the virtio-serial chardev that modules/win/domain.ps1
# gives every domain it creates. That is *simpler* than the libvirt path rather
# than harder -- there is nothing in the way -- and it is why the agent channel
# was the first thing this driver needed.

# --- numbers a person can read ----------------------------------------------
#
# These exist because a log line is read by someone deciding whether a transfer
# is going well, and "50000000 bytes" does not answer that question as fast as
# "47.7 MiB" does. Binary units throughout, to match what Windows reports for
# the same file. Character for character what modules/linux/guest prints.

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
# loopback socket per domain, created by qemu with
#
#   -chardev socket,id=qga0,host=127.0.0.1,port=<Get-GuestAgentPort VM>,server=on,wait=off
#   -device  virtio-serial
#   -device  virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
#
# and spoken as newline-delimited JSON: one object out, one object back.
#
# It was a named pipe until it was measured: `-chardev pipe` on Windows blocks
# qemu's startup until a client connects, which hung every `domain create` --
# see the chardev in Get-DomainQemuArgs for the whole diagnosis.

# Read back out of the launcher, the same way the monitor port is: the launcher
# is the domain, and a port allocated at create time has nowhere else to live.
function Get-GuestAgentPort {
    param([Parameter(Mandatory)][string]$Vm)
    $text = Get-DomainLauncherText $Vm
    # The optional quote is not cosmetic: the launcher quotes any value holding
    # a comma, and this one always holds several.
    $m = [regex]::Match($text, '-chardev\s+"?socket,id=qga0,host=127\.0\.0\.1,port=(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }

    if ($text -match '-chardev\s+"?pipe,id=qga0') {
        Die @(
            "$Vm was created with a pipe guest agent channel, which hangs qemu"
            'on this host: it blocks until something opens the pipe, before the'
            'display or the monitor come up at all. Recreate the domain --'
            "'virutil domain delete $Vm' then 'virutil domain create $Vm <iso>'"
            '-- to get the loopback socket that replaced it.'
        )
    }
    Die @(
        "$Vm's launcher opens no guest agent channel, so there is nothing to run"
        'anything inside the guest with. Recreate the domain, or add the qga0'
        "chardev to $(Get-DomainLauncher $Vm) by hand."
    )
}

# --- one round trip per call, under a per-domain lock -----------------------
#
# The channel serves one host client at a time: qemu's socket chardev stops
# accepting while a client is connected and listens with a backlog of 1, so a
# second client's connect succeeds but sits unanswered until the first one
# leaves. qemu-ga then answers in strict FIFO order on the one stream, so a
# client that leaves early hands its unread replies to whoever connects next.
# docs/qga-multi-client.md has the sources and the measurements.
#
# So every call is one round trip -- lock, connect, guest-sync-delimited, one
# command, its reply, close, unlock -- and two virutil runs against one domain
# interleave per command, the way libvirt's agent job makes them on the bash
# driver. The channel used to be held for the whole run, on the belief that a
# socket chardev "accepts two and then refuses". That was measured with no
# guest behind the port, and it is true only then: with nothing in the guest
# reading, qemu never reads the client's socket either, never sees its EOF,
# and the accept slot stays taken. With an agent running, 50 connect/sync/close
# cycles in a row all succeeded, about 35ms each, on isa-serial.
#
# The guestless case is still why Test-GuestAgent, the one caller that waits
# for an agent that may not be up yet, retries over one held connection rather
# than reconnecting.

# The lock is a file beside the launcher, held open for writing with read
# sharing only. A second opener gets a sharing violation, which is the wait;
# the OS drops the handle when its process dies, however it dies, so a crashed
# holder never leaves a stale lock behind -- only stale text, which the next
# holder overwrites. Read sharing is what lets a waiter read who holds it.
# A file rather than a named mutex because it is the same object to an
# elevated and an unelevated process, which a Local\ mutex is not.
$script:GuestAgentLocks = @{}

# What a waiter is shown: set once by virutil.ps1 from its own arguments.
$script:GuestAgentLockCommand = ''

function Get-GuestAgentLockPath {
    param([Parameter(Mandatory)][string]$Vm)
    return (Join-Path $script:VirutilsImageDir "$Vm.agent.lock")
}

# How long a call waits for another run's round trip, in seconds. Generous: a
# round trip is milliseconds, so a wait this long means the holder is stuck on a
# reply that is not coming, or is Test-GuestAgent waiting for a guest to boot.
function Get-GuestAgentLockWait {
    $v = Get-VirutilsEnv 'AGENT_WAIT' '120'
    $n = 0
    if (-not [int]::TryParse($v, [ref]$n) -or $n -lt 0) {
        Die "VIRUTILS_AGENT_WAIT must be a whole number of seconds, not '$v'"
    }
    return $n
}

# The holder's own line, or '' if it cannot be read. Never throws: it is only
# ever said to a person.
function Read-GuestAgentLockHolder {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $r = New-Object IO.StreamReader($fs)
            return $r.ReadToEnd().Trim()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

# True if this exception is the sharing violation that means "held".
function Test-GuestAgentLockBusy {
    param($Exception)
    $e = $Exception
    while ($e -is [Management.Automation.MethodInvocationException] -and $e.InnerException) {
        $e = $e.InnerException
    }
    if ($e -isnot [IO.IOException]) { return $false }
    # ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION
    $code = $e.HResult -band 0xFFFF
    return ($code -eq 32 -or $code -eq 33)
}

# Enter-GuestAgentLock VM -- hold VM's agent lock, waiting for another run's
# round trip to end. Dies, naming the holder, once VIRUTILS_AGENT_WAIT runs out.
# Re-entrant within a run, so a helper that holds it can call one that takes it.
function Enter-GuestAgentLock {
    param([Parameter(Mandatory)][string]$Vm)
    if ($script:GuestAgentLocks.ContainsKey($Vm)) {
        $script:GuestAgentLocks[$Vm].Depth++
        return
    }
    $path = Get-GuestAgentLockPath $Vm
    New-VirutilsDir (Split-Path -Parent $path) | Out-Null
    $waitS = Get-GuestAgentLockWait
    $started = Get-GuestAgentTick
    $deadline = $started + [long]$waitS * 1000
    $told = $null
    while ($true) {
        try {
            $fs = [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'Read')
            break
        } catch {
            if (-not (Test-GuestAgentLockBusy $_.Exception)) { throw }
        }
        $holder = Read-GuestAgentLockHolder $path
        if (-not $holder) { $holder = 'another virutil' }
        if ((Get-GuestAgentTick) -ge $deadline) {
            Die @(
                "gave up after ${waitS}s waiting for $Vm's guest agent, which is"
                "held by $holder."
                'The agent serves one client at a time, and that run has held it'
                'for longer than any one command takes. If it is stuck, ending it'
                'frees the agent; VIRUTILS_AGENT_WAIT sets how long to wait.'
            )
        }
        # Not at once: two runs taking turns wait on each other's round trips,
        # tens of milliseconds each, all the time, and that is working rather
        # than news. A wait that lasts is said, once per holder rather than once
        # per poll, because a busy domain changes hands between other runs'
        # commands.
        if ((Get-GuestAgentTick) - $started -ge 2000 -and $holder -ne $told) {
            Say "waiting for $Vm's guest agent: held by $holder"
            $told = $holder
        }
        Start-Sleep -Milliseconds 100
    }
    try {
        $line = "virutil pid $PID"
        if ($script:GuestAgentLockCommand) { $line += ", ``$($script:GuestAgentLockCommand)``" }
        $line += ", since $([DateTime]::Now.ToString('HH:mm:ss'))"
        $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`n")
        $fs.SetLength(0)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
    } catch {
        # The text is for a waiter to read; the lock is the handle, and that
        # is held whether or not the text made it.
    }
    $script:GuestAgentLocks[$Vm] = [pscustomobject]@{ Stream = $fs; Depth = 1 }
}

function Exit-GuestAgentLock {
    param([Parameter(Mandatory)][string]$Vm)
    if (-not $script:GuestAgentLocks.ContainsKey($Vm)) { return }
    $l = $script:GuestAgentLocks[$Vm]
    $l.Depth--
    if ($l.Depth -gt 0) { return }
    try { $l.Stream.Dispose() } catch { }
    $script:GuestAgentLocks.Remove($Vm)
}

# Close-GuestAgentChannels -- called once by virutil.ps1 however the run ends.
# Nothing stays open between calls any more, so this only releases a lock a
# throw left held; the OS would release it at exit regardless.
function Close-GuestAgentChannels {
    foreach ($k in @($script:GuestAgentLocks.Keys)) {
        try { $script:GuestAgentLocks[$k].Stream.Dispose() } catch { }
    }
    $script:GuestAgentLocks = @{}
}

# --- the connection ---------------------------------------------------------
#
# A channel is the TCP client, its stream, and the one read that may still be
# outstanding on it. ReadAsync and Wait rather than a plain Read, and this is
# the difference between a timeout and a hang: a synchronous Read for a byte the
# guest is never going to send blocks forever and no deadline checked around it
# is ever reached. A read whose wait expires is kept rather than abandoned:
# a second ReadAsync on the same stream would race it, and the byte the first
# one eventually took -- often the sync's 0xFF -- would be lost to the reader.

# Connect-GuestAgent VM [-TimeoutMs N] -- a connected channel, or $null.
function Connect-GuestAgent {
    param([Parameter(Mandatory)][string]$Vm, [int]$TimeoutMs = 2000)
    $port = Get-GuestAgentPort $Vm
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        if (-not $tcp.ConnectAsync('127.0.0.1', $port).Wait($TimeoutMs)) {
            $tcp.Close()
            return $null
        }
    } catch {
        $tcp.Close()
        return $null
    }
    return [pscustomobject]@{
        Tcp = $tcp; Stream = $tcp.GetStream(); Buf = (New-Object byte[] 1); Pending = $null; Closed = $false
    }
}

function Close-GuestAgent {
    param($Chan)
    if ($null -eq $Chan) { return }
    try { $Chan.Stream.Dispose() } catch { }
    try { $Chan.Tcp.Close() } catch { }
}

# Send-GuestAgentBytes CHAN BYTES -- throws if the channel is gone.
function Send-GuestAgentBytes {
    param($Chan, [byte[]]$Bytes)
    $Chan.Stream.Write($Bytes, 0, $Bytes.Length)
    $Chan.Stream.Flush()
}

# A monotonic millisecond count that exists on both PowerShells.
#
# This was [Environment]::TickCount64, which is .NET Core only: the .NET
# Framework that Windows PowerShell 5.1 runs on has no such property, and
# reading a property that is not there throws under the
# $ErrorActionPreference = 'Stop' that virutil.ps1 sets. Every caller below sits
# inside a catch that turns any throw into a silent $null -- so on 5.1 the
# channel never opened and the failure was reported as "$Vm's QEMU guest agent
# is not answering", pointing at a qemu-ga that was running the whole time.
# Measured: virutil under pwsh 7 worked and the same command under 5.1 did not,
# against the same guest, seconds apart.
#
# A Stopwatch rather than [Environment]::TickCount, which is a 32-bit count
# that wraps about every 49.7 days -- PowerShell widens it to Int64 before the
# subtraction, so the wrap would not cancel out and a deadline computed across
# one would come out enormous.
$script:GuestAgentClock = [Diagnostics.Stopwatch]::StartNew()
function Get-GuestAgentTick { return $script:GuestAgentClock.ElapsedMilliseconds }

# One byte, or $null if none arrived before DEADLINE. Throws on a closed peer,
# which is not a timeout and must not be retried as one.
function Read-GuestAgentByte {
    param($Chan, [long]$Deadline)
    $remaining = $Deadline - (Get-GuestAgentTick)
    if ($remaining -le 0) { return $null }
    if ($null -eq $Chan.Pending) { $Chan.Pending = $Chan.Stream.ReadAsync($Chan.Buf, 0, 1) }
    if (-not $Chan.Pending.Wait([int]$remaining)) { return $null }
    $n = $Chan.Pending.Result
    $Chan.Pending = $null
    if ($n -eq 0) { $Chan.Closed = $true; throw 'the guest agent channel closed' }
    return $Chan.Buf[0]
}

# One newline-terminated line, as a string, or $null if DEADLINE passed first.
# A byte at a time because the reply is a line: a fixed-size read would either
# block for bytes that are not coming or swallow the start of the next reply.
# With -StopAtDelimiter an 0xFF, the sync delimiter, comes back on its own as
# [char]0xFF, ending whatever line it interrupted.
function Read-GuestAgentLine {
    param($Chan, [long]$Deadline, [switch]$StopAtDelimiter)
    $out = New-Object System.IO.MemoryStream
    while ($true) {
        $b = Read-GuestAgentByte $Chan $Deadline
        if ($null -eq $b) { return $null }
        if ($b -eq 0xFF -and $StopAtDelimiter) { return [char]0xFF }
        if ($b -eq 0x0A) { return [Text.Encoding]::UTF8.GetString($out.ToArray()) }
        $out.WriteByte($b)
    }
}

# Sync-GuestAgent CHAN TIMEOUTMS -- true once the stream is known to hold
# nothing older than this call.
#
# The synchronise is not optional politeness. A reply nobody read -- from a run
# that was interrupted, or from a guest that answered late -- is still on its
# way down the stream, and the next command would read it as its own. The
# documented fix is guest-sync-delimited: an 0xFF byte, which qemu-ga treats as
# "discard what you were parsing", then a request carrying an id. Its answer
# comes back behind an 0xFF of its own, and everything before the reply that
# carries *this* id is stale -- including the answers to earlier syncs, which is
# what a retry over a held channel finds: an id that does not match is skipped,
# not taken as failure.
function Sync-GuestAgent {
    param($Chan, [int]$TimeoutMs = 2000)
    $id = Get-Random -Minimum 1 -Maximum ([int]::MaxValue)
    # The delimiter is a raw 0xFF byte and is prepended as one. Putting U+00FF
    # in the string instead would encode as two bytes (0xC3 0xBF), which is not
    # the byte qemu-ga looks for, and the sync would silently never happen.
    $req = @([byte]0xFF) + [Text.Encoding]::UTF8.GetBytes(
        "{""execute"":""guest-sync-delimited"",""arguments"":{""id"":$id}}`n")
    try {
        Send-GuestAgentBytes $Chan $req
        $deadline = (Get-GuestAgentTick) + $TimeoutMs
        $delimited = $false
        while ($true) {
            $line = Read-GuestAgentLine $Chan $deadline -StopAtDelimiter
            if ($null -eq $line) { return $false }
            if ($line -eq [string][char]0xFF) { $delimited = $true; continue }
            if (-not $delimited) { continue }
            $delimited = $false
            try { $reply = $line | ConvertFrom-Json } catch { continue }
            if ($reply.PSObject.Properties.Name -contains 'return' -and "$($reply.return)" -eq "$id") {
                return $true
            }
        }
    } catch {
        # Not a timeout: the far end is gone, and the caller must not retry
        # over this channel.
        $Chan.Closed = $true
        return $false
    }
}

# Open-GuestAgent VM [-TimeoutMs N] -- a connected, synchronised channel, or
# $null. The caller closes it, and holds the lock around it.
function Open-GuestAgent {
    param([Parameter(Mandatory)][string]$Vm, [int]$TimeoutMs = 2000)
    $chan = Connect-GuestAgent $Vm -TimeoutMs $TimeoutMs
    if ($null -eq $chan) { return $null }
    if (-not (Sync-GuestAgent $chan $TimeoutMs)) {
        Close-GuestAgent $chan
        return $null
    }
    return $chan
}

# Invoke-GuestAgent VM COMMAND [ARGUMENTS] -- one round trip, the `return`
# member of the reply. Dies on an agent-level error rather than handing a caller
# an object with no `return` in it.
#
# TimeoutMs is the wait for *this* reply, not for the command: guest-exec
# returns a pid immediately and it is guest-exec-status that is polled, so
# nothing here ever waits out a long-running guest process. Nor does it count
# the wait for the lock, which is VIRUTILS_AGENT_WAIT's.
#
# The request carries no "id", and that is measured rather than overlooked: the
# qemu-ga a Windows XP guest runs (virtio-win's 7.6.2) refuses one -- "QMP input
# object member 'id' is unexpected" -- and so fails every command. Nor does it
# need one. Under the lock and behind a sync nothing else is on the stream, so
# the next line is this command's answer; libvirt sends none either.
function Invoke-GuestAgent {
    param(
        [Parameter(Mandatory)][string]$Vm,
        [Parameter(Mandatory)][string]$Command,
        $Arguments = $null,
        [int]$TimeoutMs = 10000
    )

    Enter-GuestAgentLock $Vm
    try {
        # The sync gets the call's own patience, not a short one: after a call
        # that gave up, the agent may still be working on that call's command,
        # and the sync's answer queues behind it.
        $chan = Open-GuestAgent $Vm -TimeoutMs $TimeoutMs
        if ($null -eq $chan) {
            Die @(
                "$Vm's QEMU guest agent is not answering on 127.0.0.1:$(Get-GuestAgentPort $Vm)."
                'The agent is what runs anything inside the guest, so nothing can'
                'proceed without it. Check that the domain is running, and that'
                'qemu-ga is running in the guest -- on a Windows guest that is the'
                "'QEMU Guest Agent' service, installed by virtio-win-guest-tools."
            )
        }
        try {
            $req = [ordered]@{ execute = $Command }
            if ($null -ne $Arguments) { $req['arguments'] = $Arguments }
            $json = ($req | ConvertTo-Json -Depth 10 -Compress) + "`n"
            try {
                Send-GuestAgentBytes $chan ([Text.Encoding]::UTF8.GetBytes($json))
            } catch {
                Die "$Vm's guest agent channel dropped while sending $Command`: $($_.Exception.Message)"
            }

            $line = $null
            try { $line = Read-GuestAgentLine $chan ((Get-GuestAgentTick) + $TimeoutMs) } catch {
                Die "$Vm's guest agent channel dropped while waiting for $Command"
            }
            if ($null -eq $line) {
                Die "$Vm's guest agent did not answer $Command within $($TimeoutMs)ms"
            }
            $reply = $line | ConvertFrom-Json
            $names = $reply.PSObject.Properties.Name
        } finally {
            Close-GuestAgent $chan
        }
    } finally {
        Exit-GuestAgentLock $Vm
    }

    if ($names -contains 'error') {
        Die "$Vm's guest agent refused $Command`: $($reply.error.desc)"
    }
    # A command with nothing to return -- guest-ping -- answers {"return": {}},
    # so an absent member is a protocol surprise rather than an empty result.
    if ($names -notcontains 'return') {
        Die "$Vm's guest agent answered $Command with neither a result nor an error"
    }
    return $reply.return
}

# Test-GuestAgent VM [SECONDS] -- true once the agent answers, waiting up to
# SECONDS for it. A sync, not the connection: the port accepts with nothing
# listening behind it in the guest.
#
# The retry is over one *held* connection rather than over fresh ones, and the
# lock is held for the whole wait. With no agent reading the port, qemu never
# notices a client that has gone, so every connect-and-drop would use up the one
# accept slot until the agent starts -- the "accepts two and then refuses" that
# was measured before there was a guest. Only a refused or dropped connection is
# replaced.
function Test-GuestAgent {
    param([Parameter(Mandatory)][string]$Vm, [int]$Seconds = 0)
    Enter-GuestAgentLock $Vm
    $chan = $null
    try {
        $deadline = (Get-GuestAgentTick) + [long]$Seconds * 1000
        while ($true) {
            if ($null -eq $chan) { $chan = Connect-GuestAgent $Vm -TimeoutMs 500 }
            if ($null -ne $chan) {
                if (Sync-GuestAgent $chan 2000) { return $true }
                if ($chan.Closed) { Close-GuestAgent $chan; $chan = $null }
            }
            if ((Get-GuestAgentTick) -ge $deadline) { return $false }
            Start-Sleep -Seconds 1
        }
    } finally {
        Close-GuestAgent $chan
        Exit-GuestAgentLock $Vm
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
