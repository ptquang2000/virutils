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
$moduleDir = Join-Path (Split-Path -Parent $here) 'modules'
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

    # Get-RestArgs stands in for the shell's `shift`, and the slice it replaces
    # counts backwards from the end once the array is exhausted -- which would
    # hand a module its own arguments reversed rather than none.
    Check 'rest of a two-element array'   'b'  ((Get-RestArgs @('a','b') 1) -join ',')
    Check 'rest past the end is empty'    ''   ((Get-RestArgs @('a') 1) -join ',')
    Check 'rest of an empty array'        ''   ((Get-RestArgs @() 1) -join ',')
    Check 'rest from index 2'             'c'  ((Get-RestArgs @('a','b','c') 2) -join ',')

    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine("$($script:Pass) passed, $($script:Fail) failed")
} finally {
    # [IO.Directory]::Delete, not Remove-Item: Remove-Item truncates a path at a
    # `~` segment, and a temp directory on a profile with an 8.3 short name has
    # one. See Remove-VirutilsFile in modules/paths.ps1.
    if (Test-Path -LiteralPath $env:VIRUTILS_DIR) {
        [IO.Directory]::Delete($env:VIRUTILS_DIR, $true)
    }
}

exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
