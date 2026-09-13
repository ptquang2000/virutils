<#
.SYNOPSIS
  install.ps1 -- put virutil.ps1 on PATH on a Windows host.

.DESCRIPTION
  The Windows counterpart to install.sh, and deliberately its mirror: same
  actions, same defaults, same "the checkout stays the source of truth" rule.

  virutil.ps1 resolves its module and payload directories from its own path,
  following a symlink rather than going around one, so this links the driver
  instead of copying it. A copy would look for modules\ beside the copy and
  find nothing.

  Windows will not create a symlink without administrator rights or Developer
  Mode. When the link fails, this writes a shim in its place -- a two-line
  script that invokes the driver where it actually lives -- which needs no
  privilege and leaves the same single source of truth. Uninstall removes
  either, and only if it is ours.

  Completion is a dot-source line in your $PROFILE rather than a linked file:
  PowerShell has no fpath to drop a completer into, so the profile is the only
  place a registration can happen. The line goes in a marked block so that
  installing twice changes nothing and uninstalling takes back exactly what
  was added. completions\_virutil stays zsh-only and is not touched here.

    .\install.ps1                    link into ~\.local\bin, register completion
    .\install.ps1 -NoCompletions     skip the $PROFILE edit
    .\install.ps1 -Check             report on dependencies and exit
    .\install.ps1 -Uninstall         remove what this script installed

.PARAMETER Bin
  Where to link virutil.ps1. Defaults to the BIN environment variable, then
  to ~\.local\bin -- the same default install.sh uses.

.PARAMETER NoCompletions
  Link the driver but leave $PROFILE alone.

.PARAMETER Check
  Only report on host dependencies. Exits 1 if a required one is missing.

.PARAMETER Uninstall
  Remove the link or shim, leaving the checkout alone.
#>
[CmdletBinding()]
param(
    [string] $Bin,
    [switch] $NoCompletions,
    [switch] $Check,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Log  { param($m) Write-Host '[*] ' -ForegroundColor Blue   -NoNewline; Write-Host $m }
function Warn { param($m) Write-Host '[!] ' -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Err  { param($m) Write-Host '[x] ' -ForegroundColor Red    -NoNewline; Write-Host $m }
function Ok   { param($m) Write-Host '[+] ' -ForegroundColor Green  -NoNewline; Write-Host $m }

$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not $Bin) { $Bin = $env:BIN }
if (-not $Bin) { $Bin = Join-Path $HOME '.local\bin' }

$src  = Join-Path $here 'virutil.ps1'
$dest = Join-Path $Bin  'virutil.ps1'
$comp = Join-Path $here 'completions\virutil.completion.ps1'

# The profile block, fenced so uninstall can find both ends of what it wrote.
$compBegin = '# >>> virutil completion >>>'
$compEnd   = '# <<< virutil completion <<<'

# Stamped into a shim so uninstall can tell one it wrote from a file that
# happens to share the name. Nothing else keys on it.
$shimMark = '# installed by virutil install.ps1 -- do not edit'

# --- dependencies -----------------------------------------------------------
#
# The bash driver leans on a dozen host programs; this one leans on qemu and
# nothing else. The search path below is Get-QemuTools in modules\domain.ps1,
# and the two must agree -- a check that passes where the driver then dies is
# worse than no check.

function Test-Deps {
    $missing = 0

    Log 'Checking dependencies'

    $qemuDir = @(
        (Join-Path $env:USERPROFILE 'scoop\apps\qemu\current')
        'C:\Program Files\qemu'
    ) | Where-Object { Test-Path (Join-Path $_ 'qemu-system-x86_64.exe') } | Select-Object -First 1

    if (-not $qemuDir) {
        Warn 'qemu -- qemu-system-x86_64.exe not found (scoop install qemu)'
        Warn '        searched ~\scoop\apps\qemu\current and C:\Program Files\qemu'
        return 1
    }
    Ok "qemu -- $qemuDir"

    if (-not (Test-Path (Join-Path $qemuDir 'qemu-img.exe'))) {
        Warn 'qemu-img.exe missing beside qemu-system-x86_64.exe -- domain create cannot make a disk'
        $missing = 1
    }

    # The accelerator, asked of the binary rather than assumed from the build.
    $system = Join-Path $qemuDir 'qemu-system-x86_64.exe'
    try {
        if (((& $system -accel help) -join "`n") -match 'whpx') {
            Ok 'whpx -- this qemu has the accelerator'
        } else {
            Warn 'whpx -- this qemu has no whpx accelerator; domain cannot start a guest'
            $missing = 1
        }
    } catch {
        Warn "whpx -- could not run $system to ask: $($_.Exception.Message)"
        $missing = 1
    }

    # Windows 11 will not install without UEFI, so firmware is required here
    # rather than optional as it would be on the libvirt side.
    $code = Join-Path $qemuDir 'share\edk2-x86_64-code.fd'
    $vars = Join-Path $qemuDir 'share\edk2-i386-vars.fd'
    if ((Test-Path $code) -and (Test-Path $vars)) {
        Ok 'ovmf -- firmware present'
    } else {
        Warn "ovmf -- no edk2 firmware under $qemuDir\share; Windows 11 will not install"
        $missing = 1
    }

    # Optional, and only `usb` wants it: qemu reaches a device through libusb,
    # which cannot open one a Windows class driver already owns. UsbDk is what
    # lets it capture one anyway; short of that the device needs WinUSB bound to
    # it by hand (Zadig). Not counted as missing -- everything but passing a
    # device through works without it.
    if (Get-Service -Name 'UsbDk' -ErrorAction SilentlyContinue) {
        Ok 'UsbDk -- present; virutil usb can take a device from Windows'
    } else {
        Log 'UsbDk -- not installed; virutil usb can only pass a device with WinUSB bound to it'
    }

    # Needs elevation to read, so a failure to answer is reported as unknown
    # rather than as absent.
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction Stop
        if ($f.State -eq 'Enabled') {
            Ok 'Windows Hypervisor Platform -- enabled'
        } else {
            Warn 'Windows Hypervisor Platform is not enabled -- whpx will not attach'
            Warn '  enable: Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform'
            $missing = 1
        }
    } catch {
        Log 'Windows Hypervisor Platform -- cannot tell without elevation, skipping'
    }

    # Optional, and only for a Windows guest: the driver falls back to its own
    # search and to VIRUTILS_VIRTIO=none.
    if ($env:VIRUTILS_VIRTIO) {
        if ($env:VIRUTILS_VIRTIO -eq 'none' -or (Test-Path $env:VIRUTILS_VIRTIO)) {
            Ok "virtio-win -- VIRUTILS_VIRTIO=$($env:VIRUTILS_VIRTIO)"
        } else {
            Warn "optional: VIRUTILS_VIRTIO points at nothing: $($env:VIRUTILS_VIRTIO)"
        }
    } else {
        Log 'optional: VIRUTILS_VIRTIO unset -- a Windows guest gets no virtio drivers'
    }

    return $missing
}

# --- linking ----------------------------------------------------------------

function Install-Driver {
    if (-not (Test-Path -LiteralPath $src)) {
        Err "source missing: $src"
        return 1
    }

    $existing = if (Test-Path -LiteralPath $dest) { Get-Item -LiteralPath $dest -Force } else { $null }

    if ($existing -and $existing.LinkType -eq 'SymbolicLink' -and @($existing.Target)[0] -eq $src) {
        Log "already linked: $dest"
        return 0
    }

    New-Item -ItemType Directory -Path $Bin -Force | Out-Null

    if ($existing) {
        $backup = "$dest.bak.$stamp"
        Log "backing up $dest -> $backup"
        Move-Item -LiteralPath $dest -Destination $backup
    }

    try {
        New-Item -ItemType SymbolicLink -Path $dest -Target $src -ErrorAction Stop | Out-Null
        Ok "linked $dest -> $src"
    } catch {
        # No SeCreateSymbolicLinkPrivilege and no Developer Mode. The shim gets
        # to the same place: one driver, living in the checkout.
        Log 'cannot create a symlink here (needs admin or Developer Mode) -- writing a shim instead'
        @(
            $shimMark
            "& '$src' @args"
            'exit $LASTEXITCODE'
        ) | Set-Content -LiteralPath $dest -Encoding ASCII
        Ok "wrote shim $dest -> $src"
    }

    $onPath = ($env:PATH -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }) -contains $Bin.TrimEnd('\')
    if (-not $onPath) {
        Warn "$Bin is not on PATH -- add it for this session with:"
        Write-Host "      `$env:PATH = '$Bin;' + `$env:PATH"
        Warn 'and persist it with:'
        Write-Host "      [Environment]::SetEnvironmentVariable('PATH', '$Bin;' + [Environment]::GetEnvironmentVariable('PATH','User'), 'User')"
    }
    Log "PowerShell finds .ps1 on PATH, so this runs as: virutil domain list"

    return 0
}

# --- completion --------------------------------------------------------------
#
# $PROFILE is the user's file, not ours, so every edit here is confined to the
# fenced block and the file is backed up before the first one.

# The block's line range in $lines, or $null. Returned rather than acted on so
# install and uninstall agree on what "already there" means.
function Find-CompBlock {
    param([string[]]$Lines)
    $b = [Array]::FindIndex($Lines, [Predicate[string]] { $args[0].Trim() -eq $compBegin })
    if ($b -lt 0) { return $null }
    $e = [Array]::FindIndex($Lines, $b, [Predicate[string]] { $args[0].Trim() -eq $compEnd })
    if ($e -lt 0) { return $null }
    return @{ Begin = $b; End = $e }
}

function Install-Completion {
    if (-not (Test-Path -LiteralPath $comp)) {
        Warn "skip completion, source missing: $comp"
        return
    }

    $profilePath = $PROFILE.CurrentUserAllHosts
    $block = @($compBegin, ". '$comp'", $compEnd)

    if (-not (Test-Path -LiteralPath $profilePath)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
        Set-Content -LiteralPath $profilePath -Value $block -Encoding UTF8
        Ok "created $profilePath with the completion block"
        Log 'open a new shell, or dot-source your profile, to pick it up'
        return
    }

    $lines = @(Get-Content -LiteralPath $profilePath)
    $found = Find-CompBlock $lines

    if ($found) {
        if ($lines[$found.Begin..$found.End] -join "`n" -eq ($block -join "`n")) {
            Log "completion already registered in $profilePath"
            return
        }
        # Same block, different checkout. Rewrite in place rather than append,
        # so two paths never both register.
        Copy-Item -LiteralPath $profilePath -Destination "$profilePath.bak.$stamp"
        Log "backing up $profilePath -> $profilePath.bak.$stamp"
        $new = @()
        if ($found.Begin -gt 0) { $new += $lines[0..($found.Begin - 1)] }
        $new += $block
        if ($found.End -lt $lines.Count - 1) { $new += $lines[($found.End + 1)..($lines.Count - 1)] }
        Set-Content -LiteralPath $profilePath -Value $new -Encoding UTF8
        Ok "updated the completion block in $profilePath"
        return
    }

    Copy-Item -LiteralPath $profilePath -Destination "$profilePath.bak.$stamp"
    Log "backing up $profilePath -> $profilePath.bak.$stamp"
    Add-Content -LiteralPath $profilePath -Value (@('') + $block) -Encoding UTF8
    Ok "registered completion in $profilePath"
    Log 'open a new shell, or dot-source your profile, to pick it up'
}

function Uninstall-Completion {
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (-not (Test-Path -LiteralPath $profilePath)) { return }

    $lines = @(Get-Content -LiteralPath $profilePath)
    $found = Find-CompBlock $lines
    if (-not $found) {
        Log 'no completion block in your profile'
        return
    }

    Copy-Item -LiteralPath $profilePath -Destination "$profilePath.bak.$stamp"
    Log "backing up $profilePath -> $profilePath.bak.$stamp"

    $new = @()
    if ($found.Begin -gt 0) { $new += $lines[0..($found.Begin - 1)] }
    if ($found.End -lt $lines.Count - 1) { $new += $lines[($found.End + 1)..($lines.Count - 1)] }
    Set-Content -LiteralPath $profilePath -Value $new -Encoding UTF8
    Ok "removed the completion block from $profilePath"
}

function Uninstall-Driver {
    if (-not (Test-Path -LiteralPath $dest)) {
        Log "nothing at $dest"
        return
    }

    $item = Get-Item -LiteralPath $dest -Force

    if ($item.LinkType -eq 'SymbolicLink') {
        $target = @($item.Target)[0]
        if ($target -ne $src) {
            Warn "points elsewhere, leaving alone: $dest -> $target"
            return
        }
        Remove-Item -LiteralPath $dest -Force
        Ok "removed $dest"
        return
    }

    if ((Get-Content -LiteralPath $dest -TotalCount 1) -eq $shimMark) {
        Remove-Item -LiteralPath $dest -Force
        Ok "removed shim $dest"
        return
    }

    Warn "not a link or a shim of ours, leaving alone: $dest"
}

# --- dispatch ---------------------------------------------------------------

if ($Check -and $Uninstall) {
    Err 'pass one of -Check or -Uninstall, not both'
    exit 2
}

if ($Check) {
    exit (Test-Deps)
}

if ($Uninstall) {
    Log 'Uninstalling virutil'
    Uninstall-Driver
    if (-not $NoCompletions) { Uninstall-Completion }
    Ok "Done. The checkout at $here is untouched."
    exit 0
}

Log "Installing virutil from $here"
if ((Install-Driver) -ne 0) { exit 1 }
if (-not $NoCompletions) { Install-Completion }
if ((Test-Deps) -ne 0) { Warn 'installed, but some dependencies are missing (see above)' }
Ok 'Done.'
exit 0
