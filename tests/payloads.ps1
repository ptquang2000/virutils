<#
.SYNOPSIS
  Render every guest-side payload with fixed inputs and print them all.

.DESCRIPTION
  The PowerShell half of tests/payloads.sh, and the point is that it writes the
  same bytes. Both are compared against the one tests/golden/payloads.txt, so a
  renderer that drifts -- a quoting rule that stops matching, a placeholder
  filled differently, a comment line stripped by one and not the other -- fails
  here rather than in a guest.

  The values are the literals the bash harness's push/pull/sync functions
  compute for those same inputs, because push and pull are not ported to this
  driver yet. What is under test is the renderer, which is.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path (Split-Path -Parent $here) 'modules'
. (Join-Path $moduleDir 'parser.ps1')
. (Join-Path $moduleDir 'payload.ps1')

$unc  = '\\10.0.2.2\Tok3nTok3nTok3nTok3n'
$url  = 'rsync://10.0.2.2:23456/Tok3nTok3nTok3nTok3n'

# LF throughout and written to the raw stdout stream: the golden file is the
# bash harness's output, and a CRLF here would fail a comparison that is about
# the payloads rather than about line endings.
$out = [Console]::Out
function Section {
    param([string]$Name, [string]$Text)
    $out.Write("`n===== $Name =====`n")
    $out.Write($Text.Replace("`r`n", "`n"))
    $out.Write("`n")
}

Section 'push.ps1 dir -> dir'   (Invoke-Payload 'push-dir.ps1'  @{ SRC = $unc; DST = 'C:\opt\app\tree' })
Section 'push.ps1 dir/ -> dir'  (Invoke-Payload 'push-dir.ps1'  @{ SRC = $unc; DST = 'C:\opt\app' })
Section 'push.ps1 file -> dir'  (Invoke-Payload 'push-file.ps1' @{ SRC = "$unc\one.txt"; DST = 'C:\opt\app\one.txt' })
Section 'push.ps1 file -> file' (Invoke-Payload 'push-file.ps1' @{ SRC = "$unc\one.txt"; DST = 'C:\opt\app\two.txt' })
Section 'push.sh dir -> dir'    (Invoke-Payload 'push-dir.sh'   @{ SRC = "$url/"; DST = '/opt/app/tree' })
Section 'push.sh dir/ -> dir'   (Invoke-Payload 'push-dir.sh'   @{ SRC = "$url/"; DST = '/opt/app' })
Section 'push.sh file -> dir'   (Invoke-Payload 'push-file.sh'  @{ SRC = "$url/one.txt"; DST = '/opt/app/one.txt' })
Section 'push.sh file -> file'  (Invoke-Payload 'push-file.sh'  @{ SRC = "$url/one.txt"; DST = '/opt/app/two.txt' })
Section 'pull.ps1'              (Invoke-Payload 'pull.ps1'      @{ SRC = 'C:\Users\me\out\*.log'; DST = $unc })
Section 'pull.sh'               (Invoke-Payload 'pull.sh'       @{ SRC = '/home/me/out/*.log'; DST = "$url/" })
Section 'sync.ps1'              (Invoke-Payload 'sync.ps1'      @{ SRC = $unc })
Section 'sync.sh'               (Invoke-Payload 'sync.sh'       @{ SRC = "$url/" })
Section 'probe.sh'              (Invoke-Payload 'probe.sh')
