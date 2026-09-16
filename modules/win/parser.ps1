# parser -- top-level dispatch plus the helpers every module shares.
#
# The counterpart of modules/linux/parser in the bash tree, and deliberately the
# same shape: it declares $MODULES and the handful of helpers every other module
# calls, so it is the one file virutil.ps1 names and the rest are discovered.
# Keeping the two drivers structurally alike is what makes a change in one have
# an obvious address in the other -- see docs/contract.md.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What this driver answers to. Still shorter than the bash tree's list: `ui` is
# not ported, and a module that works beats two half-ported (contract section
# 7). A name absent here is refused by name rather than dispatched to a function
# that does not exist.
#
# `push` and `pull` arrived first. They were blocked rather than unwritten, on
# one question -- how a share on a Windows host authenticates a guest that
# refuses anonymous SMB -- which was measured against a real guest and answered
# with a throwaway local account per transfer. modules/win/xfer.ps1 carries the
# transport.
#
# `sync` is here now, and it did drop in beside them with nothing rearranged:
# its whole guest half is that transport plus the payload both drivers already
# shared. What it added to xfer is one way of filling a staging directory --
# sync builds its delivery tree there rather than copying one in. It delivers to
# a **Windows guest** only, and refuses `@guest=linux` and the `>pre-ui` /
# `>post-ui` run rules by name, up front: the first is the limit push and pull
# already have here, and the second is `ui`, below.
#
# `usb` is on both drivers, by two mechanisms: device_add over the QEMU monitor
# here, a libvirt <hostdev> there. What is on neither is the WSL case, where
# the device is on the far side of the kernel boundary -- see contract 7.
#
# `snapshot` was here and is gone. It shipped disk-only, because WHPX blocks
# qemu's VM-state save outright, and disk-only turned out not to be worth a
# command: the thing a snapshot is reached for -- put a running guest back the
# way it was -- is exactly the half this host cannot take. The measurements are
# kept in docs/contract.md section 7, as the reason for the removal rather than
# as a footnote to a command that still exists.
$script:MODULES = @('domain', 'exec', 'pull', 'push', 'sync', 'usb')

# Names the bash driver answers to that this one does not, and why. A name here
# is refused with its own reason instead of "unknown module", because each is in
# the grammar docs/contract.md section 2 publishes: someone who read that
# grammar and typed one has been told the command exists, and "unknown module"
# leaves them to work out alone which driver they are standing on.
#
# `ui` belongs here too and is not listed yet; it has never been on this driver,
# so it has never stopped working. `sync` was in this paragraph and has left it:
# it is in $MODULES now.
$script:ELSEWHERE = [ordered]@{
    snapshot = @(
        'virutil snapshot is a Linux-host command; this driver does not have it.'
        'It was here, disk-only, and was dropped. WHPX blocks saving a running'
        "guest's memory, so the half a snapshot is usually wanted for cannot be"
        'taken on this host at all -- see docs/contract.md section 7.'
    )
}

# --- saying things ----------------------------------------------------------
#
# Everything diagnostic goes to stderr, as it does in the bash tree, so that a
# module's real output can be piped without the commentary coming with it.
# Write-Host would go to the host's information stream and be invisible to a
# redirect, which is exactly the wrong behaviour for an error.

function Write-Err { param([string[]]$Message) $Message | ForEach-Object { [Console]::Error.WriteLine($_) } }
function Warn      { param([string[]]$Message) Write-Err $Message }
function Say       { param([string[]]$Message) Write-Err $Message }

# Die is the bash `die`: say it and stop with 1.
#
# It throws rather than calling exit, and that is load-bearing: `exit` inside a
# dot-sourced function tears the whole process down on the spot, so a `finally`
# further up -- the one that retires an SMB share or removes a staging tree --
# never runs. virutil.ps1 catches these at the top and turns them back into an
# exit code, once, where there is nothing left to clean up.
#
# The code travels in the exception's Data rather than in a custom exception
# class. A class defined in a dot-sourced file is a scope question with a
# different answer in every PowerShell version; Data is just a dictionary.
function New-VirutilError {
    param([string[]]$Message, [int]$Code)
    $e = [System.Management.Automation.RuntimeException]::new(($Message -join "`n"))
    $e.Data['VirutilCode'] = $Code
    return $e
}

function Die {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    throw (New-VirutilError $Message 1)
}

# DieWith CODE -- the same, with one of the exit codes in section 5 of the
# contract, which callers match on.
function DieWith {
    param([int]$Code, [Parameter(ValueFromRemainingArguments)][string[]]$Message)
    throw (New-VirutilError $Message $Code)
}

# A usage error is exit 1 and an asked-for help is exit 0, in both drivers and
# for every module. Carried as an exception for the same reason Die is.
function Usage {
    param([string[]]$Message, [int]$Code = 1)
    throw (New-VirutilError $Message $Code)
}

function Get-TopUsage {
    @(
        'usage: virutil MODULE [ARGS]'
        ''
        'domains'
        '  domain     the domain lifecycle: create, delete, list, start, shutdown, addr, port'
        ''
        'transfer'
        '  push       copy a file or directory from this host into a guest'
        '  pull       copy files out of a guest onto this host'
        "  sync       deliver a project's build output into a running guest"
        ''
        'guest'
        '  exec       run commands inside a guest via the QEMU guest agent'
        ''
        'hardware'
        '  usb        pass a host USB device through to a guest'
        ''
        'This is the Windows-host driver: raw QEMU under WHPX, no libvirt. It'
        'shares a contract with the bash driver rather than any source; see'
        'docs/contract.md. ui and snapshot are in the bash tree only: WHPX'
        'blocks saving a running guest memory image, and that is what took'
        'snapshot out of this one.'
        ''
        "push, pull and sync publish a share on this machine's own SMB server,"
        'so they prompt once for Administrator and mint a throwaway local'
        'account for the length of the transfer. They deliver to a Windows'
        'guest only. See README.md.'
        ''
        "Run 'virutil <module>' for a module's own usage."
    )
}

# Invoke-Dispatch ARGS -- the module name off the front, the rest handed on.
# Admits nothing outside $MODULES, so the name *is* the dispatch and there is no
# way to reach a function this file has not vouched for.
# Get-RestArgs ARGS N -- everything from index N on, or an empty array. The bash
# tree spells this `shift`; PowerShell has no such thing, and the slice that
# stands in for it (`$a[$n..($a.Count-1)]`) counts backwards from the end when
# the array is already exhausted, quietly handing back the whole thing reversed.
#
# Both returns are comma-wrapped, because `return` unrolls an array on the way
# out: `@()` would arrive as $null and a one-element slice as a bare string.
# Either one costs the caller `.Count`, which under StrictMode is not a $null
# that falls through but a PropertyNotFound that ends the run. Callers that hand
# $rest straight to a [string[]] parameter never saw this -- the binder coerced
# the scalar back -- so it stayed hidden until a caller read .Count itself.
function Get-RestArgs {
    param([string[]]$Arguments, [int]$From = 1)
    if (-not $Arguments -or $From -ge $Arguments.Count) { return ,@() }
    return ,@($Arguments[$From..($Arguments.Count - 1)])
}

function Invoke-Dispatch {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { Usage (Get-TopUsage) 1 }

    $module = $Arguments[0]
    if ($module -in @('help', '-h', '--help')) { Usage (Get-TopUsage) 0 }

    if ($script:ELSEWHERE.Contains($module)) { Die $script:ELSEWHERE[$module] }

    if ($module -notin $script:MODULES) {
        Die "virutil: unknown module: $module (see: virutil help)"
    }

    $rest = Get-RestArgs $Arguments 1

    # Every module declares <Name>-Main, so the name is the dispatch -- the same
    # rule the bash driver's "${MODULE}_main" follows.
    $name = $module.Substring(0, 1).ToUpperInvariant() + $module.Substring(1)
    & "$name-Main" $rest
}
