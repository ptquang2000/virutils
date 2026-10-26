# ui -- launch a process on a Windows guest's *interactive* desktop.
#
#   virutil ui run VM [-i N] [-s] [--elevated] [--] APP...
#
# The counterpart of modules/linux/ui, and the same command grammar, because the
# grammar is contract. Everything virutil runs in a Windows guest goes through
# qemu-ga, a session-0 service, so a process it spawns lands invisibly on session
# 0's window station. `run` crosses Session 0 Isolation from the SYSTEM shell the
# agent already gives it: the guest half is payloads/win/ui.ps1, shared byte for
# byte with the bash driver, which says how; docs/ui-psexec.md says why that
# recipe. Nothing is staged in the guest first.

Set-StrictMode -Version Latest

# The guest's "no one is logged on in that session", contract section 5. The
# payload raises it; run turns it into the fix.
$script:UiRcNoUser = 96
function Get-UiUsage {
    @(
        'usage: virutil ui run VM [-i N] [-s] [--elevated] [--] APP...'
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
        '    -s, --system     as SYSTEM on that session''s desktop'
        '    --elevated       the user''s full admin token, when UAC split it'
        '                     -- no prompt. No effect with -s.'
        '    --               end of options; everything after it is APP'
        ''
        '                  Options stop at the first word that is not one, so'
        '                  APP''s own flags stay APP''s. Exits 96 when no user is'
        '                  logged on in that session (log one on, or use -s).'
        ''
        '  -h, --help     this message'
    )
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
        # Retired: run stages nothing. Kept answering 0 so a script that still
        # calls it before run keeps working.
        'setup'  { Say 'ui needs no setup: ''virutil ui run'' stages nothing in the guest.'; break }
        'run'    { Invoke-UiRun $rest; break }
        { $_ -in @('-h', '--help') } { Usage (Get-UiUsage) 0; break }
        default  { Usage (Get-UiUsage) 1 }
    }
}
