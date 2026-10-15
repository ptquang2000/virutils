<#
.SYNOPSIS
  push and pull on a Windows host, everything except the elevated half.

.DESCRIPTION
  Contract section 7: the transfer layer on this driver serves a share from the
  host's own SMB server, which needs Administrator to publish and mints a
  throwaway local account per transfer. None of that can run in a test suite
  anyone is expected to run, and none of it is what usually breaks.

  So both seams are substituted and everything between them is exercised for
  real -- argument parsing, the guest path rules the contract fixes, the
  staging copy, the rendered payload, and the teardown:

    * the guest agent boundary (Invoke-GuestAgent), as tests/win/exec.ps1
      does, so the payload that would have gone into a guest is observable here
      instead;
    * the share publisher (Publish-XferShare / Unpublish-XferShare), the one
      place in modules/win/xfer.ps1 that elevates, touches SMB or touches local
      accounts.

  What is asserted is behaviour and not mechanism: the text that reaches the
  guest, the exit code, and -- the two properties worth the most -- that a
  transfer which completes and a transfer which fails both leave no staged tree
  behind.
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
. (Join-Path $moduleDir 'xfer.ps1')
. (Join-Path $moduleDir 'push.ps1')
. (Join-Path $moduleDir 'pull.ps1')

# The real publisher, kept before the stub below replaces it: the push and pull
# tests stub the whole of it, and the launch tests stub only the three seams
# underneath it (Get-XferHelperTask, Start-XferHelperTask,
# Start-XferHelperPrompt) so that which path it takes, what it hands the helper
# and where it gets the helper's pid from all run for real.
$script:RealPublish = ${function:Publish-XferShare}

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

# Dies WHAT SCRIPTBLOCK -- the message a failure carries, or '' if it did not
# fail. The diagnosis is the observable here: a refusal nobody can read is not
# much better than no refusal.
function Dies {
    param([scriptblock]$Body)
    try { & $Body | Out-Null; return '' }
    catch { return $_.Exception.Message }
}
function ExitCodeOf {
    param([scriptblock]$Body)
    try { & $Body | Out-Null; return 0 }
    catch {
        if ($_.Exception.Data -and $_.Exception.Data.Contains('VirutilCode')) {
            return [int]$_.Exception.Data['VirutilCode']
        }
        return -1
    }
}

# --- the two seams ----------------------------------------------------------

# The agent boundary, as tests/win/exec.ps1 substitutes it. Every payload the
# transfer would have sent is decoded back out of the -EncodedCommand and kept,
# so what reaches the guest is what is asserted rather than how it got there.
$script:Sent      = @()
$script:GuestRc   = 0
$script:GuestOut  = ''
function Invoke-GuestAgent {
    param([string]$Vm, [string]$Command, $Arguments = $null, [int]$TimeoutMs = 10000)
    switch ($Command) {
        'guest-exec' {
            $argv = @($Arguments['arg'])
            $script:Sent += [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($argv[$argv.Count - 1]))
            return ([pscustomobject]@{ pid = 4242 })
        }
        'guest-exec-status' {
            # The mount and unmount calls always succeed here: they are the
            # credential half, and a test that wants the *copy* to fail should
            # not have to arrange for the logon to fail first.
            $last = $script:Sent[$script:Sent.Count - 1]
            $rc = if ($last -match 'net use') { 0 } else { $script:GuestRc }
            $out = if ($last -match 'net use') { 'ok' } else { $script:GuestOut }
            return ([pscustomobject]@{
                exited = $true
                exitcode = $rc
                'out-data' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($out))
            })
        }
        default { throw "the test agent was asked for $Command" }
    }
}

# The share publisher. Nothing is elevated, no share is created and no account
# is minted; the staging tree underneath it is real, because that is the half a
# teardown has to take away.
$script:Published    = 0
$script:Unpublished  = 0
$script:PublishedDir = ''
$script:LastScratch  = ''
$script:PublishWrite = $false
function Publish-XferShare {
    param([string]$Token, [string]$Path, [switch]$Write)
    $script:Published++
    $script:PublishedDir = $Path
    $script:PublishWrite = [bool]$Write
    $script:LastScratch  = Get-XferScratch $Token
    return @{
        Token = $Token; Scratch = (Get-XferScratch $Token)
        Unc = "\\10.0.2.2\$Token"; User = "vxp-$Token"; Password = 'notarealpassword'
        HelperPid = 0
    }
}
function Unpublish-XferShare { param($Session) $script:Unpublished++ }

# The three seams under the real publisher. Nothing here registers, starts or
# elevates anything: "the task" is whatever $TaskSeen says it is, and "the
# helper" is $FakeHelper, which reads the request the way the real one does and
# answers through the same status file.
$script:TaskSeen       = $null
$script:TaskStarts     = @()
$script:TaskStartFails = $false
$script:PromptArgv     = $null
$script:LastRequest    = $null
$script:FakeHelper     = { param($Token) }
function Get-XferHelperTask { return $script:TaskSeen }
function Start-XferHelperTask {
    param([string]$Token)
    if ($script:TaskStartFails) { throw 'Access is denied.' }
    $script:TaskStarts += $Token
    & $script:FakeHelper $Token
}
function Start-XferHelperPrompt {
    param([string]$Shell, [string[]]$Argv)
    $script:PromptArgv = $Argv
    & $script:FakeHelper $Argv[$Argv.Count - 1]
    return $null
}
function Get-XferStrays { param([string]$Except = '') return ,@('stray1') }
# setup must never be able to register the real task from a test run, even one
# started from an elevated shell.
function Test-XferElevated { return $false }

# What a helper would write, as it would write it.
function WriteHelperStatus {
    param([string]$Token, [bool]$Ok, [int]$HelperPid, [string]$Detail = '', [switch]$Started)
    $o = @{ ok = $Ok; pid = $HelperPid; detail = $Detail }
    if ($Started) { $o.started = $true }
    Set-Content -LiteralPath (Get-XferStatusFile $Token) -Encoding ASCII -Value ($o | ConvertTo-Json -Compress)
}

# The preconditions, which need a domain, a monitor and an agent between them.
# They are asserted for ordering below rather than for content.
$script:ReadyFails = $false
function Assert-XferReady {
    param([string]$Vm)
    if ($script:ReadyFails) { Die "$Vm is not running" }
}

# Run a module and hand back what it printed, so the report line is an
# assertion rather than noise in the middle of the results.
function Capture {
    param([scriptblock]$Body)
    # The record of what went to the guest starts empty for each run, so an
    # assertion about this transfer can never be satisfied by the last one.
    $script:Sent = @()
    $orig = [Console]::Out
    $buf = New-Object IO.StringWriter
    [Console]::SetOut($buf)
    try { & $Body | Out-Null } finally { [Console]::SetOut($orig) }
    return $buf.ToString().Replace("`r`n", "`n")
}

# The two ends the last *copier* payload was rendered with. Scanned backwards
# rather than read off the end of the list, because the copier is not the last
# thing a transfer sends: the unmount goes after it, and that one has neither.
function LastHole {
    param([string]$Name)
    for ($i = $script:Sent.Count - 1; $i -ge 0; $i--) {
        $m = [regex]::Match($script:Sent[$i], "(?m)^\`$$Name = '([^']*)'")
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}
function LastDst { return (LastHole 'dst') }
function LastSrc { return (LastHole 'src') }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("virutil-src-" + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    $tree = Join-Path $scratch 'tree'
    New-Item -ItemType Directory -Force -Path $tree | Out-Null
    Set-Content -LiteralPath (Join-Path $tree 'a.txt') -Value 'a' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $tree 'b.txt') -Value 'b' -Encoding ASCII
    $one = Join-Path $scratch 'one.txt'
    Set-Content -LiteralPath $one -Value 'one' -Encoding ASCII

    # --- the guest path rules, which are contract -------------------------
    #
    # Section 2: a guest path is relative to the guest's root, a C:\ prefix and
    # backslashes are tolerated, and '..' is refused. Three spellings of one
    # place have to arrive at one answer.
    Check 'a bare relative guest path'       'opt/app' (ConvertTo-GuestWindowsPath 'opt\app')
    Check 'a drive-prefixed guest path'      'opt/app' (ConvertTo-GuestWindowsPath 'C:\opt\app')
    Check 'a backslash-prefixed guest path'  'opt/app' (ConvertTo-GuestWindowsPath '\opt\app')
    Check 'a forward-slash guest path'       'opt/app' (ConvertTo-GuestWindowsPath 'opt/app')
    Check 'a lowercase drive prefix'         'opt/app' (ConvertTo-GuestWindowsPath 'c:\opt\app')
    Check 'a trailing slash is not a component' 'opt/app' (ConvertTo-GuestWindowsPath 'C:\opt\app\')

    CheckTrue "'..' is refused, and named" `
        ((Dies { ConvertTo-GuestWindowsPath 'opt\..\..\windows' 'destination' }) -match "may not contain '\.\.'")

    # --- credentials ------------------------------------------------------
    #
    # The cap is Windows's own: a local account name may not exceed 20
    # characters, and the prefix is what makes a stray decidable, so the token
    # has to fit in what is left.
    $c1 = New-XferCredential (New-XferToken)
    $c2 = New-XferCredential (New-XferToken)
    CheckTrue 'the account name fits a Windows local account' ($c1.User.Length -le 20)
    CheckTrue 'the account name carries the prefix'           ($c1.User.StartsWith('vxp-'))
    Check     'the password is 24 characters'             24  $c1.Password.Length
    CheckTrue 'the password is alphanumeric'                  ($c1.Password -match '^[A-Za-z0-9]{24}$')
    CheckTrue 'two transfers do not get the same account'     ($c1.User -ne $c2.User)
    CheckTrue 'two transfers do not get the same password'    ($c1.Password -ne $c2.Password)

    # --- the free-space pre-flight ----------------------------------------
    #
    # Both figures in the message, because "not enough space" without them
    # leaves the reader to go and measure what the run already knew.
    $room = Dies { Assert-XferRoom 4294967296 1048576 'C:\tmp' }
    CheckTrue 'too little room is refused'        ($room -ne '')
    CheckTrue 'and the refusal names what is needed' ($room -match '4\.0 GiB')
    CheckTrue 'and what there is'                    ($room -match '1\.0 MiB')
    Check 'enough room is not refused' '' (Dies { Assert-XferRoom 1024 1048576 'C:\tmp' })
    Check 'an unmeasurable volume is not refused' '' (Dies { Assert-XferRoom 1024 $null 'C:\tmp' })

    # --- the sweep's decision ---------------------------------------------
    #
    # A stray whose owner is gone is this run's to reap; one whose owner is
    # alive belongs to a transfer still in flight, and taking its share away
    # would break it for a reason the transport does not have.
    $live = 'livetoken123'
    New-VirutilsDir (Get-XferScratch $live) | Out-Null
    Set-Content -LiteralPath (Get-XferStatusFile $live) -Encoding ASCII `
        -Value (@{ ok = $true; pid = $PID; detail = '' } | ConvertTo-Json -Compress)

    # A process id that is certainly not in use: one that has run and exited.
    $corpse = Start-Process -FilePath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) `
        -ArgumentList @('-NoProfile', '-Command', 'exit 0') -PassThru -WindowStyle Hidden
    $corpse.WaitForExit()
    $dead = 'deadtoken123'
    New-VirutilsDir (Get-XferScratch $dead) | Out-Null
    Set-Content -LiteralPath (Get-XferStatusFile $dead) -Encoding ASCII `
        -Value (@{ ok = $true; pid = $corpse.Id; detail = '' } | ConvertTo-Json -Compress)

    Check 'a stray whose owner is alive is skipped' $false (Test-XferReapable $live)
    Check 'a stray whose owner is gone is reaped'   $true  (Test-XferReapable $dead)
    Check 'a stray with no status file is reaped'   $true  (Test-XferReapable 'notokenatall')

    # --- declining the prompt is its own answer ----------------------------
    #
    # Contract section 5 gives it a code of its own so that a wrapping script
    # can tell "I clicked No" (98) from "SMB is broken" (99), and the whole
    # distinction turns on recognising one exception. It is not the exception
    # Start-Process throws: that one is an InvalidOperationException reading
    # "This command cannot be run due to the error: The operation was canceled
    # by the user", with the Win32Exception carrying ERROR_CANCELLED wrapped
    # inside it -- so a test that constructs the flat shape would pass while the
    # real thing never matched.
    $cancelled = [ComponentModel.Win32Exception]::new(1223)
    $wrapped = [InvalidOperationException]::new(
        'This command cannot be run due to the error: The operation was canceled by the user.',
        $cancelled)
    CheckTrue 'a declined consent dialog is recognised through the wrapper' `
        (Test-XferElevationDeclined $wrapped)
    CheckTrue 'and unwrapped, for a host that does not wrap it' `
        (Test-XferElevationDeclined $cancelled)
    Check 'another Win32 failure is not read as a decline' $false `
        (Test-XferElevationDeclined ([ComponentModel.Win32Exception]::new(5)))
    Check 'and neither is an ordinary error' $false `
        (Test-XferElevationDeclined ([InvalidOperationException]::new('no')))

    # --- the helper text, as both paths render it ---------------------------
    #
    # One text, two copies: the prompt path writes it into scratch and setup
    # installs it for the task. "Is the installed one current" is a comparison
    # against what this run would render, so the rendering is what is pinned.
    $text = Get-XferHelperText
    $fullTmp = [IO.Path]::GetFullPath($script:VirutilsTmpDir).TrimEnd('\')
    CheckTrue 'the helper has its scratch root baked in'  ($text.Contains("`$Root   = '$fullTmp'"))
    CheckTrue 'and the account prefix'                    ($text.Contains("`$Prefix = 'vxp-'"))
    CheckTrue 'and no placeholder is left in it'          (-not ($text -match '@(ROOT|PREFIX)@'))
    CheckTrue "a root with a quote in it stays one literal" `
        ((Get-XferHelperText "C:\it's\tmp").Contains("'C:\it''s\tmp'"))
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$parseErrors) | Out-Null
    Check 'the rendered helper parses' 0 @($parseErrors).Count
    CheckTrue 'and takes the token as its only parameter' ($text -match '(?m)^param\(\[string\]\$Token\)\r?$')

    CheckTrue 'the helper this run renders is current'          (Test-XferHelperCurrent $text)
    CheckTrue 'line endings and a trailing newline do not count' `
        (Test-XferHelperCurrent (($text -replace "`r?`n", "`r`n") + "`r`n"))
    Check 'an edited helper is stale'                $false (Test-XferHelperCurrent ($text + "`n# edited"))
    Check 'one rendered for another root is stale'   $false (Test-XferHelperCurrent (Get-XferHelperText 'D:\elsewhere'))
    Check 'a missing helper is not current'          $false (Test-XferHelperCurrent $null)

    # --- the task's registration, as pure text ----------------------------
    $taskArgs = Get-XferTaskArguments 'C:\Program Files\virutil\xfer-helper.ps1'
    CheckTrue 'the task hands the helper the token as $(Arg0)' ($taskArgs.EndsWith('-Token $(Arg0)'))
    CheckTrue 'and nothing else'  (-not ($taskArgs -match '-(Password|Path|Scratch|User|Access)\b'))
    CheckTrue 'the helper path is quoted, Program Files has a space in it' `
        ($taskArgs.Contains('-File "C:\Program Files\virutil\xfer-helper.ps1"'))
    $sddl = Get-XferTaskSddl 'S-1-5-21-1-2-3-1001'
    CheckTrue 'the user may read and run the task'  ($sddl.Contains('(A;;GRGX;;;S-1-5-21-1-2-3-1001)'))
    CheckTrue 'and nobody else is granted anything' (-not ($sddl -match ';;;(AU|WD|BU|IU)\)'))
    CheckTrue 'and the ACL does not inherit more'   ($sddl.StartsWith('D:P'))

    # --- which path a transfer takes ---------------------------------------
    $current = @{ Enabled = $true; Shell = 'pwsh.exe'; HelperText = $text; LastResult = '0x00000000' }
    $script:TaskSeen = $null
    $l = Get-XferLaunch
    Check 'no task: the prompt, as before setup existed' 'prompt' $l.Via
    Check 'and nothing is said about it'                 ''       "$($l.Why)"
    $script:TaskSeen = $current
    Check 'a current task: the task' 'task' (Get-XferLaunch).Via
    $script:TaskSeen = @{} + $current; $script:TaskSeen.HelperText = $text + "`n# older"
    $l = Get-XferLaunch
    Check 'a stale helper: the prompt'          'prompt' $l.Via
    CheckTrue 'and the fix is named'            ("$($l.Why)" -match 'virutil xfer setup')
    $script:TaskSeen = @{} + $current; $script:TaskSeen.Enabled = $false
    $l = Get-XferLaunch
    Check 'a disabled task: the prompt'         'prompt' $l.Via
    CheckTrue 'and that is said'                ("$($l.Why)" -match 'disabled')

    # --- the real publisher above the three seams -------------------------
    #
    # A real process stands in for a live helper, so the pid the session ends
    # up with can be checked for being the helper's rather than anyone else's.
    $shellExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $sleeper = Start-Process -FilePath $shellExe -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep 120') `
        -PassThru -WindowStyle Hidden
    $keepReady = $script:XferHelperReadyMs; $keepStart = $script:XferTaskStartMs
    $script:XferHelperReadyMs = 6000; $script:XferTaskStartMs = 1500
    try {
        $okHelper = {
            param($Token)
            $req = Join-Path (Get-XferScratch $Token) 'request.json'
            $script:LastRequest = (Get-Content -LiteralPath $req -Raw) | ConvertFrom-Json
            WriteHelperStatus $Token $false $sleeper.Id -Started
            WriteHelperStatus $Token $true  $sleeper.Id
        }
        function NewStage {
            $t = New-XferToken
            $s = Join-Path (Get-XferScratch $t) 'share'
            New-VirutilsDir $s | Out-Null
            return @($t, $s)
        }

        # Through the task.
        $script:TaskSeen = $current; $script:TaskStarts = @(); $script:PromptArgv = $null
        $script:FakeHelper = $okHelper
        $tok, $stage = NewStage
        $sess = & $script:RealPublish -Token $tok -Path $stage
        Check     'with the task registered, the task is started'  $tok "$($script:TaskStarts)"
        Check     'and no prompt is raised'                        $null $script:PromptArgv
        Check     'the session says which path it took'            'task' $sess.Via
        Check     'the helper pid comes from the status file'      $sleeper.Id $sess.HelperPid
        Check     'the request carries the password'               $sess.Password $script:LastRequest.password
        Check     'and the access'                                 'ro' $script:LastRequest.access
        Check     'and the pid to wait on'                         $PID $script:LastRequest.parentPid
        Check     'and the strays'                                 'stray1' "$($script:LastRequest.strays)"
        CheckTrue 'and no helper is written into scratch for the task to run' `
            (-not (Test-Path -LiteralPath (Join-Path (Get-XferScratch $tok) 'helper.ps1')))

        # Through the prompt.
        $script:TaskSeen = $null; $script:TaskStarts = @()
        $tok, $stage = NewStage
        $sess = & $script:RealPublish -Token $tok -Path $stage -Write
        Check     'with no task, the prompt is raised'             'prompt' $sess.Via
        Check     'and the task is not touched'                    '' "$($script:TaskStarts)"
        Check     'the prompted helper is handed the token alone'  "-File|-Token|$tok" `
            ((@($script:PromptArgv) | Select-Object -Skip 4 | Where-Object { $_ -match '^-|^[a-z0-9]{12}$' }) -join '|')
        CheckTrue 'and never the password'                         (@($script:PromptArgv) -notcontains $sess.Password)
        Check     'the helper pid comes from the status file here too' $sleeper.Id $sess.HelperPid
        Check     'a pull request is read-write'                   'rw' $script:LastRequest.access
        CheckTrue 'the helper it runs is the rendered one' `
            (Test-XferHelperCurrent (Get-Content -LiteralPath (Join-Path (Get-XferScratch $tok) 'helper.ps1') -Raw))

        # A task that is there but will not start for this user.
        $script:TaskSeen = $current; $script:TaskStartFails = $true; $script:PromptArgv = $null
        $tok, $stage = NewStage
        $sess = & $script:RealPublish -Token $tok -Path $stage
        Check     'a task that will not start falls back to the prompt' 'prompt' $sess.Via
        CheckTrue 'and the prompt was raised'                           ($null -ne $script:PromptArgv)
        $script:TaskStartFails = $false

        # A helper that said it started and then died without an answer.
        $script:FakeHelper = { param($Token) WriteHelperStatus $Token $false $corpse.Id -Started }
        $tok, $stage = NewStage
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $msg = Dies { & $script:RealPublish -Token $tok -Path $stage }
        $rc  = ExitCodeOf { & $script:RealPublish -Token $tok -Path $stage }
        CheckTrue 'a helper that dies after starting is reported'   ($msg -match 'exited without saying')
        CheckTrue 'when it dies, not at the timeout'                ($clock.ElapsedMilliseconds -lt $script:XferHelperReadyMs)
        Check     'and it is the host-setup code'                   99 $rc

        # A task start that never runs a helper at all.
        $script:FakeHelper = { param($Token) }
        $tok, $stage = NewStage
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $msg = Dies { & $script:RealPublish -Token $tok -Path $stage }
        CheckTrue 'a task that never runs its helper is reported'   ($msg -match 'virutil-xfer-helper was started')
        CheckTrue 'after the start window, not the ready timeout'   ($clock.ElapsedMilliseconds -lt $script:XferHelperReadyMs)

        # A helper that answers with a failure.
        $script:FakeHelper = { param($Token) WriteHelperStatus $Token $false $sleeper.Id 'New-SmbShare: no' }
        $tok, $stage = NewStage
        $msg = Dies { & $script:RealPublish -Token $tok -Path $stage }
        CheckTrue "a helper's own failure is what is reported"      ($msg -match 'New-SmbShare: no')

        # Publish refuses to share anything but the transfer's own stage.
        $tok, $stage = NewStage
        CheckTrue 'a path that is not the stage is refused' `
            ((Dies { & $script:RealPublish -Token $tok -Path $scratch }) -match 'internal')

        # An empty stray list is an empty list, not a missing value.
        $tok, $stage = NewStage
        $req = Get-Content -LiteralPath (Write-XferRequest $tok (New-XferCredential $tok) 'ro' @()) -Raw
        CheckTrue 'no strays is written as an empty list' ($req -match '"strays":\[\]')
    } finally {
        $script:XferHelperReadyMs = $keepReady; $script:XferTaskStartMs = $keepStart
        $script:TaskSeen = $null
        try { $sleeper.Kill() } catch { }
    }

    # --- the real helper, run unelevated, refusing --------------------------
    #
    # Each case below is refused before the helper mints, shares or grants
    # anything, so running it for real needs no Administrator and changes
    # nothing whether or not this shell happens to be elevated. What is checked
    # is that a caller of the task -- who chooses the token and writes the
    # request -- cannot steer it.
    $helperFile = Join-Path $scratch 'helper.ps1'
    Set-Content -LiteralPath $helperFile -Value (Get-XferHelperText) -Encoding UTF8
    function RunHelper {
        param([string]$Token)
        & $shellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helperFile -Token $Token *> $null
        return $LASTEXITCODE
    }
    function StatusDetail {
        param([string]$Token)
        try { return [string]((Get-Content -LiteralPath (Get-XferStatusFile $Token) -Raw | ConvertFrom-Json).detail) }
        catch { return '' }
    }
    function GoodRequest {
        param([string]$Token, [string]$Password = 'abcdefghijklmnopqrstuvwx')
        Set-Content -LiteralPath (Join-Path (Get-XferScratch $Token) 'request.json') -Encoding ASCII `
            -Value (@{ password = $Password; access = 'ro'; parentPid = $PID; strays = @() } | ConvertTo-Json -Compress)
    }

    Check 'a token that could climb out of the root is refused' 2 (RunHelper '..\..\windows')

    # A junction in place of the scratch directory: the helper would write its
    # status file, and grant, wherever it pointed.
    $elsewhere = Join-Path $scratch 'elsewhere'
    New-Item -ItemType Directory -Force -Path $elsewhere | Out-Null
    $jtok = 'junction1234'
    New-Item -ItemType Junction -Path (Get-XferScratch $jtok) -Target $elsewhere | Out-Null
    Check     'a scratch directory that is a junction is refused' 3 (RunHelper $jtok)
    CheckTrue 'and nothing was written through it' `
        (-not (Test-Path -LiteralPath (Join-Path $elsewhere 'status.json')))
    [IO.Directory]::Delete((Get-XferScratch $jtok))

    $btok, $bstage = NewStage
    GoodRequest $btok 'short'
    Check     'a request the parent did not make is refused' 1 (RunHelper $btok)
    CheckTrue 'and says which field'                         ((StatusDetail $btok) -match 'password')

    $rtok, $rstage = NewStage
    GoodRequest $rtok
    New-Item -ItemType Junction -Path (Join-Path $rstage 'link') -Target $elsewhere | Out-Null
    Check     'a share with a junction inside it is refused' 1 (RunHelper $rtok)
    CheckTrue 'and says so'                                  ((StatusDetail $rtok) -match 'reparse point')
    [IO.Directory]::Delete((Join-Path $rstage 'link'))

    # --- virutil xfer -------------------------------------------------------
    Check 'xfer -h is a help'                 0 (ExitCodeOf { Xfer-Main @('-h') })
    Check 'xfer status -h is a help too'      0 (ExitCodeOf { Xfer-Main @('status', '-h') })
    Check 'xfer with no verb is a usage error' 1 (ExitCodeOf { Xfer-Main @() })
    Check 'an unknown verb is a usage error'  1 (ExitCodeOf { Xfer-Main @('bogus') })
    Check 'a verb takes no arguments'         1 (ExitCodeOf { Xfer-Main @('setup', 'now') })
    $msg = Dies { Xfer-Main @('setup') }
    CheckTrue 'setup unelevated is refused, with the way to do it' ($msg -match 'elevated PowerShell')
    CheckTrue 'remove unelevated is refused too' ((Dies { Xfer-Main @('remove') }) -match 'elevated')

    $script:TaskSeen = $null; $script:VirutilExit = 0
    $out = Capture { Xfer-Main @('status') }
    Check     'status without the task exits 1' 1 $script:VirutilExit
    CheckTrue 'and says transfers will prompt'  ($out -match 'ask for Administrator')
    $script:TaskSeen = $current; $script:VirutilExit = 0
    $out = Capture { Xfer-Main @('status') }
    Check     'status with a current task exits 0' 0 $script:VirutilExit
    CheckTrue 'and says there is no prompt'        ($out -match 'no prompt')
    $script:TaskSeen = $null; $script:VirutilExit = 0

    # --- push, end to end above the two seams ------------------------------
    #
    # The trailing-slash rule is rsync's, and it is the one push borrowed: a
    # source named with a slash puts its contents into DST, a source named
    # without one puts the directory itself under DST.
    $script:GuestOut = '1 2 40'
    $out = Capture { Push-Main @('testvm', $tree, 'opt\app') }
    Check 'push dir -> dir lands under DST'  'C:\opt\app\tree' (LastDst)
    CheckTrue 'push announces both ends'     ($out -match 'push: .* -> C:\\opt\\app\\tree')
    CheckTrue 'push reports what is present' ($out -match '2 files present \(some copied\)')
    CheckTrue 'and the guest stopwatch, not this host clock' ($out -match '40ms')

    $out = Capture { Push-Main @('testvm', ($tree + '\'), 'opt\app') }
    Check 'push dir/ -> dir lands as DST' 'C:\opt\app' (LastDst)

    $script:GuestOut = '3 12'
    $out = Capture { Push-Main @('testvm', $one, 'opt\app\') }
    Check 'push file -> dir keeps its name'  'C:\opt\app\one.txt' (LastDst)
    Check 'and is served from the share'     '\\10.0.2.2\' ((LastSrc) -replace '[^\\]+\\one\.txt$', '')
    CheckTrue 'a file push reports its size' ($out -match 'done \(3 B\) in 12ms')

    $out = Capture { Push-Main @('testvm', $one, 'opt\app\two.txt') }
    Check 'push file -> file renames' 'C:\opt\app\two.txt' (LastDst)

    # The properties worth the most, and both are observable from outside: a
    # transfer that ends leaves nothing staged, and the share is retired.
    CheckTrue 'a completed push leaves no staged tree' (-not (Test-Path -LiteralPath $script:LastScratch))
    Check     'and every published share was retired'  $script:Published $script:Unpublished
    Check     'the tree that was served is the staging copy, not the source' `
              $true ($script:PublishedDir.StartsWith($script:VirutilsTmpDir))
    Check     'a push share is read-only' $false $script:PublishWrite

    # A failing copy is the guest's code, and it still leaves nothing behind.
    $before = $script:Published
    $script:GuestRc = 93
    $rc = ExitCodeOf { Capture { Push-Main @('testvm', $tree, 'opt\app') } }
    Check     'a robocopy failure in the guest is exit 93' 93 $rc
    CheckTrue 'an interrupted push leaves no staged tree'  (-not (Test-Path -LiteralPath $script:LastScratch))
    Check     'and its share was retired too' ($script:Published - $before) 1
    $script:GuestRc = 0

    # --- pull --------------------------------------------------------------
    $dest = Join-Path $scratch 'out'
    $script:GuestOut = '2 1 30'
    $out = Capture { Pull-Main @('testvm', 'C:\Users\me\out\*.log', $dest) }
    Check 'pull names the guest pattern' 'C:\Users\me\out\*.log' (LastSrc)
    CheckTrue 'pull creates the destination'   (Test-Path -LiteralPath $dest)
    CheckTrue 'pull reports files and directories' ($out -match '2 files and 1 directory pulled in 30ms')
    Check     'a pull share is writable' $true $script:PublishWrite
    CheckTrue 'a completed pull leaves no staged tree' (-not (Test-Path -LiteralPath $script:LastScratch))

    $rc = ExitCodeOf { Capture { Pull-Main @('testvm', 'C:\', $dest) } }
    Check 'pulling the guest root is refused' 1 $rc

    $script:GuestRc = 94
    $rc = ExitCodeOf { Capture { Pull-Main @('testvm', 'nothing\here\*', $dest) } }
    Check 'no match in the guest is exit 94' 94 $rc
    $script:GuestRc = 0

    # --- nothing before the transfer is known to be possible ----------------
    #
    # Contract section 7: "Nothing is created and nothing is prompted for until
    # the transfer is known to be possible", and the worst available ordering is
    # being asked to approve Administrator and *then* told the guest is not
    # running. The share publisher is the thing that prompts, so "was it called"
    # is the whole assertion.
    $before = $script:Published
    $script:ReadyFails = $true
    $rc = ExitCodeOf { Capture { Push-Main @('testvm', $tree, 'opt\app') } }
    Check 'a guest that is not ready stops the run'     1 $rc
    Check 'and nothing was published before it did'     $before $script:Published
    $script:ReadyFails = $false

    # A source that is not there is named as that, and also before anything is
    # published.
    $before = $script:Published
    $rc = ExitCodeOf { Capture { Push-Main @('testvm', (Join-Path $scratch 'nope'), 'opt') } }
    Check 'a missing source stops the run'          1 $rc
    Check 'and nothing was published for it either' $before $script:Published

    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine("$($script:Pass) passed, $($script:Fail) failed")
} finally {
    # [IO.Directory]::Delete, not Remove-Item: Remove-Item truncates a path at a
    # `~` segment, and a temp directory on a profile with an 8.3 short name has
    # one. See Remove-VirutilsFile in modules/win/paths.ps1.
    foreach ($d in @($env:VIRUTILS_DIR, $scratch)) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            try { [IO.Directory]::Delete($d, $true) } catch { }
        }
    }
}

exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
