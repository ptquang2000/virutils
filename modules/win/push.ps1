# push -- copy a file or directory from the host into a guest's C: drive.
#
# The counterpart of modules/linux/push, and the same command grammar, because
# the grammar is contract. One transport, in modules/win/xfer.ps1: over the
# guest's own NIC, driven by the guest agent. The guest keeps running and sees
# no new device, and its copier takes only what differs from what it already
# has, so a re-push of a build that changed one file moves one file.
#
# What differs from the bash host is entirely on this side of the wire. There
# the payload is served by a private anonymous smbd bound to the one address
# that reaches the guest. Here it is served by the host's own SMB server, which
# cannot be anonymous and cannot be bound to an interface -- so each transfer
# mints a throwaway account, grants it on the share and on the filesystem, and
# destroys it at teardown, and publishing the share prompts once for
# Administrator. The guest side is byte-identical: the same payloads/push-*.ps1
# both drivers send.

function Get-PushUsage {
    @(
        'usage: virutil push VM SRC DST'
        ''
        '  VM   domain to copy into; it has to be running, since the copy is'
        '       delivered over its own network'
        '  SRC  host file or directory to copy'
        "  DST  guest path, relative to the guest's root -- C:\. A trailing"
        '       slash means a directory, exactly as with rsync. Backslashes'
        "       and a C:\ prefix are tolerated; '..' is refused."
        ''
        '  -h, --help              this message'
        ''
        'A directory source is copied recursively. The payload is served to the'
        'running guest, which fetches it itself with robocopy and so moves only'
        'what changed.'
        ''
        "On this host the share comes from the machine's own SMB server, so the"
        'transfer prompts once for Administrator and mints a throwaway local'
        'account that the guest authenticates with and that is destroyed when'
        'the transfer ends. See README.md, "On a Windows host".'
    )
}

function Push-Main {
    param([string[]]$Arguments)

    $vm = ''; $src = ''; $dst = ''; $seen = 0

    foreach ($a in @($Arguments)) {
        switch -Regex ($a) {
            '^(-h|--help)$' { Usage (Get-PushUsage) 0; break }
            # Refused rather than ignored, and with the bash driver's own
            # reasons: a script written against that host and run against this
            # one should be told the same thing. Silently accepting --live or
            # --disk would send the payload by a route the caller did not ask
            # for -- except that here neither route ever existed.
            '^--smb$'  { Die @('--smb is gone: delivering into the running guest'
                               'over SMB is what push does now. Drop the flag.'); break }
            '^--live$' { Die @('--live is gone: the HTTP transport it named has'
                               'been removed. Delivering into the running guest'
                               'is what push does now and uses SMB, which moves'
                               'only what changed; drop the flag.'); break }
            '^--disk$' { Die @("--disk is gone: writing the guest's disk image"
                               'has been removed. push delivers into the running'
                               "guest over its own network; drop the flag and"
                               'start the guest.'); break }
            '^-.+'     { Warn "unrecognised argument: $a"; Usage (Get-PushUsage) 1; break }
            default {
                switch ($seen) {
                    0 { $vm = $a }
                    1 { $src = $a }
                    2 { $dst = $a }
                    default { Warn "unexpected argument: $a"; Usage (Get-PushUsage) 1 }
                }
                $seen++
                break
            }
        }
    }
    if (-not $vm -or -not $src -or $seen -lt 3) { Usage (Get-PushUsage) 1 }

    # Read before anything is created and before anything is prompted for: a
    # source this user cannot read should be named as that, rather than
    # surfacing as a copy failure after an Administrator prompt.
    if (-not (Test-Path -LiteralPath $src)) { Die "source not found: $src" }
    $srcIsDir = Test-Path -LiteralPath $src -PathType Container
    Test-PushReadable $src

    Assert-XferReady $vm

    # The trailing slash rule is rsync's, which is where push borrowed it: it
    # has to be read off the argument the caller wrote, before normalising
    # strips it. A directory source always lands *in* a directory either way.
    $dstIsDir = $dst.EndsWith('/') -or $dst.EndsWith('\') -or $srcIsDir
    $rel = ConvertTo-GuestWindowsPath $dst 'destination'

    $base = Split-Path -Leaf ($src.TrimEnd('\', '/'))
    if (-not $base) { Die "could not work out a name to give $src in the guest" }

    # Where it lands over there, as the guest spells it. Two shapes, and which
    # one is the bash driver's rule character for character: a source named with
    # a trailing slash puts its *contents* into DST, and a source named without
    # one puts the directory itself under DST.
    if ($srcIsDir) {
        if ($src.EndsWith('/') -or $src.EndsWith('\')) { $guestDst = Join-GuestPath $rel '' }
        else                                           { $guestDst = Join-GuestPath $rel $base }
    } else {
        if ($dstIsDir) { $guestDst = Join-GuestPath $rel $base }
        else           { $guestDst = Join-GuestPath $rel '' }
    }

    [Console]::Out.WriteLine("push: $src -> $guestDst")

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $reported = Invoke-XferTransfer -Vm $vm -StageFrom $src -Body {
        param($Session, $Stage)
        if ($srcIsDir) {
            $text = Invoke-Payload 'push-dir.ps1' @{ SRC = $Session.Unc; DST = $guestDst }
        } else {
            $text = Invoke-Payload 'push-file.ps1' `
                @{ SRC = "$($Session.Unc)\$base"; DST = $guestDst }
        }
        $out = Invoke-GuestPsText $vm $text -Capture
        if ($script:VirutilExit -ne 0) { Push-Die $script:VirutilExit }
        return $out
    }
    $clock.Stop()

    Write-PushReport $vm $srcIsDir $reported $clock.ElapsedMilliseconds
}

# Join-GuestPath REL NAME -- an absolute guest path out of a normalised relative
# one and an optional last component. Cosmetic *and* addressed through, unlike
# the bash driver's push_show_dst, because on this side the same string is both
# what is printed and what goes into the payload.
function Join-GuestPath {
    param([string]$Rel, [string]$Name)
    $parts = @()
    if ($Rel)  { $parts += $Rel.Replace('/', '\') }
    if ($Name) { $parts += $Name }
    return 'C:\' + ($parts -join '\')
}

# Test-PushReadable SRC -- refuse a payload holding files this user cannot read,
# before anything is staged.
#
# The staging copy is made as the invoking user, so a file that user cannot read
# is one robocopy skips with an error partway through a tree it has otherwise
# copied -- and the message names the file but not the side. Same reasoning as
# the free-space check: name it before the spend. The bash driver's
# push_check_readable does this with `find ! -readable`.
function Test-PushReadable {
    param([string]$Src)
    if (-not (Test-Path -LiteralPath $Src -PathType Container)) {
        try { [IO.File]::OpenRead($Src).Dispose() }
        catch { Die "source not readable: $Src ($($_.Exception.Message))" }
        return
    }

    $bad = @()
    foreach ($f in Get-ChildItem -LiteralPath $Src -Recurse -File -Force -ErrorAction SilentlyContinue) {
        try { [IO.File]::OpenRead($f.FullName).Dispose() } catch { $bad += $f.FullName }
        if ($bad.Count -gt 10) { break }
    }
    if ($bad.Count -eq 0) { return }

    $shown = @($bad | Select-Object -First 10)
    if ($bad.Count -gt 10) { $shown += '  ... and more' }
    Die (@(
        "$Src holds files you cannot read, and the staging copy is made as you"
        '-- so they would be missing from what the guest is offered, and the'
        'copy would fail partway through with a message naming the file but not'
        'the side. Nothing was staged.'
        ''
    ) + $shown + @(
        ''
        'Check their mode and owner here on the host. Either fix those, or push'
        'a subdirectory that does not include them.'
    ))
}

# Write-PushReport VM ISDIR REPORTED MS -- what landed, and how fast. REPORTED
# is the guest's own line: "copied total ms" from a directory robocopy, or
# "bytes ms" from a file copy.
#
# The duration comes from the guest's stopwatch rather than from MS. MS is this
# host's wall clock and holds an agent round trip, a powershell starting up, an
# elevation prompt and a staging copy -- for a small payload, very nearly all of
# it -- so a figure computed from it would describe the overhead rather than the
# transfer.
function Write-PushReport {
    param([string]$Vm, [bool]$IsDir, [string]$Reported, [double]$Ms)

    $f = @("$Reported".Trim() -split '\s+')
    if ($IsDir) {
        $copied = if ($f.Count -ge 1 -and $f[0]) { [int]($f[0]) } else { 0 }
        $total  = if ($f.Count -ge 2) { [int]($f[1]) } else { 0 }
        $gms    = if ($f.Count -ge 3) { [double]($f[2]) } else { $Ms }
        $what = "$total file"
        if ($total -ne 1) { $what += 's' }
        if ($copied) { $what += ' present (some copied)' }
        else         { $what += ' present (all up to date)' }
        [Console]::Out.WriteLine("$Vm`: $what in $(Format-Duration $gms)")
        return
    }

    $bytes = if ($f.Count -ge 1 -and $f[0]) { [double]($f[0]) } else { 0 }
    $gms   = if ($f.Count -ge 2) { [double]($f[1]) } else { $Ms }
    $rate  = Format-Rate $bytes $gms
    $line  = "$Vm`: done ($(Format-Bytes $bytes)) in $(Format-Duration $gms)"
    if ($rate) { $line += " ($rate on the wire)" }
    [Console]::Out.WriteLine($line)
}

# Push-Die RC -- name what went wrong; the guest has already printed its own
# line above. The codes are section 5 of the contract and are the guest's, so
# this is the same table the bash driver's push_smb_die reads.
function Push-Die {
    param([int]$Rc)
    switch ($Rc) {
        93 { DieWith $Rc @('robocopy could not complete the copy in the guest (its'
                           'exit code is above). Anything it did copy is left where'
                           'it landed.') }
        92 { DieWith $Rc @('the guest could not create the destination directory;'
                           'its own message is above.') }
        default {
            DieWith $Rc @(
                "the guest failed to fetch the payload (exit $Rc); its own error"
                "is above. It had authenticated to the share, so a failure here"
                'is the copy rather than the credential.'
            )
        }
    }
}
