# ui -- launch a process on a Windows guest's *interactive* desktop.
#
#   virutil ui run   VM [-i N] [-s] [--elevated] APP...
#   virutil ui setup [VM] [-f]   cache PsExec on the host, deliver it to the guest
#
# The counterpart of modules/linux/ui, and the same command grammar, because the
# grammar is contract. Everything virutil runs in a Windows guest goes through
# qemu-ga, a session-0 service, so a process it spawns lands invisibly on session
# 0's window station. `run` crosses Session 0 Isolation the way PsExec's service
# does, in place: the guest half is payloads/win/ui.ps1, shared byte for byte
# with the bash driver, and why it works is written down there. It no longer
# needs PsExec; `setup` is what used to stage it and is all that still does.
#
# What differs from the bash host is where setup's two halves stand on this side:
#
#   * **the download** is Invoke-WebRequest and the zip is read with .NET's own
#     ZipFile, where bash needs curl-or-wget and unzip-or-bsdtar. Both are on
#     every Windows machine, so there is no fallback chain to walk.
#   * **the delivery** is Push-Main, as the bash side's is push_main -- which on
#     this host means the machine's own SMB server, Administrator (a prompt, or
#     the task `virutil xfer setup` registers) and a throwaway account for the
#     length of it. That is push's cost, taken once per guest, and it is the
#     transport contract section 7 said ui would ride.
#
# The tool is NOT vendored: the Sysinternals licence forbids redistributing it,
# but freely allows installing copies on your own devices. setup fetches it from
# Microsoft's download host into a host-side cache, once, and pushes that copy.

Set-StrictMode -Version Latest

# The official Sysinternals bundle. HTTPS to Microsoft's own host is the trust
# anchor, as it is in the bash module.
$script:UiUrl = 'https://download.sysinternals.com/files/PSTools.zip'

# Where PsExec lives, host and guest. The guest path is fixed at C:\virutil\ so
# `run` never has to be told where setup put it.
$script:UiCache    = Join-Path $script:VirutilsCacheDir 'pstools'
$script:UiCacheExe = Join-Path $script:UiCache 'PsExec.exe'
$script:UiGuestDir = 'virutil'                      # under C:\, so C:\virutil\
$script:UiGuestExe = 'C:\virutil\PsExec.exe'

# The guest's "PsExec is not there yet", and contract section 5's code for it.
# Clear of PsExec's own codes (it returns the launched PID under -d) and of the
# 0/1 the powershell wrapper uses.
$script:UiRcNoPsExec = 97

# The guest's "no one is logged on in that session", contract section 5. The
# payload raises it; run turns it into the fix.
$script:UiRcNoUser = 96

function Get-UiUsage {
    @(
        'usage: virutil ui run   VM [-i N] [-s] [--elevated] [--] APP...'
        '       virutil ui setup [VM] [-f]'
        ''
        '  run VM APP...   start APP on a guest session''s interactive desktop'
        '                  (winsta0\default) and return without waiting for it.'
        '                  APP is a program plus its arguments; a bare name is'
        '                  looked up on the guest''s PATH. Prints'
        '                  "started PID <pid> in session <n> as <user>".'
        '                  By default APP runs as the user logged on to the'
        '                  console session, with that user''s own token,'
        '                  environment and profile -- what double-clicking it'
        '                  there would give, UAC-filtered if they are an admin.'
        ''
        '    -i, --session N  that session instead of the console one'
        '    -s, --system     as SYSTEM on that session''s desktop (PsExec -s -i)'
        '    --elevated       the user''s full admin token, when UAC split it'
        '                     (PsExec -h). No prompt; no effect with -s.'
        '    --               end of options; everything after it is APP'
        ''
        '                  Options stop at the first word that is not one, so'
        '                  APP''s own flags stay APP''s. Exits 96 when no user is'
        '                  logged on in that session (log one on, or use -s).'
        ''
        '  setup [VM] [-f] fetch PsExec into the host cache (once) and deliver'
        '                  it to the guest at C:\virutil\. run no longer needs'
        '                  it. -f re-downloads even if the cache holds it.'
        ''
        '  -h, --help     this message'
    )
}

# Save-UiCache FORCE -- ensure $UiCacheExe exists on the host. Downloads the
# PSTools bundle and lifts PsExec.exe out of it; a no-op when the cache is
# already warm and FORCE is not set. The network is touched once, not once per
# guest.
function Save-UiCache {
    param([bool]$Force)

    if ((Test-Path -LiteralPath $script:UiCacheExe -PathType Leaf) -and -not $Force) {
        Say "PsExec cached: $($script:UiCacheExe)"
        return
    }

    New-VirutilsDir $script:UiCache | Out-Null
    New-VirutilsDir $script:VirutilsTmpDir | Out-Null
    $tmp = New-VirutilsDir (Join-Path $script:VirutilsTmpDir ('pstools-' + [Guid]::NewGuid().ToString('N')))
    $zip = Join-Path $tmp 'PSTools.zip'

    try {
        Say "downloading PsExec from $($script:UiUrl)"
        # Windows PowerShell 5.1 still offers TLS 1.0 first on some builds, and
        # download.sysinternals.com will not speak it. Added to, not replaced:
        # whatever the session already allows stays allowed.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $pp = $ProgressPreference
        # The progress bar costs more than the download does on 5.1.
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $script:UiUrl -OutFile $zip -UseBasicParsing
        } catch {
            Die @("download failed: $($_.Exception.Message)"
                  "Check this host's connection to download.sysinternals.com.")
        } finally {
            $ProgressPreference = $pp
        }

        # Lift just PsExec.exe out of the bundle, flattening any path -- what
        # `unzip -j ... PsExec.exe` does on the other host. Written to a
        # temporary name and moved into place, so an interrupted extract never
        # leaves a truncated binary that the cache check above would trust.
        # Both assemblies by name: Windows PowerShell 5.1 does not load the
        # first as a dependency of the second.
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $part = "$($script:UiCacheExe).part"
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $entry = $archive.Entries | Where-Object { $_.Name -ieq 'PsExec.exe' } | Select-Object -First 1
            if (-not $entry) { Die 'the bundle did not contain PsExec.exe as expected.' }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $part, $true)
        } finally {
            $archive.Dispose()
        }
        Move-Item -LiteralPath $part -Destination $script:UiCacheExe -Force
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Say "PsExec cached: $($script:UiCacheExe)"
}

# Invoke-UiSetup ARGS -- warm the host cache, then (if a VM was named) deliver
# PsExec into it. Delivery reuses push wholesale: same transport, same "moves
# only what changed", so a second setup of an unchanged binary moves nothing.
function Invoke-UiSetup {
    param([string[]]$Arguments)

    $vm = ''; $force = $false
    foreach ($a in @($Arguments)) {
        switch -Regex ($a) {
            '^(-f|--force)$' { $force = $true; break }
            '^(-h|--help)$'  { Usage (Get-UiUsage) 0; break }
            '^-.+'           { Warn "unrecognised argument: $a"; Usage (Get-UiUsage) 1; break }
            default {
                if ($vm) { Warn "unexpected argument: $a"; Usage (Get-UiUsage) 1 }
                $vm = $a
            }
        }
    }

    Save-UiCache $force

    # No VM: host cache only. Useful for pre-seeding before a guest exists.
    if (-not $vm) { Say 'host cache ready; pass a VM to deliver it into a guest.'; return }

    # A trailing separator makes DST a directory, so PsExec.exe lands at
    # C:\virutil\PsExec.exe and push creates the directory if it is missing.
    Push-Main @($vm, $script:UiCacheExe, "$($script:UiGuestDir)\")
    Say "$vm`: ready -- 'virutil ui run $vm <app>' will launch on the desktop."
}

# Invoke-UiDispatch VM VALUES -- render payloads/win/ui.ps1 and run it. A
# session with no one logged on comes back as $UiRcNoUser, with the guest's own
# line on stderr saying which session that was.
function Invoke-UiDispatch {
    param([string]$Vm, [hashtable]$Values)
    $v = @{ SESSION = ''; AS = 'user'; ELEVATE = ''; ARGV = ''; CMDLINE = '' }
    foreach ($k in $Values.Keys) { $v[$k] = $Values[$k] }
    Invoke-GuestPsText $Vm (Invoke-Payload 'ui.ps1' $v)
    if ($script:VirutilExit -eq $script:UiRcNoUser) {
        DieWith $script:UiRcNoUser @("$Vm`: nothing to launch into -- log a user on to the guest first,"
                                     "or pass -s to run as SYSTEM on that session's desktop.")
    }
}

# Invoke-UiRun VM [OPTIONS] APP... -- the CLI launch. Options sit between VM and
# APP and stop at the first word that is not one, so APP's own flags -- even a
# -s -- are APP's. The APP words travel as an argv joined with U+001F, which no
# argument has reason to hold, and the guest quotes them onto one command line;
# a path with spaces stays one argument.
function Invoke-UiRun {
    param([string[]]$Arguments)

    $argv = @($Arguments)
    if ($argv.Count -ge 1 -and $argv[0] -in @('-h', '--help')) { Usage (Get-UiUsage) 0 }
    if ($argv.Count -lt 2) { Usage (Get-UiUsage) 1 }

    $vm = $argv[0]
    $v = @{}
    $i = 1
    :opts while ($i -lt $argv.Count) {
        switch -Regex ($argv[$i]) {
            '^(-s|--system)$' { $v['AS'] = 'system'; $i++; break }
            '^--elevated$'    { $v['ELEVATE'] = '1'; $i++; break }
            '^(-i|--session)$' {
                if ($i + 1 -ge $argv.Count -or $argv[$i + 1] -notmatch '^\d+$') {
                    Warn "$($argv[$i]) needs a session number"; Usage (Get-UiUsage) 1
                }
                $v['SESSION'] = $argv[$i + 1]; $i += 2; break
            }
            '^--$'            { $i++; break opts }
            '^(-h|--help)$'   { Usage (Get-UiUsage) 0 }
            '^-'              { Warn "unrecognised option: $($argv[$i])"; Usage (Get-UiUsage) 1 }
            default           { break opts }
        }
    }
    if ($i -ge $argv.Count) { Usage (Get-UiUsage) 1 }

    # Through a variable, not piped straight out of Get-RestArgs: it returns its
    # array comma-wrapped, so the pipeline would see one object.
    $apps = Get-RestArgs $argv $i
    $v['ARGV'] = @($apps) -join [char]0x1F
    Invoke-UiDispatch $vm $v
}

# Invoke-UiRunCmdline VM CMDLINE -- launch a whole guest command line on the
# desktop as the logged-on user, used as written. This is what sync's >pre-ui
# and >post-ui rules use: a config line is free text the way a command line is,
# so quoting a space-path is the author's to do, exactly as at a prompt.
function Invoke-UiRunCmdline {
    param([string]$Vm, [string]$Cmdline)
    Invoke-UiDispatch $Vm @{ CMDLINE = $Cmdline }
}

function Ui-Main {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { Usage (Get-UiUsage) 1 }
    $rest = Get-RestArgs $Arguments 1
    switch ($Arguments[0]) {
        'setup'  { Invoke-UiSetup $rest; break }
        'run'    { Invoke-UiRun $rest; break }
        { $_ -in @('-h', '--help') } { Usage (Get-UiUsage) 0; break }
        default  { Usage (Get-UiUsage) 1 }
    }
}
