<#
.SYNOPSIS
  ui on a Windows host, with the guest agent and push substituted.

.DESCRIPTION
  The two seams are the guest agent boundary -- so the launch script that would
  have gone into the guest is captured and read back -- and Push-Main, which is
  the whole of setup's delivery and is tested in its own right by
  tests/win/transfer.ps1.

  What is asserted:

    * the grammar and its exit codes, which are contract;
    * run renders the native launcher (payloads/win/ui.ps1) with the right
      session, token kind and argv -- options stop at APP;
    * the guest turns that argv into one command line by the MSVC rules,
      run for real with the launch swapped for an echo;
    * a guest answering 96 (no one logged on) names the fix, with code 96;
    * setup with a warm cache touches no network and hands push exactly
      the cached PsExec and C:\virutil\ -- and with no VM, no push at all.
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
. (Join-Path $moduleDir 'ui.ps1')

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

# Dies BODY -- the message and the exit code a thrown virutil error carries, or
# an empty message and $null if BODY returned.
function Dies {
    param([scriptblock]$Body)
    try { & $Body | Out-Null; return @{ Msg = ''; Code = $null } }
    catch {
        $e = $_.Exception
        $code = if ($e.Data -and $e.Data.Contains('VirutilCode')) { [int]$e.Data['VirutilCode'] } else { $null }
        return @{ Msg = $e.Message; Code = $code }
    }
}

function Capture {
    param([scriptblock]$Body)
    $outOrig = [Console]::Out
    $errOrig = [Console]::Error
    $buf = New-Object IO.StringWriter
    [Console]::SetOut($buf)
    [Console]::SetError($buf)
    try { & $Body | Out-Null }
    finally { [Console]::SetOut($outOrig); [Console]::SetError($errOrig) }
    return $buf.ToString().Replace("`r`n", "`n")
}

# --- the seams ---------------------------------------------------------------

$script:Sent    = @()
$script:GuestRc = 0
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
            return ([pscustomobject]@{
                exited = $true
                exitcode = $script:GuestRc
                'out-data' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
                    'started PID 1234 in session 1 as WIN11\me'))
            })
        }
        default { throw "the test agent was asked for $Command" }
    }
}

$script:Pushed = @()
function Push-Main { param([string[]]$Arguments) $script:Pushed += ,@($Arguments) }

try {
    # --- grammar ------------------------------------------------------------
    Check 'no verb is a usage error'  1 (Dies { Ui-Main @() }).Code
    Check '-h exits 0'                0 (Dies { Ui-Main @('-h') }).Code
    Check '--help exits 0'            0 (Dies { Ui-Main @('--help') }).Code
    Check 'an unknown verb exits 1'   1 (Dies { Ui-Main @('bogus') }).Code
    Check 'run with no VM exits 1'    1 (Dies { Ui-Main @('run') }).Code
    Check 'run with no APP exits 1'   1 (Dies { Ui-Main @('run', 'win11') }).Code
    Check 'setup -h exits 0'          0 (Dies { Ui-Main @('setup', '-h') }).Code
    Check 'setup with two VMs exits 1' 1 (Dies { Ui-Main @('setup', 'a', 'b') }).Code
    Check 'setup with a bad flag exits 1' 1 (Dies { Ui-Main @('setup', '--nope') }).Code
    CheckTrue 'the usage names both verbs' `
        ((Dies { Ui-Main @() }).Msg -match 'ui setup' -and (Dies { Ui-Main @() }).Msg -match 'ui run')

    Check 'run -h exits 0'                 0 (Dies { Ui-Main @('run', '-h') }).Code
    Check 'run VM -i with no number exits 1' 1 (Dies { Ui-Main @('run', 'win11', '-i', 'notepad.exe') }).Code
    Check 'run VM -i with no APP exits 1'  1 (Dies { Ui-Main @('run', 'win11', '-i', '2') }).Code
    Check 'run VM -s with no APP exits 1'  1 (Dies { Ui-Main @('run', 'win11', '-s') }).Code
    Check 'run VM with a bad option exits 1' 1 (Dies { Ui-Main @('run', 'win11', '--nope', 'notepad.exe') }).Code

    # --- run ----------------------------------------------------------------
    #
    # The launch is payloads/win/ui.ps1 -- the native PsExec-service recipe --
    # and what is asserted is the values it was rendered with. Its text is
    # pinned by tests/golden/payloads.txt.
    $us = [string][char]0x1F
    $script:Sent = @(); $script:GuestRc = 0
    $out = Capture { Ui-Main @('run', 'win11', 'C:\Program Files\App\app.exe', "it's", '--flag') }
    Check 'run sends one script' 1 $script:Sent.Count
    $s = $script:Sent[0]
    CheckTrue 'it is the native launcher' ($s -match 'WTSQueryUserToken' -and $s -match 'CreateProcessAsUser')
    CheckTrue 'and never PsExec' ($s -notmatch 'PsExec')
    CheckTrue 'it targets the console session by default' ($s -match [regex]::Escape("`$session = ''"))
    CheckTrue 'as the logged-on user by default' ($s -match [regex]::Escape("`$as = 'user'"))
    CheckTrue 'unelevated by default' ($s -match [regex]::Escape("`$elevate = ''"))
    CheckTrue 'on winsta0\default' ($s -match [regex]::Escape('winsta0\\default'))
    CheckTrue 'each APP word is one argv element, quote doubled' `
        ($s -match [regex]::Escape("`$argv = 'C:\Program Files\App\app.exe${us}it''s${us}--flag'"))
    CheckTrue 'and no raw command line' ($s -match [regex]::Escape("`$cmdline = ''"))
    CheckTrue "the guest's line comes back" ($out -match 'started PID 1234')
    Check 'run leaves exit 0' 0 $script:VirutilExit

    # --- run, options -------------------------------------------------------
    $script:Sent = @()
    $null = Capture { Ui-Main @('run', 'win11', '-i', '2', '-s', '--elevated', 'notepad.exe') }
    $s = $script:Sent[0]
    CheckTrue '-i N picks session N' ($s -match [regex]::Escape("`$session = '2'"))
    CheckTrue '-s runs as SYSTEM' ($s -match [regex]::Escape("`$as = 'system'"))
    CheckTrue '--elevated asks for the linked token' ($s -match [regex]::Escape("`$elevate = '1'"))
    CheckTrue 'and the options are not part of APP' ($s -match [regex]::Escape("`$argv = 'notepad.exe'"))

    $script:Sent = @()
    $null = Capture { Ui-Main @('run', 'win11', 'app.exe', '-s', '-i', '3') }
    $s = $script:Sent[0]
    CheckTrue "options stop at APP: APP's -s is APP's" ($s -match [regex]::Escape("`$as = 'user'"))
    CheckTrue 'and travels in its argv' ($s -match [regex]::Escape("`$argv = 'app.exe${us}-s${us}-i${us}3'"))

    $script:Sent = @()
    $null = Capture { Ui-Main @('run', 'win11', '--session', '1', '--', '-dash.exe') }
    $s = $script:Sent[0]
    CheckTrue '-- ends the options' ($s -match [regex]::Escape("`$argv = '-dash.exe'") -and $s -match [regex]::Escape("`$session = '1'"))

    # --- run, the guest-side quoting ----------------------------------------
    #
    # The argv becomes one command line in the guest, by the MSVC rules the
    # started program parses with. Run for real in a child powershell with the
    # launch swapped for an echo, so nothing is started.
    $argv = @('C:\Program Files\App\app.exe', 'a b', 'q"x', 'tail\', 'c:\dir with\', '', 'plain', "it's") -join $us
    $text = Invoke-Payload 'ui.ps1' @{ SESSION = ''; AS = 'user'; ELEVATE = ''; ARGV = $argv; CMDLINE = '' }
    $call = '[Vu.Ui]::Run($want, $as -eq ''system'', $elevate -eq ''1'', $cmdline)'
    CheckTrue 'the payload launches through Run' ($text.Contains($call))
    $probe = Join-Path $env:VIRUTILS_DIR 'ui-probe.ps1'
    New-Item -ItemType Directory -Force -Path $env:VIRUTILS_DIR | Out-Null
    Set-Content -LiteralPath $probe -Encoding UTF8 -Value $text.Replace($call, '$cmdline')
    $line = (& powershell.exe -NoProfile -NonInteractive -File $probe | Select-Object -First 1)
    Check 'argv is quoted onto one command line' `
        '"C:\Program Files\App\app.exe" "a b" "q\"x" tail\ "c:\dir with\\" "" plain it''s' $line

    # --- run, no one logged on ----------------------------------------------
    $script:GuestRc = 96
    $r = Dies { Capture { Ui-Main @('run', 'win11', 'notepad.exe') } }
    CheckTrue 'no logged-on user names the fix' ($r.Msg -match 'log a user on' -and $r.Msg -match '-s')
    Check     'and exits 96, contract section 5' 96 $r.Code
    $script:GuestRc = 0

    # --- run, some other guest failure passes through ------------------------
    $script:GuestRc = 1
    $null = Capture { Ui-Main @('run', 'win11', 'notepad.exe') }
    Check 'any other guest code passes through' 1 $script:VirutilExit
    $script:GuestRc = 0

    # --- the sync entry point -----------------------------------------------
    $script:Sent = @()
    $null = Capture { Invoke-UiRunCmdline 'win11' '"C:\Program Files\App\app.exe" --restored' }
    CheckTrue 'a command line goes to the guest as one raw string' `
        ($script:Sent[0] -match [regex]::Escape("`$cmdline = '`"C:\Program Files\App\app.exe`" --restored'"))
    CheckTrue 'as the logged-on user' ($script:Sent[0] -match [regex]::Escape("`$as = 'user'"))

    # --- setup, with the cache already warm ---------------------------------
    #
    # A pre-seeded cache is the assertion that no network is touched: nothing
    # stubs Invoke-WebRequest, so a download attempt would fail the run.
    New-VirutilsDir $script:UiCache | Out-Null
    Set-Content -LiteralPath $script:UiCacheExe -Value 'not really psexec' -Encoding ASCII

    $script:Pushed = @()
    $out = Capture { Ui-Main @('setup') }
    CheckTrue 'setup with no VM says the cache is ready' ($out -match 'host cache ready')
    Check     'and pushes nothing' 0 $script:Pushed.Count

    $script:Pushed = @()
    $out = Capture { Ui-Main @('setup', 'win11') }
    Check 'setup VM pushes once' 1 $script:Pushed.Count
    Check 'into that VM'         'win11' $script:Pushed[0][0]
    Check 'the cached PsExec'    $script:UiCacheExe $script:Pushed[0][1]
    Check 'into C:\virutil\ as a directory' 'virutil\' $script:Pushed[0][2]
    CheckTrue 'and says what to do next' ($out -match "virutil ui run win11")
} finally {
    Remove-Item -LiteralPath $env:VIRUTILS_DIR -Recurse -Force -ErrorAction SilentlyContinue
}

[Console]::Out.WriteLine('')
[Console]::Out.WriteLine("$script:Pass passed, $script:Fail failed")
if ($script:Fail) { exit 1 }
