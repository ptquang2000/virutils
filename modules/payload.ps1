# payload -- read a guest-side script out of payloads/ and fill its holes.
#
# The counterpart of modules/payload, and it must stay one: the whole point of
# payloads/ is that both drivers put the same text on the wire, so a difference
# between these two renderers is a difference in what a guest runs. The grammar
# is written down once in payloads/README.md and in docs/contract.md section 6.
#
#   Invoke-Payload FILE @{ NAME = VALUE }
#
# NAME/VALUE fills an @NAME@ hole, quoted as a string literal in the payload's
# own language -- which the file extension decides, and which is the one thing a
# caller never does for itself. The @@NAME@@ holes are not arguments: they are
# the exit codes in section 5 of the contract, plus @@PROBE@@, and this file
# owns the table.

# payloads/ sits beside modules/, and is reached through this file's own path
# rather than the caller's working directory.
$script:PayloadsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'payloads'

# --- quoting ----------------------------------------------------------------

# A value inside a single-quoted PowerShell string. Backslashes are literal
# there, which is the whole reason for preferring it over the double-quoted
# form; only the quote itself has to be escaped, by doubling. The bash driver's
# push_ps_quote, character for character.
function ConvertTo-PsLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# A value as a single-quoted /bin/sh word. One rule: inside single quotes every
# character is literal except the quote itself, which is closed, escaped and
# reopened. The bash driver's sh_quote.
function ConvertTo-ShLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

# --- the raw table ----------------------------------------------------------
#
# Every one of these is a number a caller matches on, so it is written once and
# not spelled again in any payload. The values are section 5 of the contract and
# are the same in both drivers by definition.
$script:PayloadCodes = @{
    RC_NO_RSYNC     = 90
    RC_PUSH_MKDIR   = 92
    RC_PUSH_ROBO    = 93
    RC_PULL_NOMATCH = 94
    RC_PULL_ROBO    = 95
}

# Get-PayloadText PATH -- the file with its commentary removed. A PowerShell
# payload is base64'd as UTF-16LE onto a command line Windows caps at 32767
# characters and an sh payload travels as one argv entry Linux caps at 128KB, so
# the budget is for the transfer rather than for the prose. `#` opens a comment
# in both languages, and a line whose first non-space character is `#` goes
# whole.
function Get-PayloadText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Die "internal: no payload at $Path" }
    $lines = Get-Content -LiteralPath $Path
    return (($lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' }) -join "`n")
}

# Invoke-Payload FILE VALUES -- the rendered script, with no trailing newline.
function Invoke-Payload {
    param(
        [Parameter(Mandatory)][string]$File,
        [hashtable]$Values = @{}
    )

    $path = Join-Path $script:PayloadsDir $File
    # `break` in each arm, not decoration: a PowerShell switch runs *every*
    # branch whose pattern matches, so without them a future third pattern that
    # overlaps would quietly pick the last quoting rule rather than the right
    # one -- and quoting is the one thing a payload never does for itself.
    switch -Wildcard ($File) {
        '*.ps1' { $quote = 'ConvertTo-PsLiteral'; break }
        '*.sh'  { $quote = 'ConvertTo-ShLiteral'; break }
        default { Die "internal: payload $File is in no language this can quote for" }
    }

    $text = Get-PayloadText $path

    # @@PROBE@@ before the code table: probe.sh carries an @@RC_NO_RSYNC@@ of
    # its own, and it has to be there to be filled.
    if ($text.Contains('@@PROBE@@')) {
        $text = $text.Replace('@@PROBE@@', (Get-PayloadText (Join-Path $script:PayloadsDir 'probe.sh')))
    }

    foreach ($m in [regex]::Matches($text, '@@([A-Z][A-Z0-9_]*)@@')) {
        $name = $m.Groups[1].Value
        if (-not $script:PayloadCodes.ContainsKey($name)) {
            Die "internal: payload $File wants @@$name@@, which is not a code this knows"
        }
        $text = $text.Replace("@@$name@@", [string]$script:PayloadCodes[$name])
    }

    # The holes are settled against the arguments *before* anything is
    # substituted, rather than by looking for leftovers afterwards: a value that
    # happens to contain @SRC@ is a path, not an unfilled hole, and checking
    # after the fact cannot tell those apart.
    $holes = @([regex]::Matches($text, '@([A-Z][A-Z0-9_]*)@') |
               ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    foreach ($h in $holes) {
        if (-not $Values.ContainsKey($h)) {
            Die "internal: payload $File was rendered with @$h@ unfilled"
        }
    }
    foreach ($k in $Values.Keys) {
        if ($k -notin $holes) { Die "internal: payload $File has no @$k@ to fill" }
        $v = [string]$Values[$k]
        # Refused rather than substituted, and the bash renderer refuses the
        # same thing. It has to: it fills one hole at a time, so such a value
        # would be rescanned there as the next hole and not here. Both drivers
        # refusing is what keeps them provably identical for every input either
        # of them accepts.
        $m = [regex]::Match($v, '@[A-Z][A-Z0-9_]*@')
        if ($m.Success) {
            Die @(
                "$k is '$v', which contains $($m.Value) -- the spelling of a"
                'payload placeholder. virutil will not send that into a guest'
                'as itself. Rename it.'
            )
        }
    }

    # One pass, so a value is never rescanned: substituting hole by hole would
    # let the first value's text be read as the second hole.
    return [regex]::Replace($text, '@([A-Z][A-Z0-9_]*)@', {
        param($m)
        & $quote ([string]$Values[$m.Groups[1].Value])
    })
}
