# paths -- where virutil keeps its state: one root, every artifact under it, so
# a single variable relocates the whole lot and a single directory holds
# everything virutil leaves behind. The counterpart of modules/paths, and the
# same layout, because the layout is contract (docs/contract.md section 3).
#
#   $VirutilsRoot        the root, one directory for all of it
#   $VirutilsConfDir     sync configs (looked up here first)
#   $VirutilsImageDir    domain disks, launchers, snapshot overlays, UEFI nvram
#   $VirutilsStagingRoot sync's incremental staging trees
#   $VirutilsPortDir     domain port forward state and logs
#   $VirutilsMntRoot     host mount points for guest filesystems
#   $VirutilsTmpDir      scratch for transfer payloads
#   $VirutilsCacheDir    third-party tools fetched once and reused (PsExec)

# --- one spelling, and the other accepted -----------------------------------
#
# The prefix is VIRUTILS_, plural, for every variable virutil reads, in this
# driver and in the bash one. It used to be both: modules/paths spelled the
# roots VIRUTILS_*, modules/domain read VIRUTIL_IMAGE_DIR (singular) in
# preference to it, and the first draft of this driver followed the singular --
# so one config pointed the two drivers at two different directories. That is
# the bug this settles. The singular is still read, second, and says so once.
$script:VirutilsDeprecated = @()

function Get-VirutilsEnv {
    param([string]$Name, [string]$Default = '')

    # An empty value counts as unset, so VIRUTILS_VIRTIO= falls through to the
    # default rather than naming a path of no characters.
    $new = [Environment]::GetEnvironmentVariable("VIRUTILS_$Name")
    if ($new) { return $new }

    $old = [Environment]::GetEnvironmentVariable("VIRUTIL_$Name")
    if ($old) {
        $script:VirutilsDeprecated += "VIRUTIL_$Name"
        return $old
    }
    return $Default
}

# Said once. Deliberately not fatal: the old spelling still works, and a hard
# failure would break a config that has been correct for as long as it existed.
function Write-VirutilsEnvWarning {
    if ($script:VirutilsDeprecated.Count -eq 0) { return }
    $seen = @($script:VirutilsDeprecated | Select-Object -Unique)
    Warn @(
        "deprecated: $($seen -join ' ') -- virutil reads the plural VIRUTILS_"
        'prefix now, in both the PowerShell and the bash driver. Rename it to'
        "VIRUTILS_$($seen[0] -replace '^VIRUTIL_', '') (and the rest likewise);"
        'the old spelling still works and will keep working.'
    )
}

# %USERPROFILE%\.virutils rather than %LOCALAPPDATA%: the staging tree has to
# survive a reboot, qemu has to reach the images, and config discovery reads
# here first. VIRUTILS_DIR moves everything at once.
$script:VirutilsRoot        = Get-VirutilsEnv 'DIR' (Join-Path $env:USERPROFILE '.virutils')

# Each piece can be moved on its own; each defaults under the root.
$script:VirutilsConfDir     = Get-VirutilsEnv 'CONF_DIR'     (Join-Path $script:VirutilsRoot 'conf')
$script:VirutilsImageDir    = Get-VirutilsEnv 'IMAGE_DIR'    (Join-Path $script:VirutilsRoot 'images')
$script:VirutilsStagingRoot = Get-VirutilsEnv 'STAGING_ROOT' (Join-Path $script:VirutilsRoot 'staging')
$script:VirutilsPortDir     = Get-VirutilsEnv 'PORT_DIR'     (Join-Path $script:VirutilsRoot 'ports')
$script:VirutilsMntRoot     = Get-VirutilsEnv 'MNT_ROOT'     (Join-Path $script:VirutilsRoot 'mnt')
$script:VirutilsTmpDir      = Get-VirutilsEnv 'TMP_DIR'      (Join-Path $script:VirutilsRoot 'tmp')
$script:VirutilsCacheDir    = Get-VirutilsEnv 'CACHE_DIR'    (Join-Path $script:VirutilsRoot 'cache')

# The knobs domain reads. Same two spellings, same preference.
#
# Only VIRUTILS_VIRTIO is acted on. The other three are in the contract's table
# but have no meaning on this host -- there is no libosinfo, no libvirt network
# to name, and WHPX will not boot Windows 11 without UEFI -- and section 4 says
# a variable in that table must be *accepted* by both drivers, not that both can
# act on it. They are read here so that is true, and
# Write-IgnoredEnvWarnings in modules/domain.ps1 says so out loud whenever one
# of them is actually set, which is the half that is easy to leave out: three
# fields nothing consults look, from outside, exactly like three fields that
# were honoured.
$script:VirutilsOsinfo   = Get-VirutilsEnv 'OSINFO'   'win11'
$script:VirutilsVirtio   = Get-VirutilsEnv 'VIRTIO'   ''
$script:VirutilsNetwork  = Get-VirutilsEnv 'NETWORK'  ''
$script:VirutilsFirmware = Get-VirutilsEnv 'FIRMWARE' 'uefi'

Write-VirutilsEnvWarning

# New-VirutilsDir PATH -- make it, quietly, and hand the path back so a caller
# can use it in the same breath.
function New-VirutilsDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
    return $Path
}

# Remove-VirutilsFile PATH -- delete one file. True if it was there.
#
# `[IO.File]::Delete` rather than `Remove-Item -LiteralPath`, and this is not a
# preference: **`Remove-Item` cannot delete through an 8.3 short path.** Measured
# on this host, where `%TEMP%` is `C:\Users\QUANG~1.PHA\AppData\Local\Temp` --
# the short alias for `C:\Users\quang.phan\...`:
#
#   Test-Path   -LiteralPath $f  ->  True
#   Remove-Item -LiteralPath $f  ->  "An object at the specified path
#                                     C:\Users\QUANG~1.PHA does not exist."
#   [IO.File]::Delete($f)        ->  deletes it
#
# The tilde is a red herring, and worth saying so because it is the obvious
# wrong conclusion: a directory *named* `QUANG~1.PHA`, or `FOO~1`, deletes
# perfectly well. What fails is a segment that is a genuine 8.3 alias for a
# directory whose long name differs, which `-LiteralPath` does not protect
# against -- the provider resolves the path anyway and the round trip loses it.
#
# It matters because it is not exotic: Windows gives a short name to any
# directory whose name is over eight characters or holds a dot, so an account
# called `quang.phan` has one, and `%USERPROFILE%` or `%TEMP%` on such a machine
# can be handed to virutil in short form. `domain delete` would then fail with
# an error naming a directory nobody mentioned. .NET is asked directly instead.
function Remove-VirutilsFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    [IO.File]::Delete($Path)
    return $true
}
