# exec -- run commands inside a guest via the QEMU guest agent.
#
#   virutil exec ping VM                 check that the guest agent is responding
#   virutil exec cmd  VM [-d] CMD...     run CMD via cmd.exe /c        (Windows)
#   virutil exec ps   VM [-d] SCRIPT...  run SCRIPT via powershell     (Windows)
#   virutil exec sh   VM [-d] SCRIPT...  run SCRIPT via /bin/sh -c     (Linux)
#
# The counterpart of modules/exec, and the same command grammar, because the
# grammar is contract. Which of the three a guest answers to is the guest's
# business, not the agent's: guest-exec carries a path and an argv either way.
#
# Commands run as SYSTEM on Windows and as root on Linux -- qemu-ga is a service
# in both cases -- and the guest exit code becomes ours. Flags sit between the
# VM name and the command; parsing stops at the first non-flag, and `--` forces
# the end of flags so a command may start with `-`.
#
# stdin is overloaded, disambiguated by whether `-` sits in the command slot:
#   virutil exec ps VM -           the script is read from stdin
#   echo x | virutil exec ps VM C  stdin becomes the guest process's stdin,
#                                  buffered whole and EOF'd immediately, so it
#                                  cannot answer an interactive prompt

# Windows caps a command line at 32767 chars; cmd.exe caps itself far lower.
# Enforced host-side, in both drivers: overflowing them fails in the guest as an
# unrelated-looking spawn error. These numbers are contract.
$script:CmdlineMax = 32767
$script:CmdExeMax  = 8191

# Linux has no command-line limit to speak of, but it does cap a single argv
# entry at MAX_ARG_STRLEN -- 32 pages, which is 128KB on every architecture
# virutil runs on. An sh script is passed as one such entry, so this is the
# ceiling that matters, and over it execve fails in the guest as E2BIG, which
# surfaces as an unrelated-looking spawn error rather than as "your script is
# too long".
$script:ShArgMax = 131072

function Get-ExecUsage {
    @(
        'usage: virutil exec {ping|cmd|ps|sh} VM [FLAGS] [ARGS]'
        ''
        '  cmd, ps        a Windows guest; sh a Linux one.'
        ''
        '  -d, --detach   fire and forget: print the guest pid and exit 0.'
        '                 No output and no exit code, but the command survives'
        '                 the channel dropping -- the only way to run a reboot'
        '                 or a long installer.'
        '  --             end of flags'
        '  -              read the command from stdin'
    )
}

# --- running one thing ------------------------------------------------------

# Invoke-GuestExec VM PATH ARGV -- wait for completion, print the guest's stdout
# and stderr, and leave its exit code in $script:VirutilExit. Honours -Detach
# and -InputB64.
function Invoke-GuestExec {
    param(
        [Parameter(Mandatory)][string]$Vm,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Argv = @(),
        [switch]$Detach,
        [string]$InputB64 = ''
    )

    # Not $args: that is an automatic variable and assigning to it is a quiet
    # way to lose the caller's own arguments.
    $execArgs = @{ path = $Path; arg = $Argv; 'capture-output' = (-not $Detach) }
    if ($InputB64) { $execArgs['input-data'] = $InputB64 }

    $guestPid = (Invoke-GuestAgent $Vm 'guest-exec' $execArgs).pid

    if ($Detach) {
        [Console]::Out.WriteLine($guestPid)
        $script:VirutilExit = 0
        return
    }

    # Backoff: a one-liner returns at once, an installer runs for minutes.
    $ms = 50
    while ($true) {
        $st = Invoke-GuestAgent $Vm 'guest-exec-status' @{ pid = $guestPid }
        if ($st.PSObject.Properties.Name -contains 'exited' -and $st.exited) { break }
        Start-Sleep -Milliseconds $ms
        $ms = [Math]::Min(1000, [int]($ms * 3 / 2))
    }

    # \r stripped so Windows output pipes cleanly into unix tools, and trailing
    # whitespace trimmed off each line, exactly as the bash driver does.
    $out = Get-AgentStream $st 'out-data'
    if ($out) { [Console]::Out.Write((Format-GuestStream $out)) }

    $err = Get-AgentStream $st 'err-data'
    if ($err) {
        if ($err.StartsWith('#< CLIXML')) { $err = ConvertFrom-Clixml $err }
        [Console]::Error.Write((Format-GuestStream $err))
    }

    # Read through the property list, not off the object. guest-exec-status
    # returns `signal` instead of `exitcode` when the guest process was killed
    # by one, and under StrictMode reaching for an absent member throws -- so
    # the shape virutil most wants to report faithfully would instead crash the
    # run with a PowerShell error about a missing property. The bash driver
    # spells the same defence `.exitcode // 0`.
    $names = $st.PSObject.Properties.Name
    if ($names -contains 'exitcode' -and $null -ne $st.exitcode) {
        $script:VirutilExit = [int]$st.exitcode
    } elseif ($names -contains 'signal' -and $null -ne $st.signal) {
        # What a shell reports for a signalled child, so a caller branching on
        # the code sees the same number it would from `bash -c`.
        Warn "$Vm`: the guest process was killed by signal $($st.signal)"
        $script:VirutilExit = 128 + [int]$st.signal
    } else {
        $script:VirutilExit = 0
    }
}

function Get-AgentStream {
    param($Status, [string]$Name)
    if ($Status.PSObject.Properties.Name -notcontains $Name) { return '' }
    $b64 = $Status.$Name
    if (-not $b64) { return '' }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function Format-GuestStream {
    param([string]$Text)
    $lines = $Text.Replace("`r", '').Split("`n") | ForEach-Object { $_.TrimEnd() }
    return (($lines -join "`n").TrimEnd() + "`n")
}

# powershell serialises its error stream as CLIXML whenever stderr is
# redirected; only errors outside the ps wrapper's reach get here. The bash
# driver shells out to python3 for this and passes the raw text through when it
# is missing; PowerShell has an XML parser to hand, so this one always decodes.
function ConvertFrom-Clixml {
    param([string]$Text)
    try {
        $body = $Text.Split("`n", 2)[1]
        $xml = [xml]$body
    } catch {
        return $Text
    }
    $s = ($xml.SelectNodes('//*') | Where-Object { $_.LocalName -eq 'S' } |
          ForEach-Object { $_.InnerText }) -join ''
    return [regex]::Replace($s, '_x([0-9A-Fa-f]{4})_',
        { param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}

# --- the two shells ---------------------------------------------------------

# Invoke-GuestPsText VM SCRIPT -- run SCRIPT in the guest's powershell.
# Shared with the transports, exactly as the bash exec_ps_text is.
function Invoke-GuestPsText {
    param([Parameter(Mandatory)][string]$Vm, [Parameter(Mandatory)][string]$Script,
          [switch]$Detach, [string]$InputB64 = '')

    # The catch writes to the console handle, not powershell's error stream,
    # which would be serialised as CLIXML; the explicit exit 1 restores the code
    # an uncaught terminating error would have returned.
    $wrapped = @(
        '$ProgressPreference="SilentlyContinue";'
        'try { $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(4096, 2000) } catch {}'
        'try {'
        $Script
        '} catch { [Console]::Error.WriteLine(($_ | Out-String)); exit 1 }'
    ) -join "`n"

    # UTF-16LE base64 sidesteps every quoting layer between here and the guest.
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapped))

    # + the powershell.exe flags that precede it on the command line
    if (($enc.Length + 128) -gt $script:CmdlineMax) {
        Die @(
            "virutil: script encodes to $($enc.Length) chars, over Windows's"
            "$($script:CmdlineMax) command-line limit (~12000 chars of source);"
            'shorten it, or stage a .ps1 in the guest and run that'
        )
    }

    Invoke-GuestExec $Vm 'powershell.exe' `
        @('-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', $enc) `
        -Detach:$Detach -InputB64 $InputB64
}

# Invoke-GuestShText VM SCRIPT -- run SCRIPT in the guest's /bin/sh.
#
# No base64 layer, and this is the one place the Linux side is *simpler* rather
# than merely different. The Windows encoding exists because qemu-ga there has
# to flatten argv into a single CreateProcess command line, which re-quotes as
# it goes -- that is what mangles an embedded quote through cmd.exe. On Linux
# qemu-ga execve's the argv array it was handed, so the script arrives as one
# argument byte for byte, whatever is in it.
#
# set -e to match $ErrorActionPreference = "Stop" on the other side: a run rule
# exists to make the copy land correctly, so the first failing statement in one
# has to end it rather than let the rest carry on against a guest that is not in
# the state the rule was meant to put it in.
function Invoke-GuestShText {
    param([Parameter(Mandatory)][string]$Vm, [Parameter(Mandatory)][string]$Script,
          [switch]$Detach, [string]$InputB64 = '')

    $text = "set -e`n$Script"

    # + "-c" and the argv overhead around it
    if (($text.Length + 64) -gt $script:ShArgMax) {
        Die @(
            "virutil: script is $($text.Length) chars, over Linux's"
            "$($script:ShArgMax) single-argument limit; shorten it, or stage a"
            'script in the guest and run that'
        )
    }

    Invoke-GuestExec $Vm '/bin/sh' @('-c', $text) -Detach:$Detach -InputB64 $InputB64
}

# --- the command line -------------------------------------------------------

function Exec-Main {
    param([string[]]$Arguments)

    # -h/--help exits 0 and a usage error exits 1, on every module in both
    # drivers. That is contract, so it is settled before anything else is read.
    if ($Arguments -and $Arguments[0] -in @('-h', '--help')) { Usage (Get-ExecUsage) 0 }
    if (-not $Arguments -or $Arguments.Count -lt 2) { Usage (Get-ExecUsage) 1 }
    $cmd = $Arguments[0]
    $vm  = $Arguments[1]
    $rest = Get-RestArgs $Arguments 2

    if ($cmd -eq 'ping') {
        Invoke-GuestAgent $vm 'guest-ping' | Out-Null
        [Console]::Out.WriteLine("$vm`: agent up")
        $script:VirutilExit = 0
        return
    }
    if ($cmd -notin @('cmd', 'ps', 'sh')) { Usage (Get-ExecUsage) 1 }

    # Flags, then the command. Parsing stops at the first non-flag, and `--`
    # forces the end of flags so a command may start with `-`. Written as a
    # plain loop rather than a switch: `break` inside a PowerShell switch leaves
    # the switch, not the loop around it, which is a quiet way to write a flag
    # parser that stops after the first argument.
    $detach = $false
    $i = 0
    while ($i -lt $rest.Count) {
        $a = $rest[$i]
        if ($a -eq '-d' -or $a -eq '--detach') { $detach = $true; $i++; continue }
        if ($a -eq '--') { $i++; break }
        if ($a -eq '-')  { break }
        if ($a.StartsWith('-')) {
            Die "virutil exec: unknown flag: $a (use -- to end flags)"
        }
        break
    }
    $words = Get-RestArgs $rest $i

    if ($words.Count -eq 0) {
        $what = if ($cmd -eq 'cmd') { 'CMD...' } else { 'SCRIPT...' }
        Usage @("usage: virutil exec $cmd VM [-d] $what") 1
    }

    # stdin is overloaded: `-` in the command slot means the script comes from
    # it, anything else means it is the guest process's own stdin.
    $inputB64 = ''
    if ($words.Count -eq 1 -and $words[0] -eq '-') {
        $text = [Console]::In.ReadToEnd()
    } else {
        $text = $words -join ' '
        if ([Console]::IsInputRedirected) {
            $inputB64 = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes([Console]::In.ReadToEnd()))
        }
    }

    switch ($cmd) {
        'cmd' {
            # qemu-ga backslash-escapes embedded quotes and cmd.exe has never
            # understood \" as an escape, so the command arrives mangled with a
            # zero exit code. ps encodes to base64 and is immune.
            if ($text.Contains('"')) {
                Die 'virutil exec: cmd cannot carry embedded quotes through cmd.exe; use ps'
            }
            # + the "cmd.exe /c " prefix and the quotes qemu-ga wraps the arg in
            if (($text.Length + 16) -gt $script:CmdExeMax) {
                Die @(
                    "virutil exec: command is $($text.Length) chars, over cmd.exe's"
                    "$($script:CmdExeMax) limit; shorten it, or stage a .cmd file"
                    'in the guest and run that'
                )
            }
            Invoke-GuestExec $vm 'cmd.exe' @('/c', $text) -Detach:$detach -InputB64 $inputB64
        }
        'ps' { Invoke-GuestPsText $vm $text -Detach:$detach -InputB64 $inputB64 }
        'sh' { Invoke-GuestShText $vm $text -Detach:$detach -InputB64 $inputB64 }
    }
}
