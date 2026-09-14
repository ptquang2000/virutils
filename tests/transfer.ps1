<#
.SYNOPSIS
  The contract's conformance minimum for transfer, against a real guest.

.DESCRIPTION
  Contract section 8 lists "push then pull round-trips a tree byte-for-byte"
  and "a second push of an unchanged tree moves nothing" as the minimum, and
  section 8 also lists them as missing, because they need a running guest with
  an agent in it. This is that tier. It drives the installed driver as a child
  process -- the whole thing, elevation prompt and all -- because what is under
  test is the observable behaviour of `virutil push` and `virutil pull` and not
  any function inside them.

  **It skips, loudly, when there is no guest**, following the pattern
  tests/conformance.sh already uses when it cannot find a PowerShell
  interpreter. A test that exists and skips is worth more than one that stays
  hypothetical: the moment a guest is up, the minimum starts being checked
  instead of asserted.

  Two things it needs that the rest of the suite does not: a running Windows
  guest (named by VIRUTILS_TEST_VM, default win11) and a person to approve the
  elevation prompts, one per transfer. There is no way to have the first
  without the second -- publishing a share on this host's own SMB server is
  what needs Administrator, and automating that prompt away would mean
  installing a service.

  The second half is what no amount of unit testing reaches: that a transfer
  which ends, and a transfer which is killed in the middle, both leave no
  account, no share and no staged tree on this machine.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent $here
$driver  = Join-Path $root 'virutil.ps1'

# Only for the state layout: this tier drives the whole driver as a child
# process, so the roots are read from the same place it reads them rather than
# spelled again here.
. (Join-Path $root 'modules\parser.ps1')
. (Join-Path $root 'modules\paths.ps1')

$shell   = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$vm      = if ($env:VIRUTILS_TEST_VM) { $env:VIRUTILS_TEST_VM } else { 'win11' }
$guestDir = 'virutil-xfer-test'

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
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
function Skipped { param([string]$Why) [Console]::Out.WriteLine("skip     $Why"); $script:Skip++ }

# Run the driver and hand back its output and exit code together. Not
# Start-Process: its streams would go somewhere this cannot read, and the
# guest's own stderr is half of what a failure here says.
function Drive {
    param([string[]]$Argv)
    $out = & $shell -NoProfile -File $driver @Argv 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Replace("`r`n", "`n") }
}

# What this driver leaves on the machine when it is working correctly: nothing.
#
# Spelled out here rather than by calling Get-XferStrays, even though the two
# ask Windows the same two questions. That function is part of what is under
# test -- it decides what a *live* sibling is and skips it -- and an assertion
# that "nothing was left behind" must not be satisfiable by the same judgement
# that decides what counts as left behind. This one looks at the prefix and
# nothing else.
function Get-XferResidue {
    $names = @()
    try { $names += @(Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } catch { }
    try { $names += @(Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } catch { }
    # Comma-wrapped, for the reason Get-RestArgs in modules/parser.ps1 is:
    # `return` unrolls an array on the way out, so the empty case -- which is
    # the *expected* one here -- arrived as $null, and reading .Count on it
    # under StrictMode ended the run with a PropertyNotFound instead of
    # answering "nothing was left behind".
    return ,@($names | Where-Object { $_ -like 'vxp-*' } | Select-Object -Unique)
}

function Get-TreeFingerprint {
    param([string]$Path)
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($Path.Length).TrimStart('\', '/').Replace('\', '/')
        $out += "$rel $((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash)"
    }
    return ($out -join "`n")
}

# --- is there a guest? ------------------------------------------------------

$ping = Drive @('exec', 'ping', $vm)
if ($ping.Code -ne 0) {
    Skipped "no guest to test against: 'virutil exec ping $vm' failed. Start one, or set VIRUTILS_TEST_VM."
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine("$($script:Pass) passed, $($script:Fail) failed, $($script:Skip) skipped")
    exit 0
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("virutil-xfer-" + [Guid]::NewGuid().ToString('N'))
try {
    $src = Join-Path $scratch 'tree'
    $out = Join-Path $scratch 'out'
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'sub') | Out-Null
    Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value 'alpha' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'b.bin') -Value ('A' * 5000) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'sub\c.txt') -Value 'gamma' -Encoding ASCII

    # Let anything still going away go away before the baseline is taken.
    #
    # The interrupted case below kills a transfer, and its elevated helper needs
    # a moment to notice and tear down. Two runs back to back therefore start
    # with the previous one's share still on the machine and watch it vanish
    # mid-run, which fails an assertion about *this* run for something the last
    # one was already doing correctly. Waiting is not weakening the assertion:
    # whatever is still here after this is treated as the baseline and has to
    # still be here at the end.
    $settle = [Diagnostics.Stopwatch]::StartNew()
    while ($settle.ElapsedMilliseconds -lt 60000) {
        if ((Get-XferResidue).Count -eq 0 -and
            @(Get-ChildItem -LiteralPath $script:VirutilsTmpDir -Directory -ErrorAction SilentlyContinue).Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $residueBefore = Get-XferResidue

    # --- push -------------------------------------------------------------
    $r = Drive @('push', $vm, $src, "$guestDir\")
    Check 'push exits 0' 0 $r.Code
    CheckTrue 'push reports what is present' ($r.Out -match 'file(s)? present')

    # --- a second push of an unchanged tree moves nothing ------------------
    #
    # The property the whole transport exists for, and the one thing that could
    # not be learned without a guest: whether robocopy's delta holds across an
    # authenticated SMB session the way it does across the bash driver's
    # anonymous one.
    $r2 = Drive @('push', $vm, $src, "$guestDir\")
    Check 'a second push exits 0' 0 $r2.Code
    CheckTrue 'and moves nothing' ($r2.Out -match 'all up to date')

    # --- pull, and the round trip -----------------------------------------
    $r3 = Drive @('pull', $vm, "$guestDir\tree", $out)
    Check 'pull exits 0' 0 $r3.Code

    $want = Get-TreeFingerprint $src
    $got  = Get-TreeFingerprint (Join-Path $out 'tree')
    Check 'push then pull round-trips the tree byte for byte' $want $got

    # --- and nothing is left on this machine ------------------------------
    Check 'a completed transfer leaves no account and no share' `
        ($residueBefore -join ',') ((Get-XferResidue) -join ',')
    $leftover = @(Get-ChildItem -LiteralPath $script:VirutilsTmpDir -Directory -ErrorAction SilentlyContinue)
    Check 'and no staged tree' 0 $leftover.Count

    # --- an interrupted transfer leaves none either ------------------------
    #
    # Killed once the share is up, which is the window where a crash would
    # otherwise strand an account and a share. The helper is keyed on this
    # process rather than on a message precisely so that it still tears down.
    $child = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-File', $driver, 'push', $vm, $src, "$guestDir-interrupted\")
    $up = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt 120000) {
        if ((Get-XferResidue).Count -gt $residueBefore.Count) { $up = $true; break }
        if ($child.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $up) {
        Skipped 'could not catch a transfer with its share up, so the interrupted case was not exercised'
        if (-not $child.HasExited) { $child.Kill() }
    } else {
        $child.Kill()
        $child.WaitForExit()
        $gone = $false
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($clock.ElapsedMilliseconds -lt 60000) {
            if (((Get-XferResidue) -join ',') -eq ($residueBefore -join ',')) { $gone = $true; break }
            Start-Sleep -Milliseconds 500
        }
        CheckTrue 'an interrupted transfer leaves no account and no share' $gone
        $leftover = @(Get-ChildItem -LiteralPath $script:VirutilsTmpDir -Directory -ErrorAction SilentlyContinue)
        Check 'and no staged tree' 0 $leftover.Count
    }
} finally {
    Drive @('exec', 'ps', $vm,
        "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 'C:\$guestDir', 'C:\$guestDir-interrupted'") | Out-Null
    if (Test-Path -LiteralPath $scratch) {
        try { [IO.Directory]::Delete($scratch, $true) } catch { }
    }
}

[Console]::Out.WriteLine('')
[Console]::Out.WriteLine("$($script:Pass) passed, $($script:Fail) failed, $($script:Skip) skipped")
exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
