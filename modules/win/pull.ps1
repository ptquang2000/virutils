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
        '  DST  host directory to copy into (created if needed) -- or, when SRC'
        '       is one file with no wildcard and DST does not exist and has no'
        '       trailing \, the file to write: pull VM logs\run.json out\run.json'
        ''
        '  -h, --help              this message'
        ''
        'A directory source is copied recursively. The guest copies it out'
        'itself with robocopy and so moves only what changed.'
        ''
        "On this host the share comes from the machine's own SMB server, so the"
        'transfer needs Administrator and mints a throwaway local account that'
        'the guest authenticates with and that is destroyed when the transfer'
        "ends. After 'virutil xfer setup' (once, elevated) that comes from a"
        'scheduled task with no prompt; without it the transfer prompts once.'
        'See README.md, "On a Windows host".'
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

    # Resolved to an absolute path before anything is staged: the staging seed
    # reads it and the copy back writes it, and a relative path would be
    # resolved against whatever directory each of those happened to run in.
    $dstFull = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $dst))

    # DST is a file or a directory by push's rule, which is rsync's and cp's:
    # one that does not exist yet, has no trailing slash, and is fed a single
    # file *is* that file. `pull VM logs\run.json out\run.json` used to make a
    # directory called run.json with run.json inside it. A wildcard SRC always
    # means a directory, however many files it turns out to match. Whether SRC
    # is a file is only known once the guest has copied it, so this decides
    # which way to stage and Move-PullResult decides where it lands.
    $asFile = -not (Test-Path -LiteralPath $dstFull) -and
              -not ($dst.EndsWith('\') -or $dst.EndsWith('/')) -and
              $guestSrc -notmatch '[*?]'
    $dstDir = if ($asFile) { Split-Path -Parent $dstFull } else { $dstFull }
    if (-not (Test-Path -LiteralPath $dstDir)) {
        try { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        catch { Die "could not create destination: $dstDir ($($_.Exception.Message))" }
    }

    [Console]::Out.WriteLine("pull: $guestSrc -> $dstFull")

    # A DST that does not exist yet has nothing to seed the staging tree with,
    # so it stages empty rather than from the parent directory.
    $stageArgs = if ($asFile) { @{ StageWith = {}; StageNeed = 0 } } else { @{ StageFrom = $dstFull } }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $reported = Invoke-XferTransfer -Vm $vm @stageArgs -Write -Body {
        param($Session, $Stage)

        $text = Invoke-Payload 'pull.ps1' @{ SRC = $guestSrc; DST = $Session.Unc }
        $out = Invoke-GuestPsText $vm $text -Capture
        $rc  = $script:VirutilExit

        # Out of the staging tree and into what the caller named, while the
        # staging tree still exists -- teardown removes it as soon as this
        # returns.
        #
        # It runs on the failure path too, and best-effort there. The bash
        # driver serves DST itself, so a copy that failed halfway leaves what it
        # managed in DST; staging would otherwise throw that away, and "anything
        # it did copy is left where it landed" is what pull says on both hosts.
        if ($rc -ne 0) {
            try { Move-PullResult $Stage $dstFull $asFile 'partial copy' } catch { }
            Pull-Die $rc $guestSrc
        }
        Move-PullResult $Stage $dstFull $asFile `
            "the guest copied the files out, but they could not be moved from the staging tree into $dstFull"
        return $out
    }
    $clock.Stop()

    Write-PullReport $vm $reported $clock.ElapsedMilliseconds
}

# Move-PullResult STAGE DST ASFILE WHAT -- what the guest copied into STAGE, put
# where the caller asked. With ASFILE and a single file in STAGE, that file
# becomes DST. Otherwise DST is a directory and STAGE is copied into it with
# robocopy, so the write back is itself a delta and a re-pull that changed
# nothing rewrites nothing. That covers a directory source named with a DST
# that did not exist, which gets the directory it always got.
function Move-PullResult {
    param([string]$Stage, [string]$Dst, [bool]$AsFile, [string]$What)
    $items = @(Get-ChildItem -LiteralPath $Stage -Force -ErrorAction SilentlyContinue)
    if ($AsFile -and $items.Count -eq 1 -and -not $items[0].PSIsContainer) {
        try { Copy-Item -LiteralPath $items[0].FullName -Destination $Dst -Force }
        catch { Die "$What ($($_.Exception.Message))" }
        return
    }
    if ($AsFile -and $items.Count -eq 0) { return }
    Invoke-XferRobocopy $Stage $Dst $What
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
