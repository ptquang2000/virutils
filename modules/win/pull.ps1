# pull -- copy a file or directory out of a guest's C: drive to the host.
#
# The counterpart of modules/linux/pull, and push's transport taken in the other
# direction: over the guest's own NIC, driven by the guest agent, with
# modules/win/xfer.ps1 underneath. The host serves a directory *writable* and
# the guest copies into it. The guest keeps running, sees no new device, and its
# disk image is not opened at all -- no snapshot, no overlay, no commit.
#
# The direction of the *transfer* is unchanged and is not negotiable: under
# user-mode NAT the host cannot open a connection to the guest, so the guest is
# the one that moves the bytes whichever way they are going. Only the direction
# of the share differs between push and pull.
#
# **The served directory is a staging copy of DST, not DST itself**, which is
# where this diverges from the bash driver. Serving DST in place would mean
# editing its filesystem ACL to admit a throwaway account and -- since a share
# on this host cannot be bound to an interface -- offering it on every network
# this machine is attached to. The staging tree is *seeded* from DST first, so
# the guest still sees what the host already holds and still sends only what
# differs; without the seed every pull would be a full pull. Two local copies
# buy back one network one. modules/win/xfer.ps1 says the same thing where
# staging lives.

function Get-PullUsage {
    @(
        'usage: virutil pull VM SRC DST'
        ''
        '  VM   domain to read from; it has to be running, since the copy is'
        '       driven from inside it'
        "  SRC  guest path, relative to the guest's root -- C:\. Wildcards are"
        '       allowed and match case-INsensitively, since the guest does the'
        "       matching itself. Backslashes and a C:\ prefix are tolerated;"
        "       '..' is refused."
        '  DST  host directory to copy into (created if needed)'
        ''
        '  -h, --help              this message'
        ''
        'A directory source is copied recursively. The guest copies it out'
        'itself with robocopy and so moves only what changed.'
        ''
        "On this host the share comes from the machine's own SMB server, so the"
        'transfer prompts once for Administrator and mints a throwaway local'
        'account that the guest authenticates with and that is destroyed when'
        'the transfer ends. See README.md, "On a Windows host".'
    )
}

function Pull-Main {
    param([string[]]$Arguments)

    $vm = ''; $src = ''; $dst = ''; $seen = 0

    foreach ($a in @($Arguments)) {
        switch -Regex ($a) {
            '^(-h|--help)$' { Usage (Get-PullUsage) 0; break }
            # Refused rather than ignored, with the bash driver's own reason: it
            # named a transport that has been removed, and accepting it quietly
            # would read by a route the caller did not ask for.
            '^--disk$' { Die @("--disk is gone: reading the guest's disk image"
                               'has been removed. pull copies out of the running'
                               'guest over its own network; drop the flag and'
                               'start the guest.'); break }
            '^-.+' { Warn "unrecognised argument: $a"; Usage (Get-PullUsage) 1; break }
            default {
                switch ($seen) {
                    0 { $vm = $a }
                    1 { $src = $a }
                    2 { $dst = $a }
                    default { Warn "unexpected argument: $a"; Usage (Get-PullUsage) 1 }
                }
                $seen++
                break
            }
        }
    }
    if (-not $vm -or -not $src -or $seen -lt 3) { Usage (Get-PullUsage) 1 }

    Assert-XferReady $vm

    $rel = ConvertTo-GuestWindowsPath $src 'source'
    if (-not $rel) { Die 'source may not be the root of C:\' }
    $guestSrc = 'C:\' + $rel.Replace('/', '\')

    # Created before anything is staged, and resolved to an absolute path: the
    # staging seed reads it and the copy back writes it, and a relative path
    # would be resolved against whatever directory each of those happened to
    # run in.
    if (-not (Test-Path -LiteralPath $dst)) {
        try { New-Item -ItemType Directory -Force -Path $dst | Out-Null }
        catch { Die "could not create destination: $dst ($($_.Exception.Message))" }
    }
    $dstFull = (Resolve-Path -LiteralPath $dst).ProviderPath

    [Console]::Out.WriteLine("pull: $guestSrc -> $dstFull")

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $reported = Invoke-XferTransfer -Vm $vm -StageFrom $dstFull -Write -Body {
        param($Session, $Stage)

        $text = Invoke-Payload 'pull.ps1' @{ SRC = $guestSrc; DST = $Session.Unc }
        $out = Invoke-GuestPsText $vm $text -Capture
        $rc  = $script:VirutilExit

        # Out of the staging tree and into the directory the caller named, while
        # the staging tree still exists -- teardown removes it as soon as this
        # returns. robocopy again, so the write back is itself a delta and a
        # re-pull that changed nothing rewrites nothing.
        #
        # It runs on the failure path too, and best-effort there. The bash
        # driver serves DST itself, so a copy that failed halfway leaves what it
        # managed in DST; staging would otherwise throw that away, and "anything
        # it did copy is left where it landed" is what pull says on both hosts.
        if ($rc -ne 0) {
            try { Invoke-XferRobocopy $Stage $dstFull 'partial copy' } catch { }
            Pull-Die $rc $guestSrc
        }
        Invoke-XferRobocopy $Stage $dstFull `
            "the guest copied the files out, but they could not be moved from the staging tree into $dstFull"
        return $out
    }
    $clock.Stop()

    Write-PullReport $vm $reported $clock.ElapsedMilliseconds
}

# Write-PullReport VM REPORTED MS -- what came back. REPORTED is the guest's own
# line, "files dirs ms". The duration is the guest's stopwatch rather than MS:
# MS is this host's wall clock and holds an agent round trip, a powershell
# starting up, an elevation prompt and two local copies, which for a small
# payload is very nearly all of it.
function Write-PullReport {
    param([string]$Vm, [string]$Reported, [double]$Ms)

    $f     = @("$Reported".Trim() -split '\s+')
    $files = if ($f.Count -ge 1 -and $f[0]) { [int]($f[0]) } else { 0 }
    $dirs  = if ($f.Count -ge 2) { [int]($f[1]) } else { 0 }
    $gms   = if ($f.Count -ge 3) { [double]($f[2]) } else { $Ms }

    $what = ''
    if ($files -or -not $dirs) {
        $what = "$files file"
        if ($files -ne 1) { $what += 's' }
    }
    if ($dirs) {
        if ($what) { $what += ' and ' }
        $what += "$dirs director"
        if ($dirs -eq 1) { $what += 'y' } else { $what += 'ies' }
    }
    [Console]::Out.WriteLine("$Vm`: $what pulled in $(Format-Duration $gms)")
}

# Pull-Die RC SRC -- name what went wrong; the guest has already printed its own
# line above. The codes are section 5 of the contract and are the guest's, so
# this is the same table the bash driver's pull_smb_die reads.
function Pull-Die {
    param([int]$Rc, [string]$GuestSrc)
    switch ($Rc) {
        94 { DieWith $Rc "no match in the guest for $GuestSrc" }
        95 { DieWith $Rc @('robocopy could not complete the copy in the guest (its'
                           'exit code is above). Anything it did copy is left'
                           'where it landed.') }
        default {
            DieWith $Rc @(
                "the guest failed to copy the files out (exit $Rc); its own error"
                'is above. It had authenticated to the share, so a failure here'
                'is the copy rather than the credential.'
            )
        }
    }
}
