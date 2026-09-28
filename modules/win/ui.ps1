# ui -- launch a process on a Windows guest's *interactive* desktop.
#
#   virutil ui setup [VM] [-f]   cache PsExec on the host, deliver it to the guest
#   virutil ui run   VM APP...   run APP on the logged-in user's desktop
#
# The counterpart of modules/linux/ui, and the same command grammar, because the
# grammar is contract. Why the module exists at all is written down there and is
# not a property of either host: everything virutil runs in a Windows guest goes
# through qemu-ga, a session-0 service, so a process it spawns lands invisibly on
# session 0's window station. PsExec `-i` is the one in-box way across Session 0
# Isolation, so `run` is a thin wrapper over it and `setup` is what puts it where
# `run` expects it.
#
# What differs from the bash host is where the two halves stand on this side:
#
#   * **the download** is Invoke-WebRequest and the zip is read with .NET's own
#     ZipFile, where bash needs curl-or-wget and unzip-or-bsdtar. Both are on
#     every Windows machine, so there is no fallback chain to walk.
#   * **the delivery** is Push-Main, as the bash side's is push_main -- which on
#     this host means the machine's own SMB server, an Administrator prompt and
#     a throwaway account for the length of it. That is push's cost, taken once
#     per guest, and it is the transport contract section 7 said ui would ride.
#
# The guest half -- the script that resolves the console session and starts
# PsExec -- is the bash module's text statement for statement, since both drivers
# send it into the same guest.
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

function Get-UiUsage {
    @(
        'usage: virutil ui setup [VM] [-f]'
        '       virutil ui run   VM APP...'
        ''
        '  setup [VM] [-f] fetch PsExec into the host cache (once) and deliver'
        '                  it to the guest at C:\virutil\. With no VM it warms'
        '                  the host cache and stops there. -f re-downloads even'
        '                  if the host cache already holds it.'
        ''
        '  run VM APP...   launch APP on the interactive (console) desktop via'
        '                  PsExec -i. APP is a full guest path plus any'
        '                  arguments. The process runs as SYSTEM on that'
        '                  desktop, detached, and virutil returns as soon as'
        '                  PsExec has started it.'
        ''
        "  Run 'virutil ui setup VM' once per guest before 'run'. If run reports"
        '  PsExec missing, that is the fix.'
        ''
        "  setup delivers over the same SMB transport as 'virutil push', so on"
        '  this host it prompts once for Administrator and mints a throwaway'
        '  local account for the length of the delivery.'
        ''
        '  -f, --force    re-download PsExec even if the host cache holds it'
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

# ConvertTo-UiPsQuote S -- S as one single-quoted powershell string. The bash
# module's push_ps_quote: a single quote is doubled, and nothing else inside
# single quotes means anything to powershell.
function ConvertTo-UiPsQuote {
    param([string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

# Get-UiScript PSARGS_LINE -- the guest powershell for one launch, with
# PSARGS_LINE (a line that assigns $psargs, and may reference the $sid computed
# just above it) spliced in. Two callers differ only in that one line: the CLI
# builds an argv array, sync builds a raw command line.
#
# This is modules/linux/ui's ui_build_script line for line, and the reasons are
# written down there: `-i` is given the console session explicitly because a
# bare `-i` from a session-0 service targets session 0; PsExec's stderr
# narrative goes through Start-Process with both streams redirected to files so
# PowerShell's error records never touch it; and a PsExec that is not there makes
# Start-Process throw, which becomes $UiRcNoPsExec.
function Get-UiScript {
    param([string]$PsArgsLine)
    @(
        "`$exe = '$($script:UiGuestExe)'"
        'Add-Type -Name Wts -Namespace Vu -MemberDefinition ''[DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();'''
        '$sid = [Vu.Wts]::WTSGetActiveConsoleSessionId()'
        'if ($sid -eq 0xFFFFFFFF) { [Console]::Error.WriteLine("no interactive session is attached to the console (no one is logged in)."); exit 1 }'
        $PsArgsLine
        '$o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()'
        'try {'
        '  Start-Process -FilePath $exe -ArgumentList $psargs -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e -ErrorAction Stop | Out-Null'
        '} catch {'
        '  Remove-Item -LiteralPath $o,$e -Force -ErrorAction SilentlyContinue'
        "  exit $($script:UiRcNoPsExec)"
        '}'
        '$txt = (Get-Content -Raw -LiteralPath $e -ErrorAction SilentlyContinue) + (Get-Content -Raw -LiteralPath $o -ErrorAction SilentlyContinue)'
        'Remove-Item -LiteralPath $o,$e -Force -ErrorAction SilentlyContinue'
        'if ($txt) { [Console]::Out.Write($txt.Trim()) }'
        'exit 0'
    ) -join "`n"
}

# Invoke-UiDispatch VM PSARGS_LINE -- run one launch and map "PsExec absent" to
# a message that names the fix, with contract section 5's code.
function Invoke-UiDispatch {
    param([string]$Vm, [string]$PsArgsLine)
    Invoke-GuestPsText $Vm (Get-UiScript $PsArgsLine)
    if ($script:VirutilExit -eq $script:UiRcNoPsExec) {
        DieWith $script:UiRcNoPsExec @("PsExec is not installed in $Vm at $($script:UiGuestExe)."
                                       "Run 'virutil ui setup $Vm' first.")
    }
}

# Invoke-UiRun VM APP... -- the CLI launch. Each APP token becomes one
# single-quoted powershell string in an argv array, so a path with spaces stays
# one argument and Start-Process quotes each element back onto PsExec's command
# line.
function Invoke-UiRun {
    param([string[]]$Arguments)

    $argv = @($Arguments)
    if ($argv.Count -ge 1 -and $argv[0] -in @('-h', '--help')) { Usage (Get-UiUsage) 0 }
    if ($argv.Count -lt 2) { Usage (Get-UiUsage) 1 }

    $vm = $argv[0]
    # Through a variable, not piped straight out of Get-RestArgs: it returns its
    # array comma-wrapped, so the pipeline would see one object -- the whole
    # array -- and quote every token as a single space-joined argument.
    $apps = Get-RestArgs $argv 1
    $joined = ($apps | ForEach-Object { ConvertTo-UiPsQuote $_ }) -join ','
    Invoke-UiDispatch $vm "`$psargs = @('-accepteula','-i',`"`$sid`",'-d',$joined)"
}

# Invoke-UiRunCmdline VM CMDLINE -- launch a whole guest command line on the
# desktop, passed verbatim after PsExec's options. This is what sync's >pre-ui
# and >post-ui rules use: a config line is free text the way a command line is,
# so quoting a space-path is the author's to do, exactly as at a prompt. $psargs
# is built as a single string, which Start-Process hands to PsExec as the raw
# command line rather than re-quoting element by element.
function Invoke-UiRunCmdline {
    param([string]$Vm, [string]$Cmdline)
    Invoke-UiDispatch $Vm "`$psargs = '-accepteula -i ' + `$sid + ' -d ' + $(ConvertTo-UiPsQuote $Cmdline)"
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
