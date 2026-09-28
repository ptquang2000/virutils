# sync -- fetch a project's build output into a staging tree, then deliver that
# tree into a running guest. Config format: see README.md.
#
# The counterpart of modules/linux/sync, and the same two halves in the same
# order, because the config file is contract: a sync.conf written for the bash
# driver has to mean the same thing here.
#
#   build tree --(fetch)--> staging dir --(map)--> guest filesystem
#
# The delivery for that second half is the transport push and pull already use,
# in modules/win/xfer.ps1: the host serves a tree read-only on the address the
# guest reaches it at, and the guest's own robocopy takes only the files that
# differ from what it already holds. The guest keeps running.
#
# **What the map rules build is the delivery tree itself**, not a copy of it.
# The bash driver builds into a scratch directory under VIRUTILS_TMP_DIR and
# serves that; here the equivalent directory is the one Invoke-XferTransfer
# stages into, so sync builds straight into it through -StageWith. Building
# somewhere else and handing that over as -StageFrom would have been a smaller
# change to xfer, and would have cost a second local copy of the whole delivery
# -- which for a build tree is the expensive half of the run.
#
# Two things differ from the bash driver, and each is a Windows host rather
# than a matter of taste:
#
#   * **The fetch and the map copy with robocopy**, not rsync. Both halves are
#     host-to-host, so the copier is the host's; robocopy is on every Windows
#     machine and is the same copier the guest runs. Get-SyncRobocopyExcludes
#     is where an rsync exclude pattern becomes robocopy's /XF and /XD.
#   * **@guest=linux is refused**, by name and up front. Assert-XferReady
#     already refuses a Linux guest for push and pull -- see docs/contract.md
#     section 7 -- and a config that names one is refused before anything is
#     fetched rather than minutes later at the delivery.
#
# >pre-ui and >post-ui used to be a third: they run through PsExec, which is
# 'virutil ui', and this driver did not have it. It does now (modules/win/ui.ps1),
# and they run exactly as they do there.
#
# Everything else -- the parse, the lookup rules, the staging layout, the map
# semantics, the cleanup rules and what the guest runs -- is the bash module's
# behaviour, and the payload the guest runs (payloads/win/sync.ps1) is the same
# bytes on both drivers.

Set-StrictMode -Version Latest

# Where a config named rather than pathed is looked for.
#
# One directory and not two, which is the one place this diverges from the bash
# module's *lookup* rather than from its copiers. That module falls back to
# ~/.config/virutils so an install predating $VIRUTILS_CONF_DIR keeps working;
# on a Windows host there is no such install to keep working, because sync has
# never run here -- and %USERPROFILE%\.config\virutils is not a path anything
# has ever written. A fallback to it would be a compatibility promise to nobody.
# docs/contract.md section 3 says configs are looked up in <root>/conf first;
# here that is also last.
$script:SyncDefaultConf = 'sync.conf'

# Parsed config. Declared here and not only in Sync-Main so every function below
# reads a variable that exists under StrictMode -- and reset per run in
# Reset-SyncConfig, which is the one place the empty state is written down.
$script:SyncRepo     = ''
$script:SyncStaging  = ''
$script:SyncDest     = ''
$script:SyncGuestOs  = 'windows'
$script:SyncFetch    = @()
$script:SyncMappings = @()
$script:SyncExcludes = @()
$script:SyncCleanup  = @()
$script:SyncRunPre   = @()
$script:SyncRunPost  = @()

# What the delivery tree turned out to hold, read by the line printed before the
# transfer. Set while the tree is built, which happens inside the staging
# callback -- so they travel in module scope rather than as a return value.
$script:SyncFiles = 0
$script:SyncBytes = [long]0

function Reset-SyncConfig {
    $script:SyncRepo     = ''
    $script:SyncStaging  = ''
    $script:SyncDest     = ''
    # windows, because that is what every config written before @guest existed
    # means, and none of them says so.
    $script:SyncGuestOs  = 'windows'
    $script:SyncFetch    = @()
    $script:SyncMappings = @()
    $script:SyncExcludes = @()
    $script:SyncCleanup  = @()
    $script:SyncRunPre   = @()
    $script:SyncRunPost  = @()
    $script:SyncFiles    = 0
    $script:SyncBytes    = [long]0
}

function Get-SyncUsage {
    @(
        'usage: virutil sync VM [-c NAME|PATH]'
        ''
        '  VM                      domain delivered into. It has to be running,'
        '                          since the delivery goes over its own network'
        '  -c, --config NAME|PATH  config to use. A value that looks like a path'
        '                          -- one holding a slash, a backslash or a drive'
        '                          letter -- is taken as given; anything else'
        "                          names a config in $script:VirutilsConfDir"
        "                          ('.conf' is appended when absent)."
        "                          default: $script:SyncDefaultConf"
        '  -h, --help              this message'
        ''
        'The config is the whole interface; see README.md for its format.'
        ''
        'The delivery moves only what changed, so a re-run after a rebuild of'
        'one file moves one file.'
        ''
        "On this host the share comes from the machine's own SMB server, so the"
        'delivery prompts once for Administrator and mints a throwaway local'
        'account that the guest authenticates with and that is destroyed when'
        'the run ends. See README.md, "On a Windows host".'
        ''
        'This driver delivers to a Windows guest only: a config saying'
        '@guest=linux is refused; see docs/contract.md section 7. >pre-ui and'
        ">post-ui run rules need PsExec in the guest first: 'virutil ui setup VM'."
    )
}

# --- the config -------------------------------------------------------------

# Resolve-SyncConfig ARG -- which file to read, decided on spelling alone and
# never on what happens to exist. The same command has to mean the same config
# from any directory.
#
# "Contains a slash" is the bash driver's rule for "this is a path"; here it has
# to admit two more spellings, since on this host a path is written with
# backslashes and may start with a drive letter. Without that, `-c C:\x.conf`
# would be looked up as the *name* "C:\x.conf" under the config directory.
function Resolve-SyncConfig {
    param([string]$Arg)

    if (-not $Arg) {
        return (Join-Path $script:VirutilsConfDir $script:SyncDefaultConf)
    }
    if ($Arg -match '[/\\]' -or $Arg -match '^[A-Za-z]:') { return $Arg }

    $name = $Arg -replace '\.conf$', ''
    return (Join-Path $script:VirutilsConfDir "$name.conf")
}

# A rule's destination names a path under a root virutil owns: the staging tree,
# the guest's C:, or the share standing in for it. '..' would leave that root,
# so it is refused outright rather than normalised away.
function ConvertTo-SyncRelative {
    param([string]$Path, [string]$What = 'destination')
    return (ConvertTo-GuestWindowsPath $Path $What)
}

# A map rule's destination is relative to @dest. Empty means @dest itself.
function Join-SyncDest {
    param([string]$Rel)
    $parts = @()
    if ($script:SyncDest) { $parts += $script:SyncDest }
    if ($Rel)             { $parts += $Rel }
    return ($parts -join '/')
}

# The guest's own spelling of a path under the root the map rules deliver to,
# for the lines a person reads. Cosmetic: nothing is addressed through it.
function Get-SyncGuestShow {
    param([string]$Rel)
    if (-not $Rel) { return 'C:\' }
    return 'C:\' + $Rel.Replace('/', '\')
}

# Read-SyncConfig PATH -- the whole file, parsed up front so a malformed config
# fails before anything is touched. One directive per line; the forms and their
# sigils are README.md's table and are the bash module's, line for line.
function Read-SyncConfig {
    param([Parameter(Mandatory)][string]$Path)

    Reset-SyncConfig

    $lineno = 0
    foreach ($raw in @(Get-Content -LiteralPath $Path)) {
        $lineno++
        $line = ($raw -replace '#.*$', '').Trim()
        if (-not $line) { continue }

        $where = "${Path}:${lineno}"
        switch -Regex ($line) {
            '^@' {
                $kv  = $line.Substring(1)
                $eq  = $kv.IndexOf('=')
                $key = if ($eq -ge 0) { $kv.Substring(0, $eq) } else { $kv }
                $val = if ($eq -ge 0) { $kv.Substring($eq + 1) } else { '' }
                Set-SyncSetting $where $key $val
                break
            }
            '^!' {
                foreach ($p in ($line.Substring(1) -split '\s+')) {
                    if ($p) { $script:SyncExcludes += $p }
                }
                break
            }
            '^-' { $script:SyncCleanup += $line.Substring(1); break }
            '^>' { Add-SyncRunRule $where $line; break }
            '^<' {
                if ($line -notmatch '\|') { Die "${where}: fetch rule needs '|': $line" }
                $script:SyncFetch += $line.Substring(1)
                break
            }
            default {
                # Map rules are the only unsigilled form, so a line starting
                # with punctuation that is not a sigil is a mistyped directive
                # rather than a glob.
                if ("$($line[0])" -notmatch '[A-Za-z0-9_./*?]') {
                    Die "${where}: unrecognised directive: $line"
                }
                if ($line -notmatch '\|') { Die "${where}: missing '|' separator: $line" }
                $script:SyncMappings += $line
            }
        }
    }
}

# Set-SyncSetting WHERE KEY VALUE -- one @key=value. The settings that were
# removed are refused by name with what replaced them, exactly as the bash
# module refuses them: a config carrying one was written against a virutil that
# did something else, and ignoring the line would deliver by a route its author
# did not ask for.
function Set-SyncSetting {
    param([string]$Where, [string]$Key, [string]$Value)

    switch ($Key) {
        'repo'    { $script:SyncRepo = $Value; break }
        'staging' { $script:SyncStaging = $Value; break }
        'dest'    { $script:SyncDest = ConvertTo-SyncRelative $Value '@dest'; break }
        'guest'   {
            if ($Value -notin @('windows', 'linux')) {
                Die @("${Where}: unknown @guest value '$Value'."
                      "It wants 'windows' or 'linux'.")
            }
            $script:SyncGuestOs = $Value
            break
        }
        'domain' {
            Die @("${Where}: @domain is no longer a setting -- pass the domain as"
                  "an argument: virutil sync $Value")
            break
        }
        { $_ -in @('nbd', 'mnt', 'shutdown_timeout') } {
            Die @("${Where}: @$Key is no longer a setting -- it configured the"
                  'disk-image delivery, which has been removed. Drop the line; the'
                  'delivery goes into the running guest over its own network.')
            break
        }
        'transport' {
            Die @("${Where}: @transport is no longer a setting -- the disk-image"
                  'delivery it could name has been removed. Drop the line; the'
                  'delivery goes into the running guest over its own network.')
            break
        }
        default { Die "${Where}: unknown setting '$Key'" }
    }
}

# Add-SyncRunRule WHERE LINE -- one `>` rule. The phase is spelled out rather
# than defaulted: a command is free text, so there is no way to tell a missing
# keyword from a command that happens to start with one.
#
# Each rule is stored tagged with how it runs -- 'sh' in the guest shell as
# SYSTEM, or 'ui' on the interactive desktop -- so pre/post order survives
# across the two kinds. The bash module carries the same tag through a
# tab-separated string; a hashtable says the same thing without a separator a
# command must never contain.
function Add-SyncRunRule {
    param([string]$Where, [string]$Line)

    $rest = $Line.Substring(1).TrimStart()
    $when = ($rest -split '\s+', 2)[0]
    $cmd  = $rest.Substring($when.Length).Trim()

    if (-not $cmd) { Die "${Where}: run rule has no command: $Line" }

    switch ($when) {
        'pre'     { $script:SyncRunPre  += @{ Mode = 'sh'; Cmd = $cmd }; break }
        'post'    { $script:SyncRunPost += @{ Mode = 'sh'; Cmd = $cmd }; break }
        'pre-ui'  { $script:SyncRunPre  += @{ Mode = 'ui'; Cmd = $cmd }; break }
        'post-ui' { $script:SyncRunPost += @{ Mode = 'ui'; Cmd = $cmd }; break }
        default {
            Die @(
                "${Where}: run rule needs 'pre', 'post', 'pre-ui' or 'post-ui': $Line"
                '  >pre  COMMAND      before the files reach the guest (guest shell, as SYSTEM)'
                '  >post COMMAND      after they have'
                '  >pre-ui  COMMAND   same timing, launched on the interactive desktop (Windows guest, PsExec)'
                '  >post-ui COMMAND   likewise -- e.g. relaunch a GUI app the sync replaced'
            )
        }
    }
}

# Assert-SyncPortable CONF -- the one thing a config can ask for that this
# driver has no way to do, refused before anything is fetched.
#
# Up front, rather than where it would be reached: the obstacle is a property
# of the host, known before the config is even opened, so there is no reason to
# spend a fetch, an elevation prompt and a delivery before saying so.
#
# >pre-ui and >post-ui were refused here too, as a group, while this driver had
# no `ui`. They are not any more: Invoke-SyncRun hands them to
# Invoke-UiRunCmdline, as the bash module hands them to ui_run_cmdline.
function Assert-SyncPortable {
    param([string]$Conf)

    if ($script:SyncGuestOs -ne 'windows') {
        Die @(
            "$Conf says @guest=$($script:SyncGuestOs), and this host can only"
            'deliver to a Windows guest so far -- the same limit push and pull'
            'have here. The bash driver has the Linux side today; see'
            'docs/contract.md section 7. Nothing was fetched.'
        )
    }
}

# --- copying, host-side -----------------------------------------------------

# Get-SyncRobocopyExcludes -- the exclude patterns as robocopy arguments.
#
# rsync's --exclude=PAT matches a *name* at any depth, file or directory alike.
# robocopy splits that in two: /XF excludes files and /XD excludes directories,
# and neither implies the other. So every pattern goes to both, which is the
# mapping that preserves what a config already means -- an exclude of `obj`
# keeps out the directory and one of `*.pdb` keeps out the files, without the
# config having to say which kind each pattern is.
#
# What does not survive the mapping is an anchored pattern: rsync reads a
# leading or embedded '/' as a position in the tree, and robocopy's /XF matches
# on the name alone. README.md says so where the excludes are documented.
function Get-SyncRobocopyExcludes {
    $out = @()
    if (@($script:SyncExcludes).Count -eq 0) { return ,$out }
    $out += '/XF'; $out += @($script:SyncExcludes)
    $out += '/XD'; $out += @($script:SyncExcludes)
    return ,$out
}

# Invoke-SyncRobocopy FROM TO WHAT -- one host-side robocopy of a tree, with the
# config's excludes applied and robocopy's bitmap exit code read the way the
# payloads read theirs: 0 means nothing needed copying, and only >= 8 is a
# failure.
function Invoke-SyncRobocopy {
    param([string]$From, [string]$To, [string]$What)
    $argv = @($From, $To, '/E', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    $argv += (Get-SyncRobocopyExcludes)
    & robocopy @argv | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Die "$What (robocopy exit $rc)" }
}

# Test-SyncExcluded NAME -- does an exclude pattern cover this leaf name?
#
# Only for the single files a map rule names directly. A tree goes through
# robocopy, which applies the same patterns itself; this is the one path where
# nothing else would. -like is robocopy's and rsync's wildcard vocabulary for a
# name: '*' and '?' and nothing that reads a separator.
function Test-SyncExcluded {
    param([string]$Name)
    foreach ($p in @($script:SyncExcludes)) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

# --- fetch: build tree -> staging -------------------------------------------

# Invoke-SyncFetch -- mirror each fetch rule's source out of @repo into the
# staging tree. Host-to-host; it knows nothing about the guest.
#
# A source that does not exist is a warning and not an error, and that is
# deliberate rather than lenient: optional third-party trees are listed
# unconditionally and are simply absent in some checkouts.
function Invoke-SyncFetch {
    [Console]::Out.WriteLine("fetch: $($script:SyncRepo)")

    foreach ($rule in @($script:SyncFetch)) {
        $bar = $rule.IndexOf('|')
        $rel = $rule.Substring(0, $bar)
        $sub = ConvertTo-SyncRelative $rule.Substring($bar + 1) 'fetch destination'

        $from = Join-Path $script:SyncRepo ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $from -PathType Container)) {
            Warn "   warning: no such source dir, skipped: $rel"
            continue
        }

        $to = $script:SyncStaging
        if ($sub) { $to = Join-Path $to ($sub -replace '/', '\') }

        $shown = if ($sub) { $sub } else { '.' }
        [Console]::Out.WriteLine("   $rel -> $shown")
        Invoke-SyncRobocopy $from $to "could not fetch $rel into the staging tree"
    }
}

# --- map: staging -> the delivery tree --------------------------------------

# Build-SyncDelivery ROOT -- run every map rule, delivering into ROOT/<dst>.
#
# ROOT is the root of the export standing in for the guest's own system drive:
# the destinations are root-relative and the export is served with that same
# layout, so the rules need know nothing about the transport.
#
# The globs are expanded here and not in the guest, as they are in the bash
# module. A pattern with no wildcard expands to itself whether the file exists
# or not, so existence is checked rather than assumed -- left in, it reaches the
# copier as a missing source and fails the whole run over one file a build did
# not produce.
function Build-SyncDelivery {
    param([Parameter(Mandatory)][string]$Root)

    foreach ($rule in @($script:SyncMappings)) {
        $bar    = $rule.IndexOf('|')
        $globs  = $rule.Substring(0, $bar)
        $rel    = ConvertTo-SyncRelative $rule.Substring($bar + 1)
        $dstRel = Join-SyncDest $rel

        $items = @()
        foreach ($g in ($globs -split '\s+')) {
            if (-not $g) { continue }
            $pattern = Join-Path $script:SyncStaging ($g -replace '/', '\')
            $hits = @(Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue)
            if ($hits.Count -eq 0) { Warn "warning: no match for '$g'"; continue }
            $items += $hits
        }
        if ($items.Count -eq 0) {
            Warn "skipping '$dstRel': nothing matched"
            continue
        }

        $into = $Root
        if ($dstRel) { $into = Join-Path $Root ($dstRel -replace '/', '\') }

        [Console]::Out.WriteLine("-> $(Get-SyncGuestShow $dstRel) ($($items.Count) item(s))")
        New-VirutilsDir $into | Out-Null

        foreach ($item in $items) {
            if ($item.PSIsContainer) {
                # The directory itself lands under the destination, which is
                # what rsync does for a source named without a trailing slash.
                # A config that wants the *contents* writes the trailing '/*'
                # README.md documents, and that expands to the children here.
                Invoke-SyncRobocopy $item.FullName (Join-Path $into $item.Name) `
                    "could not build the delivery tree from $($item.FullName)"
            } elseif (-not (Test-SyncExcluded $item.Name)) {
                # Copy-Item keeps the file's last-write time, which is what the
                # guest compares to decide whether to fetch it -- the same
                # concern Copy-XferStage spells out in modules/win/xfer.ps1.
                Copy-Item -LiteralPath $item.FullName `
                          -Destination (Join-Path $into $item.Name) -Force
            }
        }
    }
}

# Measure-SyncDelivery ROOT -- what the tree turned out to hold. Counted from
# the tree and not from the guest: this is the authority on what was offered,
# where the guest can only say how much of it it needed.
function Measure-SyncDelivery {
    param([Parameter(Mandatory)][string]$Root)
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)
    $script:SyncFiles = $files.Count
    $total = [long]0
    foreach ($f in $files) { $total += [long]$f.Length }
    $script:SyncBytes = $total
}

# --- the guest side ---------------------------------------------------------

# Invoke-SyncRun VM WHEN RULES -- run each rule in config order: an 'sh' rule
# in the guest's powershell as SYSTEM, a 'ui' rule on the interactive desktop
# through PsExec (modules/win/ui.ps1).
#
# Fatal on the first failure: a run rule exists to make the copy land correctly
# ("stop the service", "run the installer"), so carrying on past one that did
# not happen would deliver a half-installed guest and report success.
#
# A guest that is not up has no agent to run anything, and nothing running in it
# worth stopping either -- so the rules are skipped rather than failed. Read
# here and not once at startup: the delivery checked the guest was running
# before the fetch, and this is minutes later.
function Invoke-SyncRun {
    param([string]$Vm, [string]$When, $Rules)

    $rules = @($Rules)
    if ($rules.Count -eq 0) { return }

    if (-not (Test-DomainRunning $Vm)) {
        Warn @("   $When run rules skipped: $Vm is not running, so there is no"
               'agent to run them')
        return
    }

    foreach ($r in $rules) {
        if ($r.Mode -eq 'ui') {
            # No guest-OS check here, unlike the bash module's: a config that
            # reaches this far has already been held to @guest=windows by
            # Assert-SyncPortable, and the guest to Windows by Assert-XferReady.
            # A missing PsExec dies inside with its own code and fix (97).
            [Console]::Out.WriteLine("run ($When/ui): $($r.Cmd)")
            Invoke-UiRunCmdline $Vm $r.Cmd
            $label = "$When-ui"
        } else {
            [Console]::Out.WriteLine("run ($When): $($r.Cmd)")
            Invoke-GuestPsText $Vm $r.Cmd
            $label = $When
        }
        if ($script:VirutilExit -ne 0) {
            Die @("$label run rule failed in $Vm`: $($r.Cmd)"
                  'Its output is above. Nothing after it was run.')
        }
    }
}

# Invoke-SyncCleanup VM -- the cleanup rules, run in the guest: each pattern is
# expanded there, every directory it names has its contents removed but not
# itself, and every file it names is deleted.
#
# The two-levels-down rule is enforced twice, once here on the pattern and once
# in the guest on what the pattern actually resolved to -- a wildcard can only
# be checked after it has been expanded, and that happens guest-side.
#
# The script is the bash module's sync_win_cleanup, statement for statement:
# both drivers run the same text in the guest, and both read the same
# one-line-per-outcome answer back.
function Invoke-SyncCleanup {
    param([string]$Vm)

    $pats = @()
    foreach ($raw in @($script:SyncCleanup)) {
        $pat = ConvertTo-GuestWindowsPath $raw 'cleanup path'
        if ($pat -notmatch '/') {
            Warn "refusing unsafe cleanup pattern: C:\$($pat.Replace('/','\'))"
            continue
        }
        $pats += 'C:\' + $pat.Replace('/', '\')
    }
    if ($pats.Count -eq 0) { return }

    $joined = (@($pats | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ', ')

    # One line per outcome, so the host prints it in one shape. Remove-Item is
    # caught per entry: one locked file should cost that file, not the rest of
    # the cleanup.
    $text = (@(
        '$ErrorActionPreference = "Stop"'
        "foreach (`$p in @($joined)) {"
        '  $hits = @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)'
        '  if ($hits.Count -eq 0) { "absent $p"; continue }'
        '  foreach ($d in $hits) {'
        '    $full = $d.FullName.TrimEnd("\")'
        '    $rel  = $full -replace "^[A-Za-z]:\\", ""'
        '    if (($rel -split "\\").Count -lt 2) { "unsafe $full"; continue }'
        '    if (-not $d.PSIsContainer) {'
        '      try { Remove-Item -LiteralPath $full -Force; "deleted $full" }'
        '      catch { "locked $full" }'
        '      continue'
        '    }'
        '    $n = 0'
        '    foreach ($k in @(Get-ChildItem -LiteralPath $full -Force)) {'
        '      try { Remove-Item -LiteralPath $k.FullName -Recurse -Force; $n++ }'
        '      catch { "locked $($k.FullName)" }'
        '    }'
        '    "emptied $n $full"'
        '  }'
        '}'
    ) -join "`n")

    $out = Invoke-GuestPsText $Vm $text -Capture
    if ($script:VirutilExit -ne 0) {
        Die @('the guest could not run the cleanup rules; its own error is above.'
              'What was delivered is already in place.')
    }
    Write-SyncCleanupReport $out
}

# Write-SyncCleanupReport OUT -- print what the guest reported. The protocol is
# one line per outcome: 'absent PATH', 'unsafe PATH', 'locked PATH',
# 'deleted PATH', 'emptied N PATH'.
function Write-SyncCleanupReport {
    param([string]$Out)
    foreach ($line in ($Out -split "`n")) {
        $l = $line.Trim()
        if (-not $l) { continue }
        $sp   = $l.IndexOf(' ')
        $kind = if ($sp -ge 0) { $l.Substring(0, $sp) } else { $l }
        $rest = if ($sp -ge 0) { $l.Substring($sp + 1) } else { '' }
        switch ($kind) {
            'absent'  { [Console]::Out.WriteLine("   not present, skipped: $rest"); break }
            'unsafe'  { Warn "refusing unsafe cleanup path: $rest"; break }
            'locked'  { Warn "   could not remove: $rest"; break }
            'deleted' { [Console]::Out.WriteLine("   deleted $rest"); break }
            'emptied' {
                $sp2  = $rest.IndexOf(' ')
                $n    = if ($sp2 -ge 0) { $rest.Substring(0, $sp2) } else { $rest }
                $path = if ($sp2 -ge 0) { $rest.Substring($sp2 + 1) } else { '' }
                [Console]::Out.WriteLine("   emptied $path ($n entries)")
                break
            }
            default { [Console]::Out.WriteLine("   $l") }
        }
    }
}

# Write-SyncReport VM REPORTED MS -- what was offered and whether any of it had
# to move. REPORTED is the guest's own "copied ms": bit 0 of robocopy's exit
# code, and its stopwatch, which is the copy alone without the agent round trip
# and powershell start-up this host's wall clock folds in.
#
# There is no file count or byte count from the guest on purpose: robocopy holds
# them only in its summary, and that summary is localised -- a non-English guest
# would have it parsed wrong rather than not at all.
function Write-SyncReport {
    param([string]$Vm, [string]$Reported, [double]$Ms)

    $f      = @("$Reported".Trim() -split '\s+')
    $copied = if ($f.Count -ge 1 -and $f[0]) { [int]($f[0]) } else { 0 }
    $gms    = if ($f.Count -ge 2 -and $f[1]) { [double]($f[1]) } else { $Ms }

    $what = "$($script:SyncFiles) file"
    if ($script:SyncFiles -ne 1) { $what += 's' }
    if ($copied) { $what += ' offered, the ones that differed copied' }
    else         { $what += ' offered, all already current in the guest' }
    [Console]::Out.WriteLine("$Vm`: $what in $(Format-Duration $gms)")
}

# Sync-Die RC -- name what went wrong; the guest has already printed its own
# line above. The code is section 5 of the contract and is the guest's, so this
# reads the same table push does.
function Sync-Die {
    param([int]$Rc)
    if ($Rc -eq 93) {
        DieWith $Rc @('robocopy could not deliver the tree in the guest (its exit'
                      'code is above). Anything it did copy is left where it'
                      'landed, and no cleanup rule and no >post rule has run.')
    }
    DieWith $Rc @(
        "the guest failed to fetch the delivery (exit $Rc); its own error is"
        'above. It had authenticated to the share, so a failure here is the copy'
        'rather than the credential.'
    )
}

# --- the command ------------------------------------------------------------

function Sync-Main {
    param([string[]]$Arguments)

    $vm = ''; $confArg = ''
    $argv = @($Arguments)
    for ($i = 0; $i -lt $argv.Count; $i++) {
        $a = $argv[$i]
        switch -Regex ($a) {
            '^(-c|--config)$' {
                if ($i + 1 -ge $argv.Count) { Warn "$a needs a value"; Usage (Get-SyncUsage) 1 }
                $confArg = $argv[$i + 1]; $i++
                break
            }
            # Refused rather than ignored, with the bash driver's own reasons: a
            # script written against that host and run against this one should
            # be told the same thing.
            '^--smb$'  { Die @('--smb is gone: delivering into the running guest'
                               'over SMB is what sync does now. Drop the flag.'); break }
            '^--live$' { Die @('--live is gone: the HTTP transport it named has'
                               'been removed. Delivering into the running guest is'
                               'what sync does now and uses SMB, which moves only'
                               'what changed; drop the flag.'); break }
            '^--disk$' { Die @("--disk is gone: writing the guest's disk image has"
                               'been removed. sync delivers into the running guest'
                               'over its own network; drop the flag and start the'
                               'guest.'); break }
            '^(-h|--help)$' { Usage (Get-SyncUsage) 0; break }
            '^-.+' { Warn "unrecognised argument: $a"; Usage (Get-SyncUsage) 1; break }
            default {
                if ($vm) { Warn "unexpected argument: $a"; Usage (Get-SyncUsage) 1 }
                $vm = $a
            }
        }
    }
    if (-not $vm) { Warn 'VM is required'; Usage (Get-SyncUsage) 1 }

    $conf = Resolve-SyncConfig $confArg
    if (-not (Test-Path -LiteralPath $conf -PathType Leaf)) {
        Die @("config not found: $conf"
              'Create it, or point -c elsewhere. README.md documents the format.')
    }

    Read-SyncConfig $conf
    Assert-SyncPortable $conf

    if (-not $script:SyncStaging) { Die "${conf}: @staging is required" }
    # A name under the root, never a path: '..' is refused outright, since
    # stripping a leading slash alone would not contain '..\..\Windows'.
    $stagingName = ConvertTo-GuestWindowsPath $script:SyncStaging '@staging'
    if (-not $stagingName) { Die "${conf}: @staging is required" }
    $script:SyncStaging = Join-Path $script:VirutilsStagingRoot ($stagingName -replace '/', '\')

    $runs = @($script:SyncRunPre).Count + @($script:SyncRunPost).Count
    [Console]::Out.WriteLine("config: $conf")
    [Console]::Out.WriteLine(
        "  $(@($script:SyncFetch).Count) fetch, $(@($script:SyncMappings).Count) map, " +
        "$(@($script:SyncExcludes).Count) exclude, " +
        "$(@($script:SyncCleanup).Count) cleanup, $runs run")
    [Console]::Out.WriteLine("  staging: $($script:SyncStaging)")
    [Console]::Out.WriteLine("  domain: $vm ($($script:SyncGuestOs))")
    [Console]::Out.WriteLine('  delivery: SMB into the running guest')

    # Before the fetch: a guest in the wrong state is worth saying so before
    # spending minutes copying a build tree, and before the elevation prompt.
    # Assert-XferReady is also what asks the guest what it is, so a config
    # saying @guest=windows against a Linux guest is caught by the same call.
    Assert-XferReady $vm

    # --- fetch: build tree -> staging ---------------------------------------
    if (@($script:SyncFetch).Count -eq 0) { Die "no fetch rules in $conf" }
    if (-not $script:SyncRepo) { Die "${conf}: @repo is required" }
    if (-not (Test-Path -LiteralPath $script:SyncRepo -PathType Container)) {
        Die "repo not found: $($script:SyncRepo)"
    }

    New-VirutilsDir $script:VirutilsStagingRoot | Out-Null
    New-VirutilsDir $script:SyncStaging | Out-Null
    Invoke-SyncFetch

    # --- deliver: staging -> guest ------------------------------------------
    if (-not (Test-Path -LiteralPath $script:SyncStaging -PathType Container)) {
        Die "staging dir not found: $($script:SyncStaging)"
    }
    if (@($script:SyncMappings).Count -eq 0) { Die "no map rules in $conf" }

    Invoke-SyncDelivery $vm
}

# Invoke-SyncDelivery VM -- the delivery, and the order things happen in.
#
# The map rules already say where each file belongs under the guest's root, so
# the delivery tree they build on the host *is* the layout the guest wants --
# which makes the whole guest side one robocopy of that tree onto C:\. The
# copier compares what it finds against what it already has and takes only the
# difference, which is the point: a sync is run over and over against a build
# tree that changed a little.
#
# Where the cleanup rules and the >post rules sit is the bash module's order and
# is deliberate. They run *after* the share is retired, not inside the transfer:
# a cleanup pattern that overlaps a map destination has always emptied it last,
# and a >post rule that starts a service should see a guest with nothing of
# virutil's still mounted in it.
function Invoke-SyncDelivery {
    param([Parameter(Mandatory)][string]$Vm)

    $clock = [Diagnostics.Stopwatch]::StartNew()

    # The room check is priced from the whole staging tree, which is an upper
    # bound rather than the exact size -- the map rules select a subset of it,
    # and working out which subset means doing the copy. Erring high is the
    # right way to err for a check whose only job is to refuse before the spend.
    $reported = Invoke-XferTransfer -Vm $Vm `
        -StageNeed (Get-XferSize $script:SyncStaging) `
        -StageWith {
            param($Stage)

            Build-SyncDelivery $Stage
            Measure-SyncDelivery $Stage

            if ($script:SyncFiles -eq 0) {
                Die @("no map rule matched anything in $($script:SyncStaging), so"
                      'there is nothing to deliver. The warnings above say which.')
            }
        } `
        -Body {
            param($Session, $Stage)

            # The size goes on the line printed before the transfer because it
            # is the number that says how long to wait. It is the whole tree,
            # though, and the guest will move only part of it -- so the line
            # after the transfer is the one that says what actually crossed.
            [Console]::Out.WriteLine(
                "deliver: $($script:SyncFiles) file(s), " +
                "$(Format-Bytes $script:SyncBytes) -> $Vm C:\")

            # Here, and no sooner: the delivery tree is built and served, so a
            # rule that frees a locked file ("stop the service") is not holding
            # the guest open across the build above, which can take minutes.
            Invoke-SyncRun $Vm 'pre' $script:SyncRunPre

            $text = Invoke-Payload 'sync.ps1' @{ SRC = $Session.Unc }
            $out  = Invoke-GuestPsText $Vm $text -Capture
            if ($script:VirutilExit -ne 0) { Sync-Die $script:VirutilExit }
            return $out
        }

    $clock.Stop()
    Write-SyncReport $Vm $reported $clock.ElapsedMilliseconds

    if (@($script:SyncCleanup).Count -gt 0) { Invoke-SyncCleanup $Vm }

    # Last, so a rule that starts the service or runs an installer sees the
    # delivered files and the emptied directories.
    Invoke-SyncRun $Vm 'post' $script:SyncRunPost

    [Console]::Out.WriteLine("copy complete -> $Vm")
}
