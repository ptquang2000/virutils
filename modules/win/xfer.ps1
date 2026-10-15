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
# Listed in $MODULES, which modules/linux/xfer is not, and only for the
# `virutil xfer` command at the bottom: setting up, once, the scheduled task
# that lets a transfer elevate without a UAC prompt. Everything above that is
# still the library push, pull and sync call, and none of them touches it while
# the loader is still loading -- only at run time, by which point every module
# is in.

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
# How long a helper started through the scheduled task gets to say it has
# started at all. There is no prompt on that path and no process handle either,
# so this is the only thing that turns "the task never ran it" -- a shell that
# was uninstalled, a task someone disabled -- into a report rather than the
# whole two-minute wait above. A cold pwsh under a virus scanner is seconds,
# not twenty of them.
$script:XferTaskStartMs = 20000
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
# **Every transfer stages.** The bytes are put into the transfer's own scratch
# directory, that directory is what the share points at, and it is deleted at
# teardown. push and pull put them there by copying a path; sync builds its
# delivery tree there a map rule at a time. See Invoke-XferTransfer.
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
#
# How elevation is achieved has two answers now, and Publish-XferShare picks:
#
#   the scheduled task   `virutil xfer setup` registered virutil-xfer-helper,
#                        once, from an elevated prompt. Starting it raises no
#                        prompt, which is the point: an unattended run (ralph,
#                        a fan-out session) otherwise stalls on a consent
#                        dialog nobody is there to answer.
#   the UAC prompt       Start-Process -Verb RunAs, once per transfer, which is
#                        what every transfer did before the task existed and
#                        what one still does on a host where setup never ran.
#
# Inside Publish-XferShare there are three more seams, one per thing that
# touches the machine -- Get-XferHelperTask, Start-XferHelperTask and
# Start-XferHelperPrompt -- so that which path is taken, what the helper is
# handed and how its pid comes back are testable without either path really
# elevating.

# The scheduled task, and where its copy of the helper lives.
#
# Under Program Files rather than beside the transfer, and that is the whole
# difference between the task and a UAC bypass anyone can use. A task's action
# is fixed when it is registered, but the file it runs is only as fixed as that
# file's ACL: a helper under %USERPROFILE% could be rewritten by any process
# running as this user, and the task would then run *that* elevated, without a
# prompt. Program Files is writable by Administrators only, so the task runs
# the text setup installed and nothing else, and that text does only what a
# transfer does (see the header of $script:XferHelperSource).
$script:XferTaskName   = 'virutil-xfer-helper'
$script:XferTaskDir    = Join-Path $env:ProgramFiles 'virutil'
$script:XferTaskHelper = Join-Path $script:XferTaskDir 'xfer-helper.ps1'

# The elevated helper, rendered from the text below at publish time (the prompt
# path) or at setup (the task path) rather than shipped as a file in modules/.
#
# Not a file in modules/ for a mechanical reason: the loader dot-sources every
# modules/*.ps1 that $MODULES does not name, so a helper script living there
# would be dot-sourced into every run of every command. The scratch root is
# baked into the text rather than worked out by the helper from its own path,
# because working out its own path is the thing that goes wrong under
# elevation, and because the installed copy does not live beside the transfer
# at all. The bash driver writes its smb.conf into scratch for the same kind of
# reason.
#
# A single-quoted here-string: nothing in it is expanded here, and everything in
# it is expanded over there. The C# below is assembled from an array of lines
# rather than from a here-string of its own, because a nested here-string
# terminator at column 0 would close this one.
#
# Two placeholders, @ROOT@ and @PREFIX@, are filled by Get-XferHelperText and
# nothing else is. There are two copies of this text in play and they are meant
# to be the same text: the one a prompted transfer writes into its scratch
# directory, and the one `virutil xfer setup` installs for the scheduled task.
$script:XferHelperSource = @'
# virutil transfer helper -- the elevated half of one transfer, and nothing
# else. Rendered by Get-XferHelperText in modules/win/xfer.ps1 and written
# either into one transfer's scratch directory (the UAC-prompt path) or under
# Program Files by `virutil xfer setup` (the scheduled-task path); not a module,
# and not on the module search path.
#
# It mints the throwaway account, publishes the share, grants that account on
# the filesystem too, reports through the status file, and then waits and takes
# all three away again. It never touches the guest, the payload or the bytes.
#
# It cannot talk back through a pipe: Start-Process -Verb RunAs requires
# ShellExecute and ShellExecute forbids stream redirection, so asking for both
# is a parameter-set error. Measured, not assumed. Hence the status file. A
# scheduled task has no pipe to offer either, so both paths answer the same way.
#
# **One argument, the token, and everything else is either baked in or derived
# from it.** The scheduled task runs this elevated with no prompt, for any
# process running as the user who set it up, and with whatever that process
# hands it as $(Arg0). So nothing a caller passes may choose what gets shared,
# which account gets minted or where the scratch directory is: the root and the
# account prefix were fixed when this text was rendered, the share is always
# <root>\<token>\share, and the account is always <prefix><token>. What does
# come from the caller -- the password, ro or rw, the pid to wait on, the strays
# to sweep -- is read from request.json in that directory and checked for shape
# before it is used. The worst a hostile caller can make this do is what a
# transfer does.
#
# The prefix is baked rather than re-spelled here for the reason it used to be
# an argument: this is a separate process and cannot read $script:XferPrefix,
# and spelling `vxp-` out a second time would mean a change to that one
# constant silently stopped the sweep from recognising its own strays.
param([string]$Token)

$ErrorActionPreference = 'Stop'

$Root   = '@ROOT@'
$Prefix = '@PREFIX@'

# The token's own alphabet (New-XferToken), and nothing that could climb out
# of the root: no separator, no dot, no drive.
if ($Token -notmatch '^[a-z0-9]{1,16}$') { exit 2 }

$Scratch = Join-Path $Root $Token
$Path    = Join-Path $Scratch 'share'
$User    = "$Prefix$Token"
$share   = $Token
$status  = Join-Path $Scratch 'status.json'
$done    = Join-Path $Scratch 'done'
$request = Join-Path $Scratch 'request.json'

# Everything under $Scratch was made by an unelevated process, and this one is
# about to write, grant and delete in there as Administrator. A junction in
# place of the scratch directory would point all three somewhere else, so it is
# refused before the first write. It is a check, not a lock -- a caller racing
# this could still swap the directory afterwards -- but that caller already had
# to be running as the user who set the task up.
function Test-Reparse {
    param([string]$P)
    $i = Get-Item -LiteralPath $P -Force -ErrorAction Stop
    return [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint)
}
try { if (Test-Reparse $Scratch) { exit 3 } } catch { exit 3 }

function Write-Status {
    param([bool]$Ok, [string]$Detail = '', [switch]$Started)
    $o = @{ ok = $Ok; pid = $PID; detail = $Detail }
    if ($Started) { $o.started = $true }
    $body = $o | ConvertTo-Json -Compress
    # Written beside the file and copied into place, so the parent -- which is
    # polling for it -- can never read half a line of JSON and act on it.
    $part = "$status.part"
    Set-Content -LiteralPath $part -Value $body -Encoding ASCII
    [IO.File]::Copy($part, $status, $true)
    [IO.File]::Delete($part)
}

# First, before anything that can fail: this process's own pid, so the parent
# can tell a helper that is working from one that died before it said anything.
# A task start hands the parent no process to watch, so this record is the only
# way it learns which one to.
Write-Status $false '' -Started

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
$ParentPid = 0
try {
    # What the parent decided, read once and then deleted: it holds the
    # password, and nothing needs it after this. Every field is checked for the
    # shape its producer gives it rather than trusted -- see the header.
    $req = (Get-Content -LiteralPath $request -Raw) | ConvertFrom-Json
    try { [IO.File]::Delete($request) } catch { }
    $Password  = [string]$req.password
    $Access    = [string]$req.access
    $ParentPid = [int]$req.parentPid
    $Strays    = @($req.strays | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[a-z0-9]{1,16}$' })
    if ($Password -notmatch '^[A-Za-z0-9]{16,64}$') { throw 'request.json: the password is not the shape New-XferCredential makes' }
    if ($Access -notin @('ro', 'rw'))               { throw "request.json: access is '$Access', not ro or rw" }
    if ($ParentPid -le 0)                           { throw 'request.json: no parent pid to wait on' }

    # The share and the ACL grant below both follow a junction, and icacls /T
    # walks the whole tree. Staging copies bytes with robocopy and Copy-Item,
    # neither of which leaves a reparse point behind, so there should be none in
    # it; one that is there was put there, and granting through it could hand
    # the throwaway account rights somewhere else entirely.
    if (Test-Reparse $Path) { throw "$Path is a reparse point; refusing to share it" }
    $walk = New-Object Collections.Generic.Stack[IO.DirectoryInfo]
    $walk.Push([IO.DirectoryInfo]::new($Path))
    while ($walk.Count -gt 0) {
        foreach ($e in $walk.Pop().EnumerateFileSystemInfos()) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$($e.FullName) is a reparse point; refusing to share a tree that contains one"
            }
            if ($e -is [IO.DirectoryInfo]) { $walk.Push($e) }
        }
    }

    # The sweep first. The parent decided what is reapable and this only carries
    # it out, so a live sibling is never in this list.
    foreach ($t in $Strays) {
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

# Get-XferHelperText [ROOT] -- the helper as it will run, for a scratch root.
#
# ROOT through GetFullPath because the helper is a different process with a
# different working directory, and under the task a different one again: a
# relative VIRUTILS_TMP_DIR has to mean here what it means to the run that
# rendered it. Quoted for a single-quoted literal, which is the one place it
# lands.
function Get-XferHelperText {
    param([string]$Root = $script:VirutilsTmpDir)
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $script:XferHelperSource.Replace('@ROOT@', $full.Replace("'", "''")).Replace('@PREFIX@', $script:XferPrefix)
}

# Test-XferHelperCurrent TEXT -- is the installed helper the one this run would
# have rendered?
#
# One comparison that answers two questions, which is why it is a comparison
# and not a version number. The helper changes when virutil is updated, and the
# root baked into it changes when VIRUTILS_TMP_DIR is moved; either way the task
# would run a helper that does not match this run, and in the second case one
# that looks for request.json in a directory this run never wrote. Line endings
# and the trailing newline are not differences: Set-Content adds one, and git
# may have checked this file out with either.
function Test-XferHelperCurrent {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return $false }
    $norm = { param($t) ($t -replace "`r", '').TrimEnd() }
    return ((& $norm $Text) -ceq (& $norm (Get-XferHelperText)))
}

# Get-XferHelperTask -- the registered task as a transfer needs to know it, or
# $null when there is none this user can see. The first seam.
#
# Through the Schedule.Service COM object rather than Get-ScheduledTask, because
# Start-XferHelperTask has to use it anyway (below) and the two should agree on
# what "the task" is. Reading needs no privilege: setup grants this user read
# and execute on it.
function Get-XferHelperTask {
    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $task = $svc.GetFolder('\').GetTask($script:XferTaskName)
    } catch { return $null }

    $shell = ''
    foreach ($a in $task.Definition.Actions) { $shell = [string]$a.Path; break }
    $text = $null
    try { $text = [IO.File]::ReadAllText($script:XferTaskHelper) } catch { }
    return @{
        Enabled    = [bool]$task.Enabled
        Shell      = $shell
        HelperText = $text
        LastResult = ('0x{0:X8}' -f $task.LastTaskResult)
    }
}

# Start-XferHelperTask TOKEN -- run the task for one transfer. The second seam.
#
# **The token goes in as the task's $(Arg0).** IRegisteredTask.Run takes
# parameters, and the Task Scheduler substitutes them into the action's
# arguments textually -- measured, with the substitution inside a path as well
# as standing alone. That is why it is the COM object here and not
# Start-ScheduledTask, which has no way to pass one.
#
# The alternatives were a fixed pointer file naming "the current transfer" and
# a queue directory the task drains, and both fail the same way: two transfers
# started at once. A pointer is overwritten by the second before the first
# task instance reads it, and a queue needs each instance to claim exactly one
# entry and a rule for an entry whose parent died before starting its task.
# A parameter is per start, so neither question exists -- and the task is
# registered to run instances in parallel, so the second start does not queue
# behind the first, whose helper lives as long as its transfer does.
function Start-XferHelperTask {
    param([Parameter(Mandatory)][string]$Token)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $task = $svc.GetFolder('\').GetTask($script:XferTaskName)
    $task.Run($Token) | Out-Null
}

# Start-XferHelperPrompt SHELL ARGV -- the UAC path, returning the process. The
# third seam, and the only one that can raise a consent dialog.
function Start-XferHelperPrompt {
    param([Parameter(Mandatory)][string]$Shell, [Parameter(Mandatory)][string[]]$Argv)
    return (Start-Process -FilePath $Shell -Verb RunAs -WindowStyle Hidden -ArgumentList $Argv -PassThru)
}

# Get-XferLaunch -- which of the two paths this transfer takes: @{ Via =
# 'task'|'prompt'; Why = a sentence when the task is there but cannot be used }.
#
# The task only when it is registered, enabled and running the helper this run
# would have rendered. Anything less falls back to the prompt rather than
# failing: a transfer that asks is a worse transfer than one that does not, but
# a much better one than a transfer that refuses because of how the host was
# set up. Not having run setup at all is said nowhere -- it is what every host
# did before the task existed -- but a task that is there and cannot be used is
# a setup someone did and is now not getting, so that is said.
function Get-XferLaunch {
    $task = Get-XferHelperTask
    if ($null -eq $task) { return @{ Via = 'prompt'; Why = '' } }
    if (-not $task.Enabled) {
        return @{ Via = 'prompt'; Why = @(
            "the scheduled task $($script:XferTaskName) is disabled, so this transfer"
            "asks for Administrator instead. Enable it, or run 'virutil xfer setup'"
            'again from an elevated PowerShell.'
        ) }
    }
    if (-not (Test-XferHelperCurrent $task.HelperText)) {
        return @{ Via = 'prompt'; Why = @(
            "the scheduled task $($script:XferTaskName) runs a helper that is not the one"
            'this virutil would use -- virutil was updated, or VIRUTILS_TMP_DIR moved,'
            "since 'virutil xfer setup' last ran -- so this transfer asks for"
            "Administrator instead. Run 'virutil xfer setup' again, elevated, to stop it."
        ) }
    }
    return @{ Via = 'task'; Why = '' }
}

# Write-XferRequest TOKEN CRED ACCESS STRAYS -- what the helper is told, in the
# file it reads it from: <scratch>\request.json.
#
# A file on both paths, not only the one that needs it. The task path has no
# command line to put these on beyond $(Arg0), and the prompt path's command
# line was where two things went wrong that a file cannot: the password was
# readable there by anything that lists processes, and Start-Process flattens
# ArgumentList so that an empty element vanishes -- a `-Strays ''` once arrived
# as a bare `-Strays`, a binding error, and the parent sat out its whole ready
# timeout for a helper that had died before it could say why.
#
# No ACL of its own. It is in this user's scratch directory, the password it
# carries is a per-transfer throwaway's, and until this file existed it was on
# a command line anyone on the machine could read. The helper deletes it once
# read.
function Write-XferRequest {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)]$Credential,
        [Parameter(Mandatory)][string]$Access,
        [string[]]$Strays = @()
    )
    $body = [ordered]@{
        password  = $Credential.Password
        access    = $Access
        parentPid = $PID
        strays    = @($Strays | Where-Object { $_ })
    } | ConvertTo-Json -Compress
    $file = Join-Path (Get-XferScratch $Token) 'request.json'
    Set-Content -LiteralPath $file -Value $body -Encoding ASCII
    return $file
}

# Publish-XferShare TOKEN PATH [-Write] -- a share over PATH that exactly one
# throwaway account may reach, and a live helper holding it open. Returns the
# session every other function here takes.
#
# Elevation is here, once per transfer -- through the task when setup has run,
# and as a UAC prompt when it has not -- and nothing before this point has
# created anything or asked the developer for anything. That is the whole
# reason the preconditions are checked first: being asked to approve
# Administrator and *then* told the guest is not running is the worst
# available ordering.
#
# PATH is always the transfer's own <scratch>\share, and the helper no longer
# takes it as an argument: it derives the same path from the token, so that a
# caller of the task cannot choose what gets shared. Anything else here is a
# bug in this file, and is said as one rather than published.
function Publish-XferShare {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Write
    )

    $scratch = Get-XferScratch $Token
    $status  = Get-XferStatusFile $Token
    $cred    = New-XferCredential $Token

    if ($Path -ne (Join-Path $scratch 'share')) {
        Die "internal: a transfer shares its own staging directory, not $Path"
    }

    # Our own process id into the status file before anything is minted, so a
    # concurrent transfer's sweep sees a live owner for this token during the
    # window before the helper has written its own. The helper replaces it.
    Set-Content -LiteralPath $status -Encoding ASCII `
        -Value (@{ ok = $false; pid = $PID; detail = 'starting' } | ConvertTo-Json -Compress)

    $access = 'ro'
    if ($Write) { $access = 'rw' }
    Write-XferRequest $Token $cred $access (Get-XferStrays -Except $Token) | Out-Null

    $launch = Get-XferLaunch
    if ($launch.Why) { Warn $launch.Why }

    $proc = $null
    if ($launch.Via -eq 'task') {
        try {
            Start-XferHelperTask $Token
        } catch {
            # Registered and current but would not start for this user -- most
            # likely a task someone else's setup registered, whose ACL admits
            # them and not us. The prompt still works, so it is the fallback.
            Warn @(
                "could not start the scheduled task $($script:XferTaskName):"
                "  $($_.Exception.Message)"
                'so this transfer asks for Administrator instead.'
            )
            $launch.Via = 'prompt'
        }
    }
    if ($launch.Via -eq 'prompt') {
        $helper = Join-Path $scratch 'helper.ps1'
        Set-Content -LiteralPath $helper -Value (Get-XferHelperText) -Encoding UTF8

        # The host this run is already running on, rather than a search of the
        # PATH: a driver launched under Windows PowerShell 5.1 should elevate
        # 5.1, and one under PowerShell 7 should elevate 7. The task path made
        # the same choice once, at setup, and recorded it in the task's action.
        $shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $argv = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $helper, '-Token', $Token
        )
        try {
            $proc = Start-XferHelperPrompt $shell $argv
        } catch {
            if (Test-XferElevationDeclined $_.Exception) {
                DieWith $script:XferRcElevationDeclined @(
                    'the elevation prompt was declined, so no share was published and'
                    "nothing was transferred. Publishing a share on the host's own"
                    "SMB server needs Administrator. 'virutil xfer setup', run once"
                    'from an elevated PowerShell, makes transfers stop asking; see'
                    'the README.'
                )
            }
            DieWith $script:XferRcHostSetup `
                "could not start the elevated helper: $($_.Exception.Message)"
        }
    }

    # The helper's pid comes back through the status file on both paths and is
    # the only thing Unpublish-XferShare waits on. A task start returns no
    # process at all, and even the prompt's process is not worth keeping past
    # this call: the status file is where the helper says who it is.
    $reported = Wait-XferHelperReady $Token -Process $proc -Via $launch.Via
    return @{
        Token     = $Token
        Scratch   = $scratch
        Unc       = "\\$($script:XferHostAddr)\$Token"
        User      = $cred.User
        Password  = $cred.Password
        HelperPid = [int]$reported.pid
        Via       = $launch.Via
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
#
# **And under PowerShell 7 there is no inner exception at all.** Its
# Start-Process catches the Win32Exception and throws a fresh
# InvalidOperationException carrying only the message -- measured, with a
# missing executable: one exception, no InnerException. So a declined (or
# timed-out: UAC cancels an unanswered dialog after about two minutes) prompt
# exited 99 under pwsh 7. What survives is the text, and the text is the
# system's own for ERROR_CANCELLED, localised the same way pwsh's copy of it
# is -- so the match is against that, asked of Windows rather than spelled in
# English here.
function Test-XferElevationDeclined {
    param($Exception)
    $cancelled = ([ComponentModel.Win32Exception]::new(1223)).Message.TrimEnd('.')
    $e = $Exception
    while ($null -ne $e) {
        $w = $e -as [ComponentModel.Win32Exception]
        if ($w -and $w.NativeErrorCode -eq 1223) { return $true }   # ERROR_CANCELLED
        if ($cancelled -and $e.Message -and $e.Message.Contains($cancelled)) { return $true }
        $e = $e.InnerException
    }
    return $false
}

# Read-XferHelperStatus TOKEN -- what the helper has said so far, or $null when
# it has said nothing: no file, half a file, or still the placeholder this
# process wrote before starting it. Otherwise @{ ok; pid; detail; started },
# where `started` is the helper's first record -- "I am running, and this is
# my pid" -- and not yet an answer.
function Read-XferHelperStatus {
    param([Parameter(Mandatory)][string]$Token)
    $s = $null
    try { $s = (Get-Content -LiteralPath (Get-XferStatusFile $Token) -Raw) | ConvertFrom-Json } catch { return $null }
    if ($null -eq $s) { return $null }
    $names = @($s.PSObject.Properties.Name)
    if ($names -notcontains 'ok' -or $names -notcontains 'pid') { return $null }
    if ([int]$s.pid -eq $PID) { return $null }
    return @{
        ok      = [bool]$s.ok
        pid     = [int]$s.pid
        detail  = $(if ($names -contains 'detail') { [string]$s.detail } else { '' })
        started = ($names -contains 'started')
    }
}

# Wait-XferHelperReady TOKEN [-Process P] [-Via task|prompt] -- poll the status
# file the helper answers through. Dies with the helper's own diagnosis, which
# is the half that makes "could not publish the share" distinguishable from a
# guest problem.
#
# **A helper that dies is reported when it dies, not at the timeout**, and there
# are two ways to know it has. PROCESS, on the prompt path, is the one the
# prompt handed back. On the task path there is no process handle at all, so
# the helper's own first record is what names the pid to watch -- and a helper
# that never got far enough to write even that is caught by
# $script:XferTaskStartMs instead. Without either, a helper killed by a bad
# execution policy, a missing shell or an argument it refused would look
# exactly like a consent prompt nobody has answered yet, and the run would sit
# out the whole ready timeout to say so.
function Wait-XferHelperReady {
    param([Parameter(Mandatory)][string]$Token, $Process = $null, [string]$Via = 'prompt')

    # An answer is final either way: the share is up, or the helper says why not.
    $answer = {
        param($s)
        if ($s.ok) { return $s }
        DieWith $script:XferRcHostSetup @(
            'the host could not publish the share for this transfer, so the'
            'guest was never asked to fetch anything. Nothing was left behind.'
            ''
            "  $($s.detail)"
        )
    }

    $helperPid = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $script:XferHelperReadyMs) {
        Start-Sleep -Milliseconds 200
        $s = Read-XferHelperStatus $Token
        if ($null -ne $s -and -not $s.started) { return (& $answer $s) }
        if ($null -ne $s) { $helperPid = $s.pid }

        $exited = $null
        if ($null -ne $Process -and $Process.HasExited) {
            $exited = "exited with $($Process.ExitCode)"
        } elseif ($helperPid -gt 0 -and -not (Test-XferProcessAlive $helperPid)) {
            $exited = "(pid $helperPid) exited"
        }
        if ($exited) {
            # One more look, because the order is write-then-exit: a helper that
            # failed, said why, and exited inside the last 200ms has said
            # something, and its own reason beats this one.
            $s = Read-XferHelperStatus $Token
            if ($null -ne $s -and -not $s.started) { return (& $answer $s) }
            DieWith $script:XferRcHostSetup @(
                "the elevated helper $exited without saying what it had done, so"
                'no share was published and nothing was transferred. It runs'
                'elevated with nowhere to print; the run it was started by is'
                'the only thing that can report this.'
            )
        }

        if ($Via -eq 'task' -and $helperPid -eq 0 -and
            $clock.ElapsedMilliseconds -ge $script:XferTaskStartMs) {
            $last = 'unknown'
            try { $t = Get-XferHelperTask; if ($t) { $last = $t.LastResult } } catch { }
            DieWith $script:XferRcHostSetup @(
                "the scheduled task $($script:XferTaskName) was started, but its helper"
                "had not begun within $([int]($script:XferTaskStartMs / 1000))s, so no share was published and nothing"
                "was transferred. The task's last result is $last; Task Scheduler's"
                "history for it says more. 'virutil xfer status' checks the setup."
            )
        }
    }

    if ($Via -eq 'task') {
        DieWith $script:XferRcHostSetup @(
            "the elevated helper started by $($script:XferTaskName) did not report"
            "within $([int]($script:XferHelperReadyMs / 1000))s. It publishes the share this transfer serves, so"
            'nothing was transferred.'
        )
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
# returns is what this returns.
#
# **Every transfer stages, and says where the staged bytes come from.** There
# are two ways to say it and exactly one has to be given:
#
#   -StageFrom PATH    copy PATH into the staging directory. push's source and
#                      pull's destination seed, and the reason pull's is not
#                      left empty is above.
#   -StageWith BLOCK   call BLOCK with the staging directory and let it put the
#                      bytes there itself, with -StageNeed saying how many to
#                      check for first.
#
# The second exists for sync, whose delivery tree is *built* rather than copied:
# its map rules already write one file at a time into a layout that mirrors the
# guest's root, so that layout can be written straight into the directory the
# share will point at. Making sync build somewhere else and hand the result over
# as -StageFrom would keep this signature and cost a second full local copy of
# the delivery -- which for a build tree is the expensive half of the run.
#
# Neither and both are refused rather than defaulted. A transfer that staged
# nothing would publish an empty share and report a successful delivery of no
# files, which is the one failure here that looks like a success.
function Invoke-XferTransfer {
    param(
        [Parameter(Mandatory)][string]$Vm,
        [string]$StageFrom,
        [scriptblock]$StageWith,
        [long]$StageNeed = 0,
        [switch]$Write,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    if ($StageFrom -and $StageWith) {
        Die 'internal: a transfer stages from a path or with a builder, not both'
    }
    if (-not $StageFrom -and -not $StageWith) {
        Die 'internal: a transfer needs -StageFrom or -StageWith'
    }

    $token   = New-XferToken
    $scratch = Get-XferScratch $token
    $stage   = Join-Path $scratch 'share'

    # Before the copy begins, because staging is where the bytes get committed.
    # A builder is priced by its caller, which is the only side that knows what
    # it is about to write.
    $need = if ($StageFrom) { Get-XferSize $StageFrom } else { $StageNeed }
    Assert-XferRoom $need `
                    (Get-XferFreeSpace $script:VirutilsTmpDir) `
                    $script:VirutilsTmpDir

    New-VirutilsDir $script:VirutilsTmpDir | Out-Null
    New-VirutilsDir $scratch | Out-Null
    New-VirutilsDir $stage | Out-Null

    try {
        # Before the share is published, either way: an elevation prompt that
        # arrives and is then followed by "nothing matched" is the worst
        # available ordering, and a builder is the one staging step that can
        # decide there is nothing to send.
        if ($StageFrom) { Copy-XferStage $StageFrom $stage }
        else            { & $StageWith $stage | Out-Null }

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

# --- virutil xfer: the scheduled task, set up once --------------------------
#
#   virutil xfer setup    register the task and install its helper (elevated)
#   virutil xfer remove   take both away again (elevated)
#   virutil xfer status   which path a transfer would take, and why
#
# A Windows-host command, and the only one in this driver with no counterpart
# on the other side of contract section 2: a Linux host's transport has no
# elevation to arrange, because its smbd is the bash driver's own. The bash
# driver refuses `xfer` by name for that reason.
#
# A module of its own rather than a flag on push, pull or sync, because what it
# changes is the host rather than one transfer, and because it is the one step
# in the whole transfer story that *has* to be done by a person at an elevated
# prompt. Spelling that as a separate command makes it impossible to hide
# inside a run that was meant to be unattended.

function Get-XferUsage {
    @(
        'usage: virutil xfer setup'
        '       virutil xfer remove'
        '       virutil xfer status'
        ''
        "  push, pull, sync and ui setup publish a share on this machine's own"
        '  SMB server, which needs Administrator. Without setup, each transfer'
        '  asks for it with a UAC prompt -- which an unattended run cannot'
        "  answer. setup registers a scheduled task, $($script:XferTaskName), that"
        '  runs the elevated half of a transfer as you with highest privileges,'
        '  on demand only, startable by you alone; a transfer starts it instead'
        '  of prompting.'
        ''
        '  setup    register the task and install its helper under'
        "           $($script:XferTaskDir). Once, from an elevated PowerShell,"
        '           as the user who runs the transfers. Again after updating'
        '           virutil or moving VIRUTILS_TMP_DIR -- until then transfers'
        '           fall back to the prompt, and say why.'
        '  remove   unregister the task and delete its helper. Elevated.'
        '  status   whether transfers will prompt, and why. Exits 0 when they'
        '           will not, 1 when they will.'
        ''
        '  -h, --help     this message'
    )
}

# Test-XferElevated -- is this process holding an Administrator token? Not
# "is this user an administrator": under UAC an administrator's ordinary shell
# holds a filtered token, and that is the shell this has to refuse.
function Test-XferElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Get-XferTaskArguments HELPER -- the action's arguments, with the token left as
# $(Arg0) for the Task Scheduler to fill per start (see Start-XferHelperTask).
# -WindowStyle Hidden because the task runs on the user's desktop with an
# interactive token, and a console flashing up for every transfer is a cost.
function Get-XferTaskArguments {
    param([Parameter(Mandatory)][string]$Helper)
    return "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Helper`" -Token `$(Arg0)"
}

# Get-XferTaskSddl SID -- who may do what to the task. SYSTEM and Administrators
# own it; the one user it runs as may read and run it, and no one else may
# even see it.
#
# Read-and-run and not more, and that is the half that matters: a user who
# could *write* the task could point its action at anything and have that run
# elevated with no prompt. Registered with TASK_DONT_ADD_PRINCIPAL_ACE, because
# the scheduler otherwise adds an entry of its own for the principal, and this
# list is meant to be the whole list.
function Get-XferTaskSddl {
    param([Parameter(Mandatory)][string]$Sid)
    return "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;$Sid)"
}

# Invoke-XferSetup -- register the task and install the helper it runs.
# Idempotent: a second run replaces both, which is also how a stale helper is
# brought up to date.
#
# Refused unelevated rather than self-elevating. One prompt, the developer's
# own, at an elevated PowerShell they opened for it, is the cost of every later
# transfer asking for none; and a setup that elevated itself would run in a
# window of its own with nowhere to report what it did.
function Invoke-XferSetup {
    if (-not (Test-XferElevated)) {
        Die @(
            'virutil xfer setup registers a scheduled task that runs elevated,'
            'and registering one needs Administrator. Run it once from an'
            'elevated PowerShell (Run as administrator), as the user who runs'
            'the transfers:'
            ''
            '  virutil xfer setup'
        )
    }

    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $id.User.Value

    # The shell this setup runs under is the shell the task will run the helper
    # under, recorded in the action. That is the prompt path's rule -- elevate
    # whichever PowerShell the run is already in -- taken once, here, because a
    # task cannot ask the run that starts it.
    $shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    # Program Files is Administrators-only to write, and the directory inherits
    # that. See $script:XferTaskDir for why that is the point.
    New-VirutilsDir $script:XferTaskDir | Out-Null
    Set-Content -LiteralPath $script:XferTaskHelper -Value (Get-XferHelperText) -Encoding UTF8

    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $def = $svc.NewTask(0)
    $def.RegistrationInfo.Author      = $id.Name
    $def.RegistrationInfo.Description = @(
        'The elevated half of a virutil push, pull or sync: mints a throwaway'
        'account, publishes an SMB share over one transfer''s staging directory,'
        'and takes both away when the transfer ends. Started on demand by'
        'virutil; registered by `virutil xfer setup`, removed by `virutil xfer remove`.'
    ) -join ' '

    # As this user, with this user's full token, and only while they are
    # logged on -- which a run that is starting the task always is. No stored
    # password, and no run on a desktop nobody is sitting at.
    $def.Principal.UserId    = $id.Name
    $def.Principal.LogonType = 3        # TASK_LOGON_INTERACTIVE_TOKEN
    $def.Principal.RunLevel  = 1        # TASK_RUNLEVEL_HIGHEST

    # No trigger: it runs when a transfer starts it and at no other time.
    # Parallel instances, because two transfers at once each need a helper and
    # each helper lives as long as its transfer. No time limit, because a sync
    # of a large tree is a long transfer and the helper's own wait on its
    # parent's pid is what bounds it. On battery too, since a laptop is where
    # the developer is.
    $set = $def.Settings
    $set.Enabled                    = $true
    $set.AllowDemandStart           = $true
    $set.MultipleInstances          = 0     # TASK_INSTANCES_PARALLEL
    $set.ExecutionTimeLimit         = 'PT0S'
    $set.DisallowStartIfOnBatteries = $false
    $set.StopIfGoingOnBatteries     = $false

    $action = $def.Actions.Create(0)        # TASK_ACTION_EXEC
    $action.Path             = $shell
    $action.Arguments        = Get-XferTaskArguments $script:XferTaskHelper
    $action.WorkingDirectory = $script:XferTaskDir

    # TASK_CREATE_OR_UPDATE | TASK_DONT_ADD_PRINCIPAL_ACE, as this user, with
    # the interactive token, and the ACL above.
    $svc.GetFolder('\').RegisterTaskDefinition(
        $script:XferTaskName, $def, (0x6 -bor 0x10), $id.Name, $null, 3,
        (Get-XferTaskSddl $sid)) | Out-Null

    Say @(
        "registered the scheduled task $($script:XferTaskName), for $($id.Name)"
        "  helper  $($script:XferTaskHelper)"
        "  shell   $shell"
        "  scratch $([IO.Path]::GetFullPath($script:VirutilsTmpDir))"
        'push, pull, sync and ui setup will start it instead of prompting.'
    )
}

# Invoke-XferRemove -- the task and its helper, both gone. Saying so when there
# was nothing to remove rather than failing: the end state is what was asked.
function Invoke-XferRemove {
    if (-not (Test-XferElevated)) {
        Die @(
            'virutil xfer remove unregisters a task only Administrators may'
            'change. Run it from an elevated PowerShell (Run as administrator).'
        )
    }
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $had = $true
    try { $svc.GetFolder('\').DeleteTask($script:XferTaskName, 0) } catch { $had = $false }
    $dir = $false
    try { $dir = Remove-XferTree $script:XferTaskDir } catch {
        Warn "could not remove $($script:XferTaskDir): $($_.Exception.Message)"
    }
    if ($had)     { Say "removed the scheduled task $($script:XferTaskName)" }
    else          { Say "no scheduled task $($script:XferTaskName) was registered" }
    if ($dir)     { Say "removed $($script:XferTaskDir)" }
    Say 'transfers will ask for Administrator again, once each.'
}

# Invoke-XferStatus -- the decision Publish-XferShare would make, made now and
# said out loud. The exit code is the answer, for a script that wants to know
# before it starts something unattended: 0 when a transfer will not prompt.
function Invoke-XferStatus {
    $task   = Get-XferHelperTask
    $launch = Get-XferLaunch
    $out = @()
    if ($null -eq $task) {
        $out += "task     $($script:XferTaskName): not registered (or not visible to this user)"
    } else {
        $out += "task     $($script:XferTaskName): registered, $(if ($task.Enabled) { 'enabled' } else { 'disabled' }), last result $($task.LastResult)"
        $out += "shell    $($task.Shell)"
        $out += "helper   $($script:XferTaskHelper): $(if (-not $task.HelperText) { 'missing' } elseif (Test-XferHelperCurrent $task.HelperText) { 'current' } else { 'stale' })"
    }
    $out += "scratch  $([IO.Path]::GetFullPath($script:VirutilsTmpDir))"
    if ($launch.Via -eq 'task') {
        $out += 'transfers start the task: no prompt.'
    } else {
        $out += 'transfers ask for Administrator, once each.'
        if ($launch.Why) { $out += @($launch.Why) }
        else { $out += "Run 'virutil xfer setup' once, from an elevated PowerShell, to stop that." }
    }
    $out | ForEach-Object { [Console]::Out.WriteLine($_) }
    if ($launch.Via -ne 'task') { $script:VirutilExit = 1 }
}

function Xfer-Main {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { Usage (Get-XferUsage) 1 }
    $verb = $Arguments[0]
    if ($verb -in @('-h', '--help')) { Usage (Get-XferUsage) 0 }

    # Each verb takes nothing else, bar a help that is asked for after it.
    $rest = Get-RestArgs $Arguments 1
    foreach ($a in $rest) {
        if ($a -in @('-h', '--help')) { Usage (Get-XferUsage) 0 }
        Warn "unexpected argument: $a"
        Usage (Get-XferUsage) 1
    }

    switch ($verb) {
        'setup'  { Invoke-XferSetup;  break }
        'remove' { Invoke-XferRemove; break }
        'status' { Invoke-XferStatus; break }
        default  { Usage (Get-XferUsage) 1 }
    }
}
