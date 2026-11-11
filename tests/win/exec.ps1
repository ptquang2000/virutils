<#
.SYNOPSIS
  exec turns a guest's result into virutil's exit code. Check that it does.

.DESCRIPTION
  Contract section 5: "Otherwise the guest's own exit code passes through
  (`exec`)." That is the whole observable contract of `virutil exec`, and it is
  one `if` away from being a PowerShell error instead -- `guest-exec-status`
  returns `signal` rather than `exitcode` when the guest process was killed by
  one, and under `Set-StrictMode -Version Latest` reaching for an absent member
  throws. The shape virutil most wants to report faithfully is the shape that
  would crash it.

  No guest and no agent: Invoke-GuestAgent is replaced with a function that
  hands back the replies a real one would, so what is under test is the
  translation rather than the channel.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'modules\win'
$env:VIRUTILS_DIR = Join-Path ([IO.Path]::GetTempPath()) ("virutil-test-" + [Guid]::NewGuid().ToString('N'))

. (Join-Path $moduleDir 'parser.ps1')
. (Join-Path $moduleDir 'paths.ps1')
. (Join-Path $moduleDir 'payload.ps1')
. (Join-Path $moduleDir 'guest.ps1')
. (Join-Path $moduleDir 'exec.ps1')

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, $Want, $Got)
    if ("$Want" -eq "$Got") { [Console]::Out.WriteLine("ok       $Name"); $script:Pass++ }
    else {
        [Console]::Out.WriteLine("FAIL     $Name")
        [Console]::Out.WriteLine("         wanted [$Want], got [$Got]")
        $script:Fail++
    }
}

function CheckTrue { param([string]$Name, $Got) Check $Name $true ([bool]$Got) }

# The agent's replies, scripted. $script:AgentStatus is what guest-exec-status
# hands back; everything else answers the way a live agent would.
$script:AgentStatus = $null
function Invoke-GuestAgent {
    param([string]$Vm, [string]$Command, $Arguments = $null, [int]$TimeoutMs = 10000)
    switch ($Command) {
        'guest-exec'        { return ([pscustomobject]@{ pid = 4242 }) }
        'guest-exec-status' { return $script:AgentStatus }
        default             { throw "the test agent was asked for $Command" }
    }
}

function RunWith {
    param($Status)
    $script:AgentStatus = $Status
    $script:VirutilExit = -1
    Invoke-GuestExec 'testvm' 'cmd.exe' @('/c', 'true') 2>$null | Out-Null
    return $script:VirutilExit
}

try {
    # The ordinary case, and the one the contract names.
    Check 'a zero exit code passes through' 0 `
        (RunWith ([pscustomobject]@{ exited = $true; exitcode = 0 }))
    Check 'a non-zero exit code passes through' 3 `
        (RunWith ([pscustomobject]@{ exited = $true; exitcode = 3 }))

    # qemu-ga omits exitcode entirely for a process killed by a signal. Before
    # this was guarded, StrictMode turned that into a PropertyNotFound error and
    # the run died with a PowerShell message rather than an exit code.
    Check 'a signalled process does not crash the run' 137 `
        (RunWith ([pscustomobject]@{ exited = $true; signal = 9 }))

    # Neither member. Nothing to report but success is still the honest reading:
    # the process exited and said nothing about how.
    Check 'neither member is zero, not an error' 0 `
        (RunWith ([pscustomobject]@{ exited = $true }))

    # `virutil exec` runs in the caller's own PowerShell, so its stdout has to
    # be on the success stream for `$x = virutil exec ...` to see it. It came out
    # through [Console]::Out, which went straight to the screen and left $x empty.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("one`r`n`r`ntwo  `r`n"))
    $script:AgentStatus = [pscustomobject]@{ exited = $true; exitcode = 0; 'out-data' = $b64 }
    $got = @(Invoke-GuestExec 'testvm' 'cmd.exe' @('/c', 'true') -Emit 2>$null)
    Check 'emitted stdout is one object per line'  3            $got.Count
    Check 'with \r and trailing blanks gone'       'one||two'   ($got -join '|')
    $got = @(Invoke-GuestExec 'testvm' 'cmd.exe' @('/c', 'true') -Emit -Detach)
    Check 'a detached pid is emitted too'          '4242'       ($got -join '|')
    $script:AgentStatus = [pscustomobject]@{ exited = $true; exitcode = 0 }
    $got = @(Invoke-GuestExec 'testvm' 'cmd.exe' @('/c', 'true') -Emit)
    Check 'no output emits nothing'                0            $got.Count
    # Without -Emit nothing reaches the pipeline: sync's run rules call this
    # inside a scriptblock whose return value is the transfer's answer.
    $script:AgentStatus = [pscustomobject]@{ exited = $true; exitcode = 0; 'out-data' = $b64 }
    $console = [Console]::Out
    $sw = New-Object IO.StringWriter
    [Console]::SetOut($sw)
    try { $got = @(Invoke-GuestExec 'testvm' 'cmd.exe' @('/c', 'true')) }
    finally { [Console]::SetOut($console) }
    Check 'without -Emit the pipeline stays empty' 0            $got.Count
    Check 'and the console has it'                 "one`n`ntwo`n" $sw.ToString()

    # --- qemu-ga's exec records ----------------------------------------------
    #
    # From here the agent is a model of qemu-ga's guest-exec bookkeeping
    # (qga/commands.c): a record per guest-exec, appended; guest-exec-status
    # answers from the *first* record with that pid and drops it once it reports
    # it exited; a pid the guest freed can be handed to the next process while
    # an old record for it is still there. MDE-6273 r1-4 is the case: a sync's
    # first status was answered by a detached run's leftover record -- exited,
    # exit 0, no output -- and the sync reported "all already current" for a
    # delivery that never ran (docs/qga-exec-records.md).
    $script:Recs      = New-Object Collections.Generic.List[object]
    $script:Execs     = New-Object Collections.Generic.List[object]
    $script:NextPid   = 0
    $script:NextOut   = ''
    $script:NextRc    = 0
    $script:NextPolls = 1
    $script:NextQuiet = $false
    $script:OldMsg    = $false
    function Add-Rec {
        param([long]$GuestPid, [bool]$Finished, [bool]$HasOutput, [int]$Status = 0, [string]$Out = '', [int]$Polls = 0)
        $script:Recs.Add([pscustomobject]@{
            Pid = $GuestPid; Finished = $Finished; HasOutput = $HasOutput
            Status = $Status; Out = $Out; PollsLeft = $Polls })
    }
    function Invoke-GuestAgent {
        param([string]$Vm, [string]$Command, $Arguments = $null, [int]$TimeoutMs = 10000)
        switch ($Command) {
            'guest-exec' {
                $argv = @($Arguments['arg'])
                $text = ''
                try { $text = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($argv[$argv.Count - 1])) } catch { }
                if (-not $text) { $text = $argv -join ' ' }
                $in = if ($Arguments.ContainsKey('input-data')) {
                    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Arguments['input-data'])) } else { '' }
                $capture = [bool]$Arguments['capture-output']
                $script:Execs.Add([pscustomobject]@{ Pid = $script:NextPid; Text = $text; Capture = $capture; Input = $in })
                # A real guest prints the wrapper's nonce first, unless the
                # process died before its script ran.
                $out = $script:NextOut
                $n = [regex]::Match($text, 'virutil-call ([0-9a-f]{32})')
                if ($n.Success -and -not $script:NextQuiet) { $out = "virutil-call $($n.Groups[1].Value)`n$out" }
                Add-Rec $script:NextPid $false $capture $script:NextRc $out $script:NextPolls
                return ([pscustomobject]@{ pid = $script:NextPid })
            }
            'guest-exec-status' {
                $p = [long]$Arguments['pid']
                $rec = $null
                foreach ($r in $script:Recs) { if ($r.Pid -eq $p) { $rec = $r; break } }
                if ($null -eq $rec) {
                    if ($script:OldMsg) { Die "$Vm's guest agent refused guest-exec-status: Invalid parameter 'pid'" }
                    Die "$Vm's guest agent refused guest-exec-status: PID $p does not exist"
                }
                if (-not $rec.Finished) {
                    if ($rec.PollsLeft -gt 0) { $rec.PollsLeft--; return ([pscustomobject]@{ exited = $false }) }
                    $rec.Finished = $true
                }
                $r = [ordered]@{ exited = $true; exitcode = $rec.Status }
                if ($rec.HasOutput -and $rec.Out) {
                    $r['out-data'] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rec.Out))
                }
                [void]$script:Recs.Remove($rec)
                return ([pscustomobject]$r)
            }
            default { throw "the model agent was asked for $Command" }
        }
    }
    function Reset-Model {
        param([long]$GuestPid = 5512, [string]$Out = '', [int]$Rc = 0, [int]$Polls = 1, [switch]$Quiet, [switch]$OldMsg)
        $script:Recs.Clear(); $script:Execs.Clear()
        $script:NextPid = $GuestPid; $script:NextOut = $Out; $script:NextRc = $Rc
        $script:NextPolls = $Polls; $script:NextQuiet = [bool]$Quiet; $script:OldMsg = [bool]$OldMsg
        $dir = Get-GuestExecLedgerDir 'testvm'
        if (Test-Path -LiteralPath $dir) { [IO.Directory]::Delete($dir, $true) }
    }
    function Ledger { return @(Get-ChildItem -LiteralPath (Get-GuestExecLedgerDir 'testvm') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) }

    # The reused pid, as on win11-2: a detached run's record, finished, no
    # output, exit 0, sitting ahead of the sync payload's.
    Reset-Model -GuestPid 5512 -Out '1 6400'
    Add-Rec 5512 $true $false 0
    $script:VirutilExit = -1
    $got = Invoke-GuestPsText 'testvm' "'payload'" -Capture 2>$null
    Check 'a reused pid still returns this call''s own output' '1 6400' $got
    Check 'with this call''s own exit code'                    0        $script:VirutilExit
    Check 'and both records are consumed'                      0        $script:Recs.Count
    Check 'and nothing is left in the ledger'                  0        (@(Ledger).Count)

    # The same, behind an abandoned captured call: a record with output and a
    # non-zero code, and some other call's nonce.
    Reset-Model -GuestPid 5512 -Out 'mine' -Rc 0
    Add-Rec 5512 $true $true 7 "virutil-call $('0' * 32)`nold output"
    $script:VirutilExit = -1
    $got = Invoke-GuestPsText 'testvm' "'payload'" -Capture 2>$null
    Check 'another call''s record is not taken for this one'  'mine' $got
    Check 'nor its exit code'                                 0      $script:VirutilExit

    # No older record, and this call's process died before printing anything:
    # its own answer is the only one there is, and it must not hang the poll.
    Reset-Model -GuestPid 6000 -Out '' -Rc 5 -Quiet
    $script:VirutilExit = -1
    $got = Invoke-GuestPsText 'testvm' "'payload'" -Capture 2>$null
    Check 'a silent process of our own is still ours'  5  $script:VirutilExit
    Check 'and its (empty) output is returned'         '' $got

    # The nonce is stripped wherever the output goes, -Emit included.
    Reset-Model -GuestPid 6001 -Out "a`nb"
    $got = @(Invoke-GuestPsText 'testvm' "'payload'" -Emit 2>$null)
    Check 'the nonce never reaches the caller' 'a|b' ($got -join '|')

    # The ledger: an entry whose owner is gone is polled once and dropped with
    # its record; a live owner's entry is left to it; a detached process still
    # running keeps its entry for the next reap.
    Reset-Model
    Add-Rec 777 $true $false 0
    Add-Rec 778 $true $false 0
    Add-Rec 779 $false $false 0 '' 1000
    [void](Add-GuestExecLedger 'testvm' 777 999999999)
    # 4 is the System process: alive on every Windows host, and never us.
    [void](Add-GuestExecLedger 'testvm' 778 4)
    [void](Add-GuestExecLedger 'testvm' 779 0)
    Invoke-GuestExecReap 'testvm'
    Check 'a dead owner''s record is reaped'          '778.4|779.0' ((Ledger) -join '|')
    Check 'and only that record was consumed'          '778|779'     (($script:Recs | ForEach-Object { $_.Pid }) -join '|')

    # An entry for a pid qemu-ga no longer knows is just dropped.
    Reset-Model
    [void](Add-GuestExecLedger 'testvm' 4321 0)
    Invoke-GuestExecReap 'testvm'
    Check 'an entry for an unknown pid is dropped' 0 (@(Ledger).Count)

    # The qemu-ga 7.6.2 an XP guest runs says "Invalid parameter 'pid'" for a
    # pid it has no record of (LE11 winxp, 2026-11-11). That is "gone" too:
    # the entry is dropped, the reap goes on to the next one, and a silent
    # process of the call's own is still its own.
    Reset-Model -OldMsg
    Add-Rec 4322 $true $false 0
    [void](Add-GuestExecLedger 'testvm' 4321 0)
    [void](Add-GuestExecLedger 'testvm' 4322 0)
    Invoke-GuestExecReap 'testvm'
    Check 'an older agent''s unknown pid is dropped, and the reap goes on' 0 (@(Ledger).Count)
    Reset-Model -GuestPid 6002 -Rc 4 -Quiet -OldMsg
    $script:VirutilExit = -1
    $got = Invoke-GuestPsText 'testvm' "'payload'" -Capture 2>$null
    Check 'and a silent process of our own is ours on it too' 4 $script:VirutilExit

    # Every call reaps first, so a record left behind cannot answer for it.
    Reset-Model -GuestPid 5512 -Out 'fresh'
    Add-Rec 5512 $true $false 0
    [void](Add-GuestExecLedger 'testvm' 5512 0)
    $got = Invoke-GuestPsText 'testvm' "'payload'" -Capture 2>$null
    Check 'a ledgered record is reaped before the next call' 'fresh' $got
    Check 'and its entry with it'                            0 (@(Ledger).Count)

    # cmd -d stays a plain detached guest-exec (XP has no powershell for a
    # launcher), so the host writes it down for the reaper.
    Reset-Model -GuestPid 3100
    $got = @(Invoke-GuestExec 'testvm' 'cmd.exe' @('/c', 'shutdown') -Detach -Emit)
    Check 'cmd -d still prints the guest pid'  '3100'   ($got -join '|')
    Check 'and leaves a ledger entry for it'   '3100.0' ((Ledger) -join '|')

    # ps -d goes through a launcher that is polled to its end: the only
    # guest-exec is captured, the script is handed over on stdin, the pid
    # printed is the one the launcher started, and no record or entry is left.
    Reset-Model -GuestPid 6100 -Out '7777'
    $got = @(Invoke-GuestPsText 'testvm' "'long job'" -Detach -Emit 2>$null)
    Check 'ps -d prints the started process''s pid' '7777' ($got -join '|')
    Check 'through one guest-exec'                  1      $script:Execs.Count
    Check 'which is captured, so it gets polled'    $true  $script:Execs[0].Capture
    $handed = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:Execs[0].Input.Trim()))
    CheckTrue 'the script reaches the launcher on stdin' ($handed -match "'long job'")
    CheckTrue 'and the launcher starts it shell-executed' ($script:Execs[0].Text -match 'UseShellExecute = \$true')
    Check 'no record is left in qemu-ga'            0      $script:Recs.Count
    Check 'and nothing in the ledger'               0      (@(Ledger).Count)
    $why = ''
    try { Invoke-GuestPsText 'testvm' "'x'" -Detach -Emit -InputB64 'eA==' | Out-Null } catch { $why = $_.Exception.Message }
    CheckTrue 'ps -d with stdin is refused, not dropped' ($why -match 'cannot hand stdin')

    # Get-RestArgs stands in for the shell's `shift`, and the slice it replaces
    # counts backwards from the end once the array is exhausted -- which would
    # hand a module its own arguments reversed rather than none.
    Check 'rest of a two-element array'   'b'  ((Get-RestArgs @('a','b') 1) -join ',')
    Check 'rest past the end is empty'    ''   ((Get-RestArgs @('a') 1) -join ',')
    Check 'rest of an empty array'        ''   ((Get-RestArgs @() 1) -join ',')
    Check 'rest from index 2'             'c'  ((Get-RestArgs @('a','b','c') 2) -join ',')

    # Every case above joins its result, and a join flattens a scalar and a
    # one-element array alike -- so none of them can see the shape. `return`
    # unrolls an array on the way out, which handed the caller $null for the
    # empty case and a bare string for the one-element case. Reading .Count is
    # the assertion that tells the two apart: under StrictMode it is what the
    # caller does and what throws. `virutil exec cmd VM WORD` is exactly the
    # one-element case, and it died on this for every single invocation.
    Check 'the empty rest is an array, not $null' 0 `
        ((Get-RestArgs @('a') 1).Count)
    Check 'a one-element rest is an array, not a string' 1 `
        ((Get-RestArgs @('a','b') 1).Count)
    Check 'and its element survives' 'b' `
        ((Get-RestArgs @('a','b') 1)[0])

    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine("$($script:Pass) passed, $($script:Fail) failed")
} finally {
    # [IO.Directory]::Delete, not Remove-Item: Remove-Item truncates a path at a
    # `~` segment, and a temp directory on a profile with an 8.3 short name has
    # one. See Remove-VirutilsFile in modules/win/paths.ps1.
    if (Test-Path -LiteralPath $env:VIRUTILS_DIR) {
        [IO.Directory]::Delete($env:VIRUTILS_DIR, $true)
    }
}

exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
