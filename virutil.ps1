<#
.SYNOPSIS
  virutil -- drive QEMU guest operations from a Windows host.

.DESCRIPTION
  The second of virutil's two drivers. `virutil` (bash) runs on a Linux host
  against libvirt/KVM; this one runs on a Windows host against raw QEMU under
  WHPX, where there is no libvirt at all. They share no source. What they share
  is docs/contract.md -- the command grammar, the state layout, the exit codes
  and the invariants -- and payloads/, the scripts that go *into* a guest, which
  are keyed on the guest's OS rather than the host's and so are byte-identical
  under both.

  A change to the contract is a change to both drivers or it is a bug.

  The shape here mirrors the bash driver deliberately: that one sources
  modules/parser (which declares the module list and the shared helpers) and
  then every other module, and dispatches to <name>_main. This dot-sources
  modules/*.ps1 and dispatches to <Name>-Main. Keeping them alike is what gives
  a change in one tree an obvious address in the other.

    virutil help    the module list
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Resolved from this script's own path, through a symlink rather than around
# one, so an installed virutil.ps1 still finds its modules and payloads.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$item = Get-Item -LiteralPath $MyInvocation.MyCommand.Path
if ($item.LinkType -eq 'SymbolicLink' -and $item.Target) {
    # Target is a string[] on Windows PowerShell 5.1 and a plain string on
    # PowerShell 7. Indexing it blindly would take the first *character* on 7 --
    # "C" -- and resolve the module directory against the working directory
    # instead. @(...) makes both shapes an array.
    $target = @($item.Target)[0]
    $here = Split-Path -Parent ([IO.Path]::GetFullPath($target))
}
$moduleDir = Join-Path $here 'modules'

# The exit code a module leaves behind. `exec` sets it to the guest's own, which
# the contract says becomes ours; everything else leaves it at 0 and fails by
# throwing instead.
$script:VirutilExit = 0

# parser bootstraps: it declares $MODULES and the helpers every other module
# calls, so it is the one file named here. The rest are discovered -- the shared
# libraries (everything $MODULES does not list) before the command modules,
# since they set the roots a command module reads as it loads.
. (Join-Path $moduleDir 'parser.ps1')

$commandModules = $script:MODULES | ForEach-Object { "$_.ps1" }
Get-ChildItem -LiteralPath $moduleDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    if ($_.Name -eq 'parser.ps1') { return }
    if ($_.Name -in $commandModules) { return }
    . $_.FullName
}
foreach ($m in $commandModules) { . (Join-Path $moduleDir $m) }

$code = $null
try {
    Invoke-Dispatch $args
} catch {
    # Every failure in this driver is thrown rather than exited, so that the
    # `finally` below -- and any further down, the ones that retire a share or
    # remove a staging tree -- run before the process goes away. This is the one
    # place that turns one back into an exit code.
    $code = 1
    $e = $_.Exception
    if ($e.Data -and $e.Data.Contains('VirutilCode')) {
        $code = [int]$e.Data['VirutilCode']
    } else {
        # Not one of ours: a bug rather than a diagnosis, so it keeps its stack.
        [Console]::Error.WriteLine($_.ScriptStackTrace)
    }
    if ($e.Message) { [Console]::Error.WriteLine($e.Message) }
} finally {
    # The guest agent channel is one per qemu process rather than one per
    # command -- qemu's chardev does not go back to listening once a client has
    # come and gone -- so the run holds it open and closes it here, once,
    # however the run ends. See Get-GuestAgentChannel in modules/guest.ps1.
    Close-GuestAgentChannels
}

if ($null -ne $code) { exit $code }
exit $script:VirutilExit
