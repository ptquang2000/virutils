# PROTOTYPE -- THROWAWAY. Not a module; nothing sources this.
#
# The question, from docs/contract.md section 7: virutil's transfer layer has
# the host serve a tree and the guest fetch it. On a Linux host the share is
# anonymous. On a Windows host there is no anonymous by default, three ways out
# were written down, and none was picked -- because the facts to pick on were
# never measured. Section 7 says so itself: "Verify the client-side refusal
# against the actual guest before designing around it."
#
# This measures it. It publishes each candidate share against a running guest,
# tells the guest to fetch, and records what actually happens.
#
# Needs Administrator: New-SmbShare does, whatever the answer turns out to be.
#
#   powershell -File prototypes\xfer-windows-auth.ps1 -Vm win11
#
# It lives in prototypes/ rather than modules/ for a load-path reason, not a
# tidiness one: virutil.ps1 dot-sources every *.ps1 in modules/ that $MODULES
# does not list, so a prototype parked there runs on every virutil command.
#
# Everything it creates is torn down in the finally block. Nothing it learns
# belongs in this file -- fold the findings into docs/contract.md and delete it.

[CmdletBinding()]
param(
    [string] $Vm       = 'win11',
    [string] $HostAddr = '10.0.2.2',   # what the guest reaches the host at under slirp
    [switch] $KeepGoing                # do not stop at the first candidate that works
)

$ErrorActionPreference = 'Stop'
$virutil = Join-Path $PSScriptRoot '..\virutil.ps1'
$pwshExe = (Get-Process -Id $PID).Path   # the same edition this script runs under

$token   = -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
$share   = "vxp$token"
$account = "vxp-$token"

# Not $env:TEMP. Under elevation that came back as the 8.3 short path
# C:\Users\QUANG~1.PHA, which Remove-Item -Recurse refuses outright. This is
# also where the contract says transfer scratch belongs: section 3, <root>/tmp.
$stage = Join-Path $env:USERPROFILE ".virutils\tmp\vxp-$token"

$created = @{ share = $false; account = $false; stage = $false }
$results = [System.Collections.Generic.List[object]]::new()

function Note($m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Head($m) { Write-Host "`n$m" -ForegroundColor Cyan }

# Run a command inside the guest.
#
# As a CHILD PROCESS, not `& $virutil`. virutil writes the guest's own stdout
# with [Console]::Out.Write (modules/exec.ps1:91) and its diagnoses with
# [Console]::Error.WriteLine (modules/parser.ps1:53) -- deliberately, so a shell
# redirect can see them (modules/parser.ps1:50). Invoked in-process the console
# handle is this console rather than a pipe, so `2>&1 | Out-String` captures
# nothing and every probe comes back empty. That is how a guest which answered
# "True" was once reported here as unable to reach the host at all.
#
# A non-zero exit means virutil or the channel failed, and is thrown. It does
# NOT mean the guest's command failed: every probe below is written to swallow
# its own failure and exit 0, because a refused fetch is a result to record
# rather than an error to raise. Conflating the two is what threw away the first
# candidate-1 measurement this script ever took.
function Guest([string] $Cmd) {
    $out = (& $pwshExe -NoProfile -File $virutil exec ps $Vm -- $Cmd 2>&1 |
                Out-String).Trim()
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "virutil exited $code. It said:`n$out`nNothing below was measured, " +
              "and this is not a finding about SMB."
    }
    return $out
}

# Wrap a guest command so it always exits 0 and reports its own exit code as
# text, so Guest's throw stays reserved for virutil failing.
function Probe([string] $Body) {
    return "`$ErrorActionPreference='Continue'; " +
           "`$o = ($Body) 2>&1 | Out-String; " +
           "Write-Output ('RC=' + `$LASTEXITCODE); Write-Output `$o; exit 0"
}

# Drop any SMB session the guest still holds to this host.
#
# Not hygiene -- a precondition. Windows allows ONE credential per (client,
# server) pair: a second connection to the same server under a different user
# name is refused with system error 1219, whatever the share. Measured here the
# hard way. A run of this script that died between `net use` and its cleanup
# left the guest holding a session under an account the teardown had since
# deleted, and the NEXT run's candidates both failed at the logon -- not because
# either answer is wrong, but because the guest was still holding the last one.
#
# That is a finding about the transfer layer and not about this script: any
# design that mints a per-transfer identity inherits it, and so does a guest
# that merely has a drive mapped to the host for its own reasons.
function Clear-GuestConnections {
    $cmd = @"
`$ErrorActionPreference='Continue'
foreach (`$l in (net use)) {
    if (`$l -match '(\\\\\S+)') {
        `$p = `$matches[1]
        if (`$p -like '\\$HostAddr\*') { net use `$p /delete /y | Out-Null }
    }
}
Write-Output 'purged'
exit 0
"@
    Guest $cmd | Out-Null
}

function Record($Candidate, $Verdict, $Detail) {
    $results.Add([pscustomobject]@{
        Candidate = $Candidate; Verdict = $Verdict; Detail = $Detail
    })
    $colour = if ($Verdict -eq 'WORKS') { 'Green' } else { 'Yellow' }
    Write-Host "  => $Verdict -- $Detail" -ForegroundColor $colour
}

# --- preconditions ----------------------------------------------------------

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host @'
Not elevated. New-SmbShare needs Administrator, and so does New-LocalUser --
which is itself a finding: publishing the share needs the privilege whichever
credential answer wins, so the auth question does not decide whether push needs
elevation. Re-run this from an elevated shell to measure the rest.
'@ -ForegroundColor Yellow
    exit 1
}

Head "Preconditions"

$row = (& $pwshExe -NoProfile -File $virutil domain list 2>&1 | Out-String) -split "`n" |
           Where-Object { $_ -match "\b$Vm\b" }
if ("$row" -notmatch 'running') { throw "$Vm is not running; start it first." }
Note "$Vm is running"

# The channel, on its own and before anything that depends on it, so a dead
# agent is reported as a dead agent rather than as whichever probe ran first
# coming back empty.
& $pwshExe -NoProfile -File $virutil exec ping $Vm | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "the guest agent channel is down -- see the message above. Nothing " +
          "inside $Vm can be driven, so nothing below was measured."
}
Note "agent channel answers"

$reach = Guest "(Test-NetConnection -ComputerName $HostAddr -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded"
if ($reach -notmatch 'True') { throw "the guest cannot reach ${HostAddr}:445 -- nothing below can be measured." }
Note "guest reaches ${HostAddr}:445"

$cfg = Guest '(Get-SmbClientConfiguration).EnableInsecureGuestLogons, (Get-SmbClientConfiguration).RequireSecuritySignature'
Note "guest EnableInsecureGuestLogons / RequireSecuritySignature = $($cfg -replace '\s+', ' / ')"

Clear-GuestConnections
Note "cleared any SMB session the guest still held to $HostAddr"

# A payload with one recognisable file in it, so a successful fetch is provable
# rather than inferred from an exit code.
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$created.stage = $true
Set-Content -Path (Join-Path $stage 'marker.txt') -Value "written by the prototype, $token"
Note "staged a one-file payload at $stage"

try {

    # --- candidate 1: the straight port -- an anonymous share ---------------
    #
    # What the Linux host does. Note this measures the SERVER half only when the
    # guest's client protections have been relaxed by hand: with them at their
    # defaults the client refuses before the server is ever consulted, which is
    # the thing section 7 asked to have verified and which has been.

    Head "Candidate 1 -- anonymous share, no credential (the Linux-host port)"
    New-SmbShare -Name $share -Path $stage -ReadAccess 'Everyone' -Temporary | Out-Null
    $created.share = $true
    Note "published \\$HostAddr\$share, read access to Everyone"

    $out = Guest (Probe "net use \\$HostAddr\$share /user:Guest ''")
    Note (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 4) -join ' | ')

    if ($out -match 'RC=0') {
        Record 'anonymous' 'WORKS' 'the host served an anonymous logon and the guest took it'
    } else {
        Record 'anonymous' 'REFUSED' (($out -replace '\s+', ' ') -replace '^RC=\d+ ', '')
    }

    Guest (Probe "net use \\$HostAddr\$share /delete /y") | Out-Null
    Remove-SmbShare -Name $share -Force -ErrorAction SilentlyContinue
    $created.share = $false

    if (-not $KeepGoing -and $results[-1].Verdict -eq 'WORKS') { return }

    # --- candidate 2: a throwaway local account per transfer ----------------
    #
    # The option section 7 costs as "account churn on the host for every push".

    Head "Candidate 2 -- a throwaway local account, minted for this transfer"
    $pw = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    $sec = ConvertTo-SecureString $pw -AsPlainText -Force
    New-LocalUser -Name $account -Password $sec -AccountNeverExpires `
                  -Description 'virutil transfer prototype -- safe to delete' | Out-Null
    $created.account = $true
    Note "created local account $account"

    # The share ACL is not enough on its own, and this is the discovery that
    # candidate 2 actually cost: a share grant and the NTFS permissions on the
    # directory behind it are two separate gates, and the tighter one wins. With
    # the share granted to the account and nothing else done, the logon succeeds
    # and robocopy then fails reading the source with ERROR 5, access denied --
    # because the staged tree lives under %USERPROFILE% and a local account
    # minted seconds ago has no rights to anything in another user's profile.
    #
    # So "mint a throwaway account" is really "mint an account AND grant it
    # NTFS read on the payload", which is a second privileged mutation per
    # transfer, on a path inside the invoking user's own profile. Section 7
    # costs this option at account churn alone; it is that plus an ACL edit.
    icacls $stage /grant "${account}:(OI)(CI)(RX)" /T /Q | Out-Null
    Note "granted $account NTFS read on the staged tree (share ACL alone is not enough)"

    New-SmbShare -Name $share -Path $stage -ReadAccess $account -Temporary | Out-Null
    $created.share = $true
    Note "published \\$HostAddr\$share, read access to $account alone"

    $dst = "C:\vxp-$token"
    # Its own try. A candidate that throws mid-way must still leave a row saying
    # what was seen before the throw -- the first run of this lost candidate 2
    # entirely to an exception between the logon and the copy, and reported
    # nothing at all about the option it had just proved could log on.
    try {
        $out = Guest (Probe "net use \\$HostAddr\$share /user:$account '$pw'")
        Note "net use: $((($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' | '))"

        if ($out -notmatch 'RC=0') {
            Record 'throwaway account' 'REFUSED' (($out -replace '\s+', ' ') -replace '^RC=\d+ ', '')
        } else {
            $copy = Guest (Probe "robocopy \\$HostAddr\$share $dst /E /NJH /NJS /NP")
            Note "robocopy: $((($copy -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' | '))"
            $seen = Guest (Probe "Get-Content $dst\marker.txt")
            Note "marker: $(($seen -replace '\s+', ' '))"
            # The marker's whole sentence, and nothing else.
            #
            # Two wrong versions of this line came first, in both directions.
            # Matching the bare token was a false positive -- the token is in the
            # staged path, so "cannot find path C:\vxp-<token>\marker.txt"
            # contains it and a failed transfer read as WORKS. Adding an RC=0
            # requirement then made it a false negative, because Get-Content is a
            # cmdlet and cmdlets do not set $LASTEXITCODE, so Probe's RC= came
            # back empty on a run that had in fact copied the file.
            #
            # The content is the evidence. The sentence cannot appear in a
            # failure message, so it needs no exit code to corroborate it -- and
            # an exit code here would be the same mistake the contract warns
            # about for robocopy, whose 1 means "files copied", not "error".
            if ($seen -match [regex]::Escape("written by the prototype, $token")) {
                Record 'throwaway account' 'WORKS' "the marker file arrived in the guest at $dst"
            } else {
                Record 'throwaway account' 'FAILED' "logon succeeded, file did not arrive: $($copy -replace '\s+', ' ')"
            }
            Guest (Probe "net use \\$HostAddr\$share /delete /y") | Out-Null
            Guest (Probe "Remove-Item $dst -Recurse -Force") | Out-Null
        }
    } catch {
        Record 'throwaway account' 'ERRORED' "the logon succeeded; the run then threw: $($_.Exception.Message -replace '\s+', ' ')"
    }

    # --- candidate 3 is not measured, on purpose ---------------------------
    #
    # Handing the invoking user's own password to the guest in a payload. It
    # would work -- candidate 2 proves the mechanism -- and it puts a real
    # credential into a script on a virtio channel and into the guest's command
    # history. Section 7 already calls that unacceptable. Measuring it would
    # only confirm a mechanism candidate 2 has confirmed, at the price of
    # actually doing the thing. Left alone deliberately.

} finally {
    Head "Teardown"
    # Before the share goes, so the guest is not left holding a session to a
    # credential that is about to stop existing. See Clear-GuestConnections.
    try { Clear-GuestConnections; Note "dropped the guest's sessions to $HostAddr" } catch { }
    if ($created.share) {
        Remove-SmbShare -Name $share -Force -ErrorAction SilentlyContinue
        Note "removed share $share"
    }
    if ($created.account) {
        Remove-LocalUser -Name $account -ErrorAction SilentlyContinue
        Note "deleted account $account"
    }
    if ($created.stage -and (Test-Path -LiteralPath $stage)) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Note "cleared $stage"
    }

    # Whatever a previous run left behind when it died before its finally ran.
    # This is the failure mode the real module has to answer for, and seeing it
    # reported here is the point.
    $strays = @(Get-SmbShare -Name 'vxp*' -ErrorAction SilentlyContinue) +
              @(Get-LocalUser -Name 'vxp-*' -ErrorAction SilentlyContinue)
    if ($strays) {
        Write-Host "`n  STRAYS from an earlier run that did not finish:" -ForegroundColor Red
        $strays | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Red }
    }

    if ($results.Count) {
        Head "What was measured"
        $results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    }
}
