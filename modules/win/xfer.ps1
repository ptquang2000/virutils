# xfer -- the transport behind push and pull on a Windows host: over the guest's
# own NIC, driven by the guest agent. The counterpart of modules/linux/xfer, and
# almost none of that file survives the crossing; what survives is the thesis.
#
# **Bytes never go through the guest agent.** The channel is base64 inside JSON
# inside one argv entry -- roughly 98 KB per call -- so the host serves a tree
# and the guest fetches it with its own copier. robocopy does the delta, which
# is what makes a second push of a build where one file changed move one file.
#
# **The host serves and the guest fetches, never the inverse.** Every domain
# this driver creates is on user-mode slirp networking. Under slirp the host
# cannot open a connection to the guest at all; the guest can always reach the
# host, at a fixed address. That address is therefore a constant here and not
# something discovered per run -- there is no equivalent of the bash driver's
# route lookup, and no free port to pick either.
#
# What the bash file has that this one does not, and why:
#
#   xfer_smb_serve      a rootful smbd on port 445   -> New-SmbShare, below
#   xfer_rsyncd_serve   an unprivileged rsyncd       -> nothing; Windows guest only
#   xfer_host_addr      ip -o -4 route get           -> $script:XferHostAddr
#   xfer_pick_port      ss -ltn                      -> nothing; 445 is not ours to pick
#   xfer_privilege      refuse `sudo virutil`        -> an elevated helper, below
#   trap xfer_stop EXIT                              -> the helper waits on our pid
#
# Port 445 is why xfer_smb_serve cannot be translated at all: a Windows SMB
# client will not talk to another port, and on a Windows host LanmanServer
# already holds that one. The answer is not a second transport but the SMB
# server the host already runs.
#
# Not listed in $MODULES: this is a shared library, picked up by the loader's
# shared-libraries-first pass, the same way modules/linux/xfer is sourced ahead
# of push and pull in the bash tree.

Set-StrictMode -Version Latest

# --- constants --------------------------------------------------------------

# Where the guest reaches this host under user-mode NAT. A constant rather than
# a lookup: slirp's gateway is this address for every domain this driver
# creates, and a bridged domain is not supported here.
$script:XferHostAddr = '10.0.2.2'

# What makes "mine to reap" decidable without a state file. A Windows local
# account name is capped at 20 characters, so the prefix plus the token has to
# fit inside that: 4 + 12 leaves room to spare and still leaves the token wide
# enough that two live transfers will not collide.
$script:XferPrefix   = 'vxp-'
$script:XferTokenLen = 12
$script:XferPassLen  = 24

# Exit codes for the failures a Windows host introduces, which the guest-side
# codes in modules/win/payload.ps1 have no room for. Both are in section 5 of
# the contract.
#
# Two rather than one, and the split is not arbitrary: declining the elevation
# prompt is the developer's answer to a question rather than a fault, and a
# script wrapping `virutil push` has to be able to tell "I clicked No" from
# "SMB is broken".
$script:XferRcElevationDeclined = 98
$script:XferRcHostSetup         = 99

# How long to wait for the elevated helper to say whether it got the share up.
# Generous, because the consent prompt itself is inside that window and someone
# reaching for a smartcard or a second factor is not a failure.
$script:XferHelperReadyMs = 120000
# And how long to wait for it to finish tearing down once told to. Short: it has
# three things to remove and nothing to ask anyone.
$script:XferHelperStopMs = 30000

# --- tokens and credentials -------------------------------------------------
#
# A cryptographic RNG rather than Get-Random, and for the password that is the
# whole point: this is a credential, and Get-Random is a general-purpose
# generator seeded in a way nobody should have to reason about. The token gets
# the same treatment because it costs nothing to give it.

function Get-XferRandomString {
    param([int]$Length, [string]$Alphabet)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] $Length
        $rng.GetBytes($bytes)
        $out = New-Object char[] $Length
        for ($i = 0; $i -lt $Length; $i++) {
            $out[$i] = $Alphabet[$bytes[$i] % $Alphabet.Length]
        }
        return (-join $out)
    } finally { $rng.Dispose() }
}

# New-XferToken -- names one transfer. It is the share name and the account name
# both, so a sweep looking at either sees the same token.
#
# Lowercase, and without the characters that read as each other: a share name
# and a local account name are both case-insensitive, so mixing case would buy
# no entropy while making two spellings of one stray look like two strays.
function New-XferToken {
    return Get-XferRandomString $script:XferTokenLen 'abcdefghijkmnpqrstuvwxyz23456789'
}

# New-XferCredential TOKEN -- the throwaway the guest authenticates with.
#
# Alphanumeric only, and that is two constraints meeting rather than timidity.
# ConvertTo-PsLiteral would carry any character safely, but the renderer refuses
# a *value* spelled like a placeholder -- so a password that happened to contain
# @X@ would abort a transfer at random. And the guest hands this to `net use`,
# whose parsing of a bare argument is not something to stake a transfer on.
# 24 alphanumeric characters is about 143 bits, far past what a credential that
# exists for one transfer needs.
function New-XferCredential {
    param([Parameter(Mandatory)][string]$Token)
    return @{
        User     = "$($script:XferPrefix)$Token"
        Password = Get-XferRandomString $script:XferPassLen `
                       'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    }
}

# --- scratch ----------------------------------------------------------------
#
# Under the transfer scratch directory the contract's state layout reserves, and
# deliberately not under %TEMP%: under elevation that comes back as an 8.3 short
# path, which Remove-Item refuses to delete through. See Remove-VirutilsFile in
# modules/win/paths.ps1 for the measurement.

function Get-XferScratch {
    param([Parameter(Mandatory)][string]$Token)
    return (Join-Path $script:VirutilsTmpDir $Token)
}

function Get-XferStatusFile {
    param([Parameter(Mandatory)][string]$Token)
    return (Join-Path (Get-XferScratch $Token) 'status.json')
}

# Remove-XferTree PATH -- delete a directory and everything under it, or say
# nothing if it is already gone.
#
# [IO.Directory]::Delete rather than Remove-Item, for the reason
# Remove-VirutilsFile uses [IO.File]::Delete: Remove-Item cannot delete through
# a path whose segments include a genuine 8.3 alias, and a profile directory
# named `quang.phan` has one.
function Remove-XferTree {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    [IO.Directory]::Delete($Path, $true)
    return $true
}

# --- room for the staging copy ----------------------------------------------
#
# Split in two so the refusal is a pure function of two numbers: the lookup can
# fail or mean nothing on an odd volume, and a test should not have to own a
# disk to check that the message names both figures.

function Get-XferFreeSpace {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
        return (New-Object IO.DriveInfo($root)).AvailableFreeSpace
    } catch { return $null }
}

# Assert-XferRoom NEED FREE DIR -- refuse a staging copy that will not fit,
# before spending any of it. The bash driver checks at the equivalent point and
# for the equivalent reason: without it the failure mode is a half-copied tree
# and a copy error partway in, rather than a sentence.
#
# A FREE of $null is "could not tell", and is allowed through. Refusing a
# transfer because a volume would not answer would be worse than the failure
# this guards against.
function Assert-XferRoom {
    param([long]$Need, $Free, [string]$Dir)
    if ($null -eq $Free) { return }
    if ([long]$Free -gt $Need) { return }
    Die @(
        "staging this transfer needs about $(Format-Bytes $Need) in $Dir and"
        "there is $(Format-Bytes ([long]$Free)) free. Point VIRUTILS_TMP_DIR at"
        'somewhere with room, or move fewer files.'
    )
}

# Get-XferSize PATH -- how many bytes the staging copy will have to write.
function Get-XferSize {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return [long](Get-Item -LiteralPath $Path).Length
    }
    $total = [long]0
    foreach ($f in Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $total += [long]$f.Length
    }
    return $total
}

# --- staging ----------------------------------------------------------------
#
# **Every transfer stages.** The source is copied into the transfer's own
# scratch directory, that copy is what the share points at, and it is deleted at
# teardown.
#
# This diverges from the bash driver, which serves a directory source in place
# and stages only a single file, and the divergence is deliberate. Serving in
# place would mean editing the filesystem ACL of the developer's real source
# tree to admit a throwaway account, and -- since New-SmbShare takes no bind
# address, so a share is offered on every network this host is attached to --
# offering that tree to all of them. What is exposed should be a copy this
# driver owns and deletes. The price is one local copy per transfer, which the
# guest-side delta does not recover.
#
# pull stages too, and seeds its staging tree from the destination first. That
# is not symmetry for its own sake: the guest's robocopy decides what to send by
# comparing against what it can see in the share, so an empty staging tree would
# make every pull a full pull and cost pull the incrementality push keeps. The
# seed is a local copy against a network one.

# Copy-XferStage SRC STAGE -- put SRC's bytes where the share will point.
#
# robocopy rather than Copy-Item for a tree: it is on every Windows host, it is
# the same copier the guest runs, and it preserves timestamps. That last one is
# load-bearing rather than tidy -- the guest decides what to fetch by comparing
# timestamps, so a staged copy stamped with the current time is newer than
# everything in the guest and gets re-sent on every push, which quietly costs
# the transfer the incrementality that is its whole reason for existing. The
# bash driver spells the same concern `cp -p`.
function Copy-XferStage {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Stage)

    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        # One file, alone in a directory of its own, because a share is a
        # directory and a bare file has to be given one to sit in. Copy-Item
        # preserves the file's last-write time, which is what the guest compares.
        Copy-Item -LiteralPath $Source -Destination (Join-Path $Stage (Split-Path -Leaf $Source)) -Force
        return
    }
    Invoke-XferRobocopy $Source $Stage "could not stage $Source for transfer"
}

# Invoke-XferRobocopy FROM TO WHAT -- one host-side robocopy, with its bitmap
# exit code read the way the payloads read theirs: 0 means nothing needed
# copying, and only >= 8 is a failure.
function Invoke-XferRobocopy {
    param([string]$From, [string]$To, [string]$What)
    & robocopy $From $To /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Die "$What (robocopy exit $rc)" }
}

# --- strays -----------------------------------------------------------------
#
# Reaped on the next run rather than hunted for on this one. The prefix makes
# "mine" decidable without a state file, and the status file makes "still in
# use" decidable without a lock file.
#
# The decision lives here, in the unelevated parent, rather than in the elevated
# helper that carries it out: it is the part worth testing, and testing it here
# needs neither Administrator nor a machine to mutate. The helper is handed a
# list and removes it.

function Test-XferProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try { return ($null -ne (Get-Process -Id $ProcessId -ErrorAction Stop)) }
    catch { return $false }
}

# Get-XferOwnerPid TOKEN -- the process id in that transfer's status file, or
# $null when there is no such file or it says nothing useful.
function Get-XferOwnerPid {
    param([Parameter(Mandatory)][string]$Token)
    $file = Get-XferStatusFile $Token
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $s = (Get-Content -LiteralPath $file -Raw) | ConvertFrom-Json
        if ($null -eq $s) { return $null }
        if ($s.PSObject.Properties.Name -notcontains 'pid') { return $null }
        return [int]$s.pid
    } catch { return $null }
}

# Test-XferReapable TOKEN -- may this run remove the account and share that
# token names?
#
# No, if the process that owns it is still alive. Two concurrent transfers are
# otherwise completely independent -- each carries its own token, its own
# account and its own share -- so a sweep that took a live sibling's share out
# from under it would break a transfer for a reason the transport does not have.
# Refusing concurrency outright with a lock file was the alternative, and it
# would make a background pull block the next push.
#
# A token with no status file at all *is* reapable: that is a stray from a run
# that died before it got far enough to write one, which is exactly what a sweep
# is for. A live sibling cannot be mistaken for one, because the parent writes
# its own process id into that file before it mints anything.
function Test-XferReapable {
    param([Parameter(Mandatory)][string]$Token)
    $owner = Get-XferOwnerPid $Token
    if ($null -eq $owner) { return $true }
    return (-not (Test-XferProcessAlive $owner))
}

# Get-XferStrays [-Except TOKEN] -- the tokens of every account and share this
# driver left behind that nothing is still using. EXCEPT is this transfer's own
# token, which has no helper of its own at the moment this is called.
#
# Listing shares and local accounts needs no privilege; removing them does, and
# that half is the helper's.
function Get-XferStrays {
    param([string]$Except = '')
    $names = @()
    try { $names += @(Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } catch { }
    try { $names += @(Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } catch { }

    $out = @()
    foreach ($n in @($names | Select-Object -Unique)) {
        if (-not $n) { continue }
        if (-not $n.StartsWith($script:XferPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $token = $n.Substring($script:XferPrefix.Length)
        if (-not $token -or $token -eq $Except) { continue }
        if (Test-XferReapable $token) { $out += $token }
    }
    return ,@($out | Select-Object -Unique)
}

# --- the share, and the one place that elevates -----------------------------
#
# Publish-XferShare and Unpublish-XferShare are the only functions in this file
# that elevate, touch SMB or touch local accounts, and that is the seam: stub
# the pair and everything else here becomes testable with no Administrator and
# nothing on the machine mutated. It is a function pair rather than the
# helper-process boundary on purpose -- how elevation is achieved on Windows is
# an implementation detail, and "publish a share" is the operation worth naming,
# stubbing, and reading in one place.

# The elevated helper, written into the transfer's scratch directory at publish
# time rather than shipped as a file in modules/.
#
# Two reasons, and the first is mechanical: the loader dot-sources every
# modules/*.ps1 that $MODULES does not name, so a helper script living there
# would be dot-sourced into every run of every command. The second is that a
# script written beside the status file it answers through needs no argument
# telling it where it is, and working out its own path is the thing that goes
# wrong under elevation. The bash driver writes its smb.conf into scratch for
# the same kind of reason.
#
# A single-quoted here-string: nothing in it is expanded here, and everything in
# it is expanded over there. The C# below is assembled from an array of lines
# rather than from a here-string of its own, because a nested here-string
# terminator at column 0 would close this one.
$script:XferHelperSource = @'
# virutil transfer helper -- the elevated half of one transfer, and nothing
# else. Written here by Publish-XferShare in modules/win/xfer.ps1; not a module,
# and not on the module search path.
#
# It mints the throwaway account, publishes the share, grants that account on
# the filesystem too, reports through the status file, and then waits and takes
# all three away again. It never touches the guest, the payload or the bytes.
#
# It cannot talk back through a pipe: Start-Process -Verb RunAs requires
# ShellExecute and ShellExecute forbids stream redirection, so asking for both
# is a parameter-set error. Measured, not assumed. Hence the status file.
#
# Every value it needs comes down as an argument, including the account-name
# prefix: it is a separate process and cannot read $script:XferPrefix, and
# re-spelling `vxp-` here would mean a change to that one constant silently
# stopped the sweep from recognising its own strays.
param(
    [string]$Token,
    [string]$User,
    [string]$Prefix,
    [string]$Password,
    [string]$Path,
    [string]$Access,
    [int]$ParentPid,
    [string]$Scratch,
    [string]$Strays = ''
)

$ErrorActionPreference = 'Stop'

$share  = $Token
$status = Join-Path $Scratch 'status.json'
$done   = Join-Path $Scratch 'done'

function Write-Status {
    param([bool]$Ok, [string]$Detail = '')
    $body = @{ ok = $Ok; pid = $PID; detail = $Detail } | ConvertTo-Json -Compress
    # Written beside the file and copied into place, so the parent -- which is
    # polling for it -- can never read half a line of JSON and act on it.
    $part = "$status.part"
    Set-Content -LiteralPath $part -Value $body -Encoding ASCII
    [IO.File]::Copy($part, $status, $true)
    [IO.File]::Delete($part)
}

# The logon rights, set directly against the account's SID rather than through
# secedit. secedit exports, edits and reimports the machine's whole security
# policy, so a run that died halfway would leave that policy edited -- a far
# worse stray than an account. LsaAddAccountRights touches one SID.
#
# The grant is as necessary as the denials, and that is the easy half to leave
# out: "Access this computer from the network" is held by Administrators and
# Users, and this account is deliberately in neither, so without it the share
# would refuse the one logon it exists for.
$lsaSource = @(
    'using System;'
    'using System.Runtime.InteropServices;'
    'using System.Security.Principal;'
    'public static class VxpLsa {'
    '  [StructLayout(LayoutKind.Sequential)] struct US {'
    '    public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }'
    '  [StructLayout(LayoutKind.Sequential)] struct OA {'
    '    public int Length; public IntPtr Root; public IntPtr Name; public int Attributes;'
    '    public IntPtr Sd; public IntPtr Sqos; }'
    '  [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr s, ref OA a, int access, out IntPtr h);'
    '  [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr h, byte[] sid, US[] r, int n);'
    '  [DllImport("advapi32.dll")] static extern uint LsaRemoveAccountRights(IntPtr h, byte[] sid, bool all, US[] r, int n);'
    '  [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr h);'
    '  [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint s);'
    '  static US Str(string s) {'
    '    US u = new US();'
    '    u.Buffer = Marshal.StringToHGlobalUni(s);'
    '    u.Length = (ushort)(s.Length * 2);'
    '    u.MaximumLength = (ushort)(u.Length + 2);'
    '    return u; }'
    '  static byte[] Sid(string account) {'
    '    SecurityIdentifier sid = (SecurityIdentifier)(new NTAccount(account)).Translate(typeof(SecurityIdentifier));'
    '    byte[] b = new byte[sid.BinaryLength];'
    '    sid.GetBinaryForm(b, 0);'
    '    return b; }'
    '  public static void Set(string account, string[] rights, bool add) {'
    '    OA a = new OA();'
    '    a.Length = Marshal.SizeOf(typeof(OA));'
    '    IntPtr h;'
    '    uint st = LsaOpenPolicy(IntPtr.Zero, ref a, 0x00000FFF, out h);'
    '    if (st != 0) throw new Exception("LsaOpenPolicy failed: " + LsaNtStatusToWinError(st));'
    '    try {'
    '      US[] r = new US[rights.Length];'
    '      for (int i = 0; i < rights.Length; i++) r[i] = Str(rights[i]);'
    '      byte[] sid = Sid(account);'
    '      st = add ? LsaAddAccountRights(h, sid, r, r.Length)'
    '               : LsaRemoveAccountRights(h, sid, false, r, r.Length);'
    '      if (st != 0) throw new Exception("LsaAccountRights failed: " + LsaNtStatusToWinError(st));'
    '    } finally { LsaClose(h); } }'
    '}'
) -join "`n"
Add-Type -TypeDefinition $lsaSource -ErrorAction SilentlyContinue | Out-Null

$granted = @('SeNetworkLogonRight')
$denied  = @('SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight')

function Remove-Everything {
    try { Remove-SmbShare -Name $share -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
    try { [VxpLsa]::Set($User, ($granted + $denied), $false) } catch { }
    try { Remove-LocalUser -Name $User -ErrorAction SilentlyContinue } catch { }
}

$made = $false
try {
    # The sweep first. The parent decided what is reapable and this only carries
    # it out, so a live sibling is never in this list.
    foreach ($t in ($Strays -split ',')) {
        if (-not $t) { continue }
        try { Remove-SmbShare -Name $t -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        try { Remove-LocalUser -Name "$Prefix$t" -ErrorAction SilentlyContinue } catch { }
    }

    # In no group: New-LocalUser adds the account to none, and that is what
    # makes "this credential is worthless if it leaks" true rather than merely
    # likely. Its one right is the network logon granted below.
    $secret = ConvertTo-SecureString $Password -AsPlainText -Force
    New-LocalUser -Name $User -Password $secret -AccountNeverExpires `
        -UserMayNotChangePassword -Description "virutil transfer $Token" | Out-Null
    [VxpLsa]::Set($User, $granted, $true)
    [VxpLsa]::Set($User, $denied, $true)

    # -Temporary: the share does not survive a reboot, so the worst a crash this
    # cannot recover from leaves behind is something that goes away by itself.
    if ($Access -eq 'rw') {
        New-SmbShare -Name $share -Path $Path -ChangeAccess $User -Temporary | Out-Null
    } else {
        New-SmbShare -Name $share -Path $Path -ReadAccess $User -Temporary | Out-Null
    }

    # The share ACL and the filesystem ACL are two independent gates and the
    # tighter one wins. Measured on the prototype: with the share granted and
    # this not, the guest logs on successfully and then gets "ERROR 5 Access is
    # denied" reading the tree, because the staging directory is under a profile
    # an account minted seconds ago has no rights inside.
    $mask = 'RX'
    if ($Access -eq 'rw') { $mask = 'M' }
    $icacls = & icacls $Path /grant ("{0}:(OI)(CI){1}" -f $User, $mask) /T /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls on $Path failed: $icacls" }

    $made = $true
    Write-Status $true ''
} catch {
    try { Write-Status $false $_.Exception.Message } catch { }
}

if (-not $made) {
    # Nothing was necessarily created, but something may have been: the account
    # can exist with no share, or both with no ACL. Undo whatever is there.
    Remove-Everything
    exit 1
}

try {
    # **This is the crash-safe half.** Waiting on the *parent's* process rather
    # than only on a message means teardown fires on Ctrl-C, on an unhandled
    # exception, and on the run being killed while the agent hangs -- the
    # nearest thing Windows offers to the exit trap the bash transport relies
    # on. The done file is the ordinary path, and says "finished; do not wait
    # for my console to close".
    while ($true) {
        if (Test-Path -LiteralPath $done) { break }
        try { Get-Process -Id $ParentPid -ErrorAction Stop | Out-Null } catch { break }
        Start-Sleep -Milliseconds 250
    }
} finally {
    Remove-Everything
    # The staged copy goes with them. The parent removes it too, and whichever
    # gets there first is fine; this is the copy that still runs when the parent
    # is no longer around to.
    try { [IO.Directory]::Delete($Scratch, $true) } catch { }
}
'@

# Publish-XferShare TOKEN PATH [-Write] -- a share over PATH that exactly one
# throwaway account may reach, and a live helper holding it open. Returns the
# session every other function here takes.
#
# The elevation prompt is here, once per transfer, and nothing before this point
# has created anything or asked the developer for anything -- which is the whole
# reason the preconditions are checked first. Being asked to approve
# Administrator and *then* told the guest is not running is the worst available
# ordering.
function Publish-XferShare {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Write
    )

    $scratch = Get-XferScratch $Token
    $status  = Get-XferStatusFile $Token
    $cred    = New-XferCredential $Token

    # Our own process id into the status file before anything is minted, so a
    # concurrent transfer's sweep sees a live owner for this token during the
    # window before the helper has written its own. The helper replaces it.
    Set-Content -LiteralPath $status -Encoding ASCII `
        -Value (@{ ok = $false; pid = $PID; detail = 'starting' } | ConvertTo-Json -Compress)

    $helper = Join-Path $scratch 'helper.ps1'
    Set-Content -LiteralPath $helper -Value $script:XferHelperSource -Encoding UTF8

    $strays = Get-XferStrays -Except $Token

    # The host this run is already running on, rather than a search of the PATH:
    # a driver launched under Windows PowerShell 5.1 should elevate 5.1, and one
    # under PowerShell 7 should elevate 7.
    $shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    $access = 'ro'
    if ($Write) { $access = 'rw' }

    $argv = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $helper,
        '-Token', $Token,
        '-User', $cred.User,
        '-Prefix', $script:XferPrefix,
        '-Password', $cred.Password,
        '-Path', $Path,
        '-Access', $access,
        '-ParentPid', "$PID",
        '-Scratch', $scratch
    )
    # **-Strays only when there are some**, and this is measured rather than
    # tidy: Start-Process flattens ArgumentList into one command line, and an
    # empty element vanishes on the way. `-Strays ''` therefore arrives at the
    # helper as a `-Strays` with no value, which is a parameter binding error --
    # so the helper died before it could write a status file, and the parent sat
    # out its whole ready timeout waiting for one. Nothing in the diagnosis said
    # "argument"; it said the share had not appeared.
    if ($strays.Count -gt 0) { $argv += @('-Strays', ($strays -join ',')) }

    try {
        $helperProc = Start-Process -FilePath $shell -Verb RunAs -WindowStyle Hidden `
            -ArgumentList $argv -PassThru
    } catch {
        if (Test-XferElevationDeclined $_.Exception) {
            DieWith $script:XferRcElevationDeclined @(
                'the elevation prompt was declined, so no share was published and'
                "nothing was transferred. Publishing a share on the host's own"
                'SMB server needs Administrator; see the README.'
            )
        }
        DieWith $script:XferRcHostSetup `
            "could not start the elevated helper: $($_.Exception.Message)"
    }

    $reported = Wait-XferHelperReady $Token $helperProc
    return @{
        Token     = $Token
        Scratch   = $scratch
        Unc       = "\\$($script:XferHostAddr)\$Token"
        User      = $cred.User
        Password  = $cred.Password
        HelperPid = [int]$reported.pid
    }
}

# Test-XferElevationDeclined EXCEPTION -- was that the consent dialog being
# answered "No"?
#
# The inner exception chain and not the exception itself, which is the whole
# reason this is a function with a test rather than a cast inline. A declined
# `Start-Process -Verb RunAs` surfaces as an InvalidOperationException reading
# "This command cannot be run due to the error: The operation was canceled by
# the user", and the Win32Exception carrying ERROR_CANCELLED is wrapped inside
# it. A cast against the outer exception therefore never matches, and the one
# failure that has its own exit code -- so that a wrapping script can tell "I
# clicked No" from "SMB is broken" -- would have been reported as the other one.
function Test-XferElevationDeclined {
    param($Exception)
    $e = $Exception
    while ($null -ne $e) {
        $w = $e -as [ComponentModel.Win32Exception]
        if ($w -and $w.NativeErrorCode -eq 1223) { return $true }   # ERROR_CANCELLED
        $e = $e.InnerException
    }
    return $false
}

# Wait-XferHelperReady TOKEN [PROCESS] -- poll the status file the helper
# answers through. Dies with the helper's own diagnosis, which is the half that
# makes "could not publish the share" distinguishable from a guest problem.
#
# PROCESS is watched alongside the file, and it is what turns a fast failure
# into a fast report: a helper that dies before it can write anything -- a bad
# execution policy, a mis-bound argument, a host that will not start -- would
# otherwise be indistinguishable from a consent prompt nobody has answered yet,
# and the run would sit out the whole ready timeout to say so.
function Wait-XferHelperReady {
    param([Parameter(Mandatory)][string]$Token, $Process = $null)

    $status = Get-XferStatusFile $Token
    $clock  = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $script:XferHelperReadyMs) {
        Start-Sleep -Milliseconds 200
        $s = $null
        try { $s = (Get-Content -LiteralPath $status -Raw) | ConvertFrom-Json } catch { $s = $null }
        if ($null -ne $s -and $s.PSObject.Properties.Name -contains 'ok') {
            # Still the placeholder this process wrote before launching the helper.
            if ([int]$s.pid -ne $PID) {
                if ($s.ok) { return $s }
                DieWith $script:XferRcHostSetup @(
                    'the host could not publish the share for this transfer, so the'
                    'guest was never asked to fetch anything. Nothing was left behind.'
                    ''
                    "  $($s.detail)"
                )
            }
        }
        # Checked after the file, not before it: the helper writes its status
        # and then goes on living, but a helper that both succeeded and exited
        # in the same 200ms should still be read as having succeeded.
        if ($null -ne $Process -and $Process.HasExited) {
            DieWith $script:XferRcHostSetup @(
                "the elevated helper exited with $($Process.ExitCode) without saying"
                'what it had done, so no share was published and nothing was'
                'transferred. It runs in its own elevated console with nowhere to'
                'print; the run it was launched by is the only thing that can'
                'report this.'
            )
        }
    }
    DieWith $script:XferRcHostSetup @(
        "the elevated helper did not report within $([int]($script:XferHelperReadyMs / 1000))s."
        'It publishes the share this transfer serves, so nothing was'
        'transferred. If a consent prompt is still open, answer it and retry.'
    )
}

# Unpublish-XferShare SESSION -- tell the helper it is finished, and wait for it
# to say it is. The other half of the seam.
#
# The helper tears down in its own finally either way; this is what makes that
# happen now rather than when this process exits, so a `virutil push` that has
# printed its line is a machine with no share and no account on it.
function Unpublish-XferShare {
    param([Parameter(Mandatory)]$Session)

    $done = Join-Path $Session.Scratch 'done'
    try { Set-Content -LiteralPath $done -Value 'done' -Encoding ASCII } catch { }

    if (-not $Session.HelperPid) { return }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $script:XferHelperStopMs) {
        if (-not (Test-XferProcessAlive ([int]$Session.HelperPid))) { return }
        Start-Sleep -Milliseconds 200
    }
    Warn @(
        "the elevated helper (pid $($Session.HelperPid)) has not finished taking"
        "away the share and account named $($Session.Token). It will when it"
        'does; the next transfer sweeps it away if it never does.'
    )
}

# --- the guest side of the share --------------------------------------------

# Mount-XferGuest VM SESSION -- authenticate the guest to the share, so the
# copier payload that follows can address the UNC.
#
# Its own agent call rather than a credential hole in the three existing Windows
# payloads: those are shared byte-for-byte with the bash driver, which serves an
# anonymous share and would have to carry a hole it can never fill. See
# payloads/win/mount.ps1 and docs/contract.md section 6.
function Mount-XferGuest {
    param([Parameter(Mandatory)][string]$Vm, [Parameter(Mandatory)]$Session)

    $text = Invoke-Payload 'mount.ps1' @{
        UNC = $Session.Unc; USER = $Session.User; PASS = $Session.Password
    }
    Invoke-GuestPsText $Vm $text -Capture | Out-Null
    if ($script:VirutilExit -ne 0) {
        Die @(
            "$Vm could not authenticate to $($Session.Unc); its own error is"
            'above. The share is on this host and is published for one'
            'throwaway account, so this is an SMB refusal rather than a routing'
            "problem: check that the guest's Workstation service is running and"
            'that no policy there forbids the connection.'
        )
    }
}

# Dismount-XferGuest VM SESSION -- best effort, and never fatal.
#
# The next transfer's mount drops the guest's sessions unconditionally anyway,
# because it cannot trust that this ran. Reporting a failure here would turn a
# copy that landed into a command that says it did not.
#
# Which is also why the copier's exit code is put back afterwards. Every guest
# call leaves the guest's own code in $script:VirutilExit, and that is what
# virutil.ps1 exits with -- so an unmount that failed after a copy that worked
# would hand the caller a non-zero exit for a transfer that succeeded.
function Dismount-XferGuest {
    param([Parameter(Mandatory)][string]$Vm, [Parameter(Mandatory)]$Session)
    $keep = $script:VirutilExit
    try {
        $text = Invoke-Payload 'unmount.ps1' @{ UNC = $Session.Unc }
        Invoke-GuestPsText $Vm $text -Capture | Out-Null
    } catch { } finally {
        $script:VirutilExit = $keep
    }
}

# --- preconditions ----------------------------------------------------------

# Assert-XferReady VM -- everything that decides whether the transfer can happen
# at all, settled before anything is created and before anything is prompted
# for. The bash driver's xfer_check, in the same place and for the same reason.
function Assert-XferReady {
    param([Parameter(Mandatory)][string]$Vm)

    Assert-Domain $Vm
    if (-not (Test-DomainRunning $Vm)) {
        Die @(
            "$Vm is not running, and the copy is delivered over its own"
            "network. Start it with 'virutil domain start $Vm'."
        )
    }
    if (-not (Test-GuestAgent $Vm)) {
        Die @(
            "$Vm's QEMU guest agent is not answering, and the agent is what"
            'drives the copy from inside the guest. Check that qemu-ga is'
            "running there -- on a Windows guest that is the 'QEMU Guest Agent'"
            'service, installed by virtio-win-guest-tools.'
        )
    }

    # Asked rather than flagged, exactly as the bash driver asks -- see
    # Get-GuestOs in modules/win/guest.ps1.
    $os = Get-GuestOs $Vm
    if ($os -ne 'windows') {
        Die @(
            "$Vm reports a $os guest, and this host can only transfer to a"
            'Windows guest so far. The Linux side is payload selection against'
            'payloads that already exist plus one unmeasured fact, and it is a'
            'later pass; the bash driver has it today. See docs/contract.md'
            'section 7.'
        )
    }
}

# --- one transfer -----------------------------------------------------------

# Invoke-XferTransfer -- the whole shape of a transfer, once, so that push and
# pull supply only the part that differs.
#
# The nesting of the finally blocks is the order things have to be undone in,
# and each one runs however the run ends: the guest lets go of the share, then
# the share and the account go, then the staged copy. Every failure in this
# driver throws rather than exits precisely so that these run -- see Die in
# modules/win/parser.ps1.
#
# BODY is called with the session and the staging directory, and whatever it
# returns is what this returns. STAGEFROM is mandatory because every transfer
# stages -- pull's staging tree is seeded from its destination rather than left
# empty, so there is no shape of transfer that skips this.
function Invoke-XferTransfer {
    param(
        [Parameter(Mandatory)][string]$Vm,
        [Parameter(Mandatory)][string]$StageFrom,
        [switch]$Write,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    $token   = New-XferToken
    $scratch = Get-XferScratch $token
    $stage   = Join-Path $scratch 'share'

    # Before the copy begins, because staging is where the bytes get committed.
    Assert-XferRoom (Get-XferSize $StageFrom) `
                    (Get-XferFreeSpace $script:VirutilsTmpDir) `
                    $script:VirutilsTmpDir

    New-VirutilsDir $script:VirutilsTmpDir | Out-Null
    New-VirutilsDir $scratch | Out-Null
    New-VirutilsDir $stage | Out-Null

    try {
        Copy-XferStage $StageFrom $stage

        $session = Publish-XferShare $token $stage -Write:$Write
        try {
            Mount-XferGuest $Vm $session
            try {
                return (& $Body $session $stage)
            } finally {
                Dismount-XferGuest $Vm $session
            }
        } finally {
            Unpublish-XferShare $session
        }
    } finally {
        try { Remove-XferTree $scratch | Out-Null } catch { }
    }
}
