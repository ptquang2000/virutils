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
    * run's argv quoting: each APP token one single-quoted powershell string,
      so a space-path stays one argument and an embedded quote survives;
    * the launch targets the console session (-i $sid), never a bare -i;
    * a guest answering 97 becomes "run virutil ui setup", with code 97;
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
                    'notepad.exe started on 1 with process ID 1234.'))
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

    # --- run ----------------------------------------------------------------
    $script:Sent = @(); $script:GuestRc = 0
    $out = Capture { Ui-Main @('run', 'win11', 'C:\Program Files\App\app.exe', "it's", '--flag') }
    Check 'run sends one script' 1 $script:Sent.Count
    $s = $script:Sent[0]
    CheckTrue 'it runs the staged PsExec' ($s -match [regex]::Escape("`$exe = 'C:\virutil\PsExec.exe'"))
    CheckTrue 'it resolves the console session in the guest' ($s -match 'WTSGetActiveConsoleSessionId')
    CheckTrue 'and passes it to -i, never a bare -i' `
        ($s -match [regex]::Escape("@('-accepteula','-i',`"`$sid`",'-d',"))
    CheckTrue 'a space-path stays one argument' `
        ($s -match [regex]::Escape("'C:\Program Files\App\app.exe'"))
    CheckTrue 'an embedded single quote is doubled' ($s -match [regex]::Escape("'it''s'"))
    CheckTrue 'a trailing flag is its own argument' ($s -match [regex]::Escape(",'--flag')"))
    CheckTrue "PsExec's own line comes back" ($out -match 'process ID 1234')
    Check 'run leaves exit 0' 0 $script:VirutilExit

    # --- run, PsExec not staged ---------------------------------------------
    $script:GuestRc = 97
    $r = Dies { Capture { Ui-Main @('run', 'win11', 'notepad.exe') } }
    CheckTrue 'a missing PsExec names the fix' ($r.Msg -match "virutil ui setup win11")
    Check     'and exits 97, contract section 5' 97 $r.Code
    $script:GuestRc = 0

    # --- run, some other guest failure passes through ------------------------
    $script:GuestRc = 1
    $null = Capture { Ui-Main @('run', 'win11', 'notepad.exe') }
    Check 'any other guest code passes through' 1 $script:VirutilExit
    $script:GuestRc = 0

    # --- the sync entry point -----------------------------------------------
    $script:Sent = @()
    $null = Capture { Invoke-UiRunCmdline 'win11' '"C:\Program Files\App\app.exe" --restored' }
    CheckTrue 'a command line goes to PsExec as one raw string' `
        ($script:Sent[0] -match [regex]::Escape("'-accepteula -i ' + `$sid + ' -d ' + '`"C:\Program Files\App\app.exe`" --restored'"))

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
