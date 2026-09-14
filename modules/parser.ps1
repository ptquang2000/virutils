# parser -- top-level dispatch plus the helpers every module shares.
#
# The counterpart of modules/parser in the bash tree, and deliberately the same
# shape: it declares $MODULES and the handful of helpers every other module
# calls, so it is the one file virutil.ps1 names and the rest are discovered.
# Keeping the two drivers structurally alike is what makes a change in one have
# an obvious address in the other -- see docs/contract.md.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What this driver answers to. Shorter than the bash tree's list on purpose:
# `sync`, `push`, `pull` and `ui` are not ported yet, and a module that works
# beats two half-ported (contract section 7). A name absent here is refused by
# name rather than dispatched to a function that does not exist.
#
# `usb` is on both drivers, by two mechanisms: device_add over the QEMU monitor
# here, a libvirt <hostdev> there. What is on neither is the WSL case, where
# the device is on the far side of the kernel boundary -- see contract 7.
#
# `snapshot` is on both too, and is the newest of them. It is disk-only on this
# host and needs the domain shut off, because WHPX blocks qemu's VM-state save
# outright -- measured, and written up in the header of modules/snapshot.ps1.
# That is a contract difference (section 9), stated wherever the command is,
# rather than a silently smaller command.
$script:MODULES = @('domain', 'exec', 'snapshot', 'usb')

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
        '  snapshot   qcow2 internal snapshots: create, list, revert, delete'
        ''
        'guest'
        '  exec       run commands inside a guest via the QEMU guest agent'
        ''
        'hardware'
        '  usb        pass a host USB device through to a guest'
        ''
        'This is the Windows-host driver: raw QEMU under WHPX, no libvirt. It'
        'shares a contract with the bash driver rather than any source; see'
        'docs/contract.md. sync, push, pull and ui are in the bash tree only'
        'so far, and snapshot is disk-only here: WHPX blocks saving a running'
        "guest's memory, so a snapshot needs the domain shut off."
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
function Get-RestArgs {
    param([string[]]$Arguments, [int]$From = 1)
    if (-not $Arguments -or $From -ge $Arguments.Count) { return @() }
    return $Arguments[$From..($Arguments.Count - 1)]
}

function Invoke-Dispatch {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { Usage (Get-TopUsage) 1 }

    $module = $Arguments[0]
    if ($module -in @('help', '-h', '--help')) { Usage (Get-TopUsage) 0 }

    if ($module -notin $script:MODULES) {
        Die "virutil: unknown module: $module (see: virutil help)"
    }

    $rest = Get-RestArgs $Arguments 1

    # Every module declares <Name>-Main, so the name is the dispatch -- the same
    # rule the bash driver's "${MODULE}_main" follows.
    $name = $module.Substring(0, 1).ToUpperInvariant() + $module.Substring(1)
    & "$name-Main" $rest
}
