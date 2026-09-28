<#
.SYNOPSIS
  sync on a Windows host, everything except the elevated half.

.DESCRIPTION
  tests/win/xfer.ps1's shape, for the module that sits on top of that
  transport. The same two seams are substituted -- the guest agent boundary and
  the share publisher -- and everything between them runs for real: the config
  parse, the fetch, the glob expansion, the delivery tree the map rules build,
  the payload that would have gone into the guest, and the teardown.

  What it is really for is the half of sync that is *not* the transport, and
  that the bash suite has no counterpart for because the bash module is a
  different implementation of it:

    * the config file is contract, so a config written for the bash driver has
      to parse to the same thing here -- including the directives that are
      refused by name;
    * the one thing this host cannot do -- @guest=linux -- is refused
      **before anything is fetched**, which is a property of ordering and not
      of the message;
    * the >pre-ui / >post-ui run rules, once refused here too, go to PsExec
      through modules/win/ui.ps1 exactly as the bash module sends them;
    * the map rules build a tree whose layout is the guest's own root, which is
      the whole reason the guest side is one robocopy.

  A real staging tree and a real delivery tree are built on this host, because
  those are the halves a fake would make vacuous.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'modules\win'
$env:VIRUTILS_DIR = Join-Path ([IO.Path]::GetTempPath()) ("virutil-test-" + [Guid]::NewGuid().ToString('N'))

. (Join-Path $moduleDir 'parser.ps1')
. (Join-Path $moduleDir 'paths.ps1')
. (Join-Path $moduleDir 'payload.ps1')
. (Join-Path $moduleDir 'guest.ps1')
. (Join-Path $moduleDir 'exec.ps1')
. (Join-Path $moduleDir 'xfer.ps1')
. (Join-Path $moduleDir 'sync.ps1')
. (Join-Path $moduleDir 'ui.ps1')

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, $Want, $Got)
    if ("$Want" -eq "$Got") { [Console]::Out.WriteLine("ok       $Name"); $script:Pass++ }
    else {
        [Console]::Out.WriteLine("FAIL     $Name")
        [Console]::Out.WriteLine("         wanted [$Want], got [$Got]")
        $script:Fail++
    }
}
function CheckTrue { param([string]$Name, $Got) Check $Name $true ([bool]$Got) }

function Dies {
    param([scriptblock]$Body)
    try { & $Body | Out-Null; return '' }
    catch { return $_.Exception.Message }
}

# --- the seams ---------------------------------------------------------------

$script:Sent     = @()
$script:GuestRc  = 0
$script:UiRc     = 0
$script:GuestOut = '1 1234'
function Invoke-GuestAgent {
    param([string]$Vm, [string]$Command, $Arguments = $null, [int]$TimeoutMs = 10000)
    switch ($Command) {
        'guest-exec' {
            $argv = @($Arguments['arg'])
            $script:Sent += [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($argv[$argv.Count - 1]))
            return ([pscustomobject]@{ pid = 4242 })
        }
        'guest-exec-status' {
            # $GuestRc is the *delivery's* exit code and nothing else's. sync
            # sends four kinds of script into a guest -- the mount pair, the run
            # rules, the delivery and the cleanup -- and a knob that failed all
            # of them could never reach the delivery: the >pre rule would have
            # died first, and the test would have asserted the wrong refusal.
            $last  = $script:Sent[$script:Sent.Count - 1]
            $isDelivery = $last -match '\$dst = "C:\\"'
            # $UiRc is the same idea for a ui run rule's launch script, so the
            # missing-PsExec answer can be given to that script and no other.
            $isUi = $last -match 'PsExec\.exe'
            $rc  = if ($isDelivery) { $script:GuestRc } elseif ($isUi) { $script:UiRc } else { 0 }
            $out = if ($isDelivery) { $script:GuestOut } else { 'ok' }
            return ([pscustomobject]@{
                exited = $true
                exitcode = $rc
                'out-data' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($out))
            })
        }
        default { throw "the test agent was asked for $Command" }
    }
}

$script:Published    = 0
$script:Unpublished  = 0
$script:PublishedDir = ''
$script:LastScratch  = ''
function Publish-XferShare {
    param([string]$Token, [string]$Path, [switch]$Write)
    $script:Published++
    $script:PublishedDir = $Path
    $script:LastScratch  = Get-XferScratch $Token
    return @{
        Token = $Token; Scratch = (Get-XferScratch $Token)
        Unc = "\\10.0.2.2\$Token"; User = "vxp-$Token"; Password = 'notarealpassword'
        HelperPid = 0
    }
}
function Unpublish-XferShare { param($Session) $script:Unpublished++ }

# The preconditions, and the domain state the run rules read minutes later.
# Both are asserted for ordering rather than for content.
$script:ReadyFails = $false
$script:Running    = $true
function Assert-XferReady {
    param([string]$Vm)
    if ($script:ReadyFails) { Die "$Vm is not running" }
}
function Test-DomainRunning { param([string]$Vm) return $script:Running }

# Both streams into one buffer, which is where this diverges from
# tests/win/xfer.ps1's Capture. Half of what sync tells you is a warning -- a
# glob that matched nothing, a fetch source that is absent, run rules skipped
# because the guest went away -- and those go to stderr, as everything
# diagnostic in both drivers does. Capturing stdout alone would make every
# assertion about them silently unfalsifiable.
function Capture {
    param([scriptblock]$Body)
    $script:Sent = @()
    $outOrig = [Console]::Out
    $errOrig = [Console]::Error
    $buf = New-Object IO.StringWriter
    [Console]::SetOut($buf)
    [Console]::SetError($buf)
    try { & $Body | Out-Null }
    finally { [Console]::SetOut($outOrig); [Console]::SetError($errOrig) }
    return $buf.ToString().Replace("`r`n", "`n")
}

# The delivery payload is not the last thing a transfer sends -- the unmount
# goes after it -- so it is found by what it is rather than by position.
function DeliveryPayload {
    for ($i = $script:Sent.Count - 1; $i -ge 0; $i--) {
        if ($script:Sent[$i] -match '\$dst = "C:\\"') { return $script:Sent[$i] }
    }
    return ''
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("virutil-sync-" + [Guid]::NewGuid().ToString('N'))
try {
    $repo = Join-Path $scratch 'repo'
    $conf = Join-Path $scratch 'conf'
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'bin\Release') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'bin\Release\res') | Out-Null
    New-Item -ItemType Directory -Force -Path $conf | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'bin\Release\app.exe')     -Value 'exe' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $repo 'bin\Release\app.pdb')     -Value 'pdb' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $repo 'bin\Release\res\one.txt') -Value 'one' -Encoding ASCII

    # WriteConf NAME LINES -- a config file, and the path to it.
    function WriteConf {
        param([string]$Name, [string[]]$Lines)
        $p = Join-Path $conf $Name
        Set-Content -LiteralPath $p -Value $Lines -Encoding ASCII
        return $p
    }

    $base = @(
        "@repo=$repo"
        '@staging=proj'
        '@dest=Program Files/Example'
        '# a comment, and a blank line follow'
        ''
        '!*.pdb'
        '<bin/Release|.'
        '*|'
        '-ProgramData/Example/logs'
        '>pre  Stop-Service -Name example'
        '>post Start-Service -Name example'
    )

    # --- the parse, which is contract ---------------------------------------
    #
    # The config file is the one interface sync has, and it is shared with the
    # bash driver -- so what a directive parses to is worth asserting directly,
    # before any of it is acted on.

    Read-SyncConfig (WriteConf 'base.conf' $base)
    Check 'the repo is read'             $repo   $script:SyncRepo
    Check 'the staging name is read'     'proj'  $script:SyncStaging
    Check 'dest is normalised'  'Program Files/Example' $script:SyncDest
    Check 'the guest defaults to windows' 'windows' $script:SyncGuestOs
    Check 'one fetch rule'    1 (@($script:SyncFetch).Count)
    Check 'one map rule'      1 (@($script:SyncMappings).Count)
    Check 'one exclude'       1 (@($script:SyncExcludes).Count)
    Check 'one cleanup rule'  1 (@($script:SyncCleanup).Count)
    Check 'one pre rule'      1 (@($script:SyncRunPre).Count)
    Check 'one post rule'     1 (@($script:SyncRunPost).Count)
    Check 'a run rule keeps its whole command' `
        'Stop-Service -Name example' (@($script:SyncRunPre)[0].Cmd)

    # A dest written the Windows way has to mean the same place, since the
    # driver on the other host will be handed the same file.
    Read-SyncConfig (WriteConf 'winpath.conf' (@("@repo=$repo", '@staging=p',
        '@dest=C:\Program Files\Example', '<a|.', '*|')))
    Check 'a drive-prefixed @dest normalises' 'Program Files/Example' $script:SyncDest

    # The directives that were removed are refused by name and with what
    # replaced them, exactly as the bash module refuses them.
    CheckTrue '@domain is refused by name' `
        ((Dies { Read-SyncConfig (WriteConf 'd.conf' @('@domain=win11')) }) -match 'no longer a setting')
    CheckTrue '@transport is refused by name' `
        ((Dies { Read-SyncConfig (WriteConf 't.conf' @('@transport=disk')) }) -match 'disk-image')
    CheckTrue 'an unknown setting names its line' `
        ((Dies { Read-SyncConfig (WriteConf 'u.conf' @('@repo=x', '@nope=1')) }) -match 'u\.conf:2: unknown setting')
    CheckTrue 'a run rule with no phase lists the phases' `
        ((Dies { Read-SyncConfig (WriteConf 'r.conf' @('>Stop-Service -Name x')) }) -match "needs 'pre', 'post'")
    CheckTrue 'a map rule without | is refused' `
        ((Dies { Read-SyncConfig (WriteConf 'm.conf' @('*.exe')) }) -match "missing '\|' separator")
    CheckTrue 'a mistyped directive is not read as a glob' `
        ((Dies { Read-SyncConfig (WriteConf 'x.conf' @('%oops|bin')) }) -match 'unrecognised directive')
    CheckTrue "a map destination may not contain '..'" `
        ((Dies { Read-SyncConfig (WriteConf 'dd.conf' @('@dest=../../Windows')) }) -match "may not contain '\.\.'")

    # --- which config is read, decided on spelling alone --------------------
    Check 'no -c means sync.conf under the config dir' `
        (Join-Path $script:VirutilsConfDir 'sync.conf') (Resolve-SyncConfig '')
    Check 'a bare name gets .conf appended' `
        (Join-Path $script:VirutilsConfDir 'win11.conf') (Resolve-SyncConfig 'win11')
    Check 'a name already ending in .conf is not doubled' `
        (Join-Path $script:VirutilsConfDir 'win11.conf') (Resolve-SyncConfig 'win11.conf')
    # The three spellings of "this is a path" on this host. The third is the one
    # the bash rule alone would get wrong, and it is the common one here.
    Check 'a slash makes it a path'     './x.conf'      (Resolve-SyncConfig './x.conf')
    Check 'a backslash makes it a path' '.\x.conf'      (Resolve-SyncConfig '.\x.conf')
    Check 'a drive letter makes it a path' 'C:\x.conf'  (Resolve-SyncConfig 'C:\x.conf')

    # --- refused before anything is fetched ---------------------------------
    #
    # Ordering, not wording: both of these are properties of this *host*, so
    # there is no reason to spend a fetch, an elevation prompt and a delivery
    # before saying so. $Published staying 0 is the assertion that matters.

    $linuxConf = WriteConf 'linux.conf' ($base + @('@guest=linux'))
    $script:Published = 0
    $why = Dies { Capture { Sync-Main @('win11', '-c', $linuxConf) } }
    CheckTrue '@guest=linux is refused by name' ($why -match 'Windows guest')
    CheckTrue '@guest=linux points at the bash driver' ($why -match 'section 7')
    Check     '@guest=linux published no share' 0 $script:Published
    CheckTrue '@guest=linux fetched nothing' (-not (Test-Path -LiteralPath $script:VirutilsStagingRoot))

    # --- a ui run rule -------------------------------------------------------
    #
    # Refused here once, because this driver had no `ui`. Now it runs, and what
    # is asserted is what reaches the guest: the rule's command line, verbatim
    # and single-quoted, after PsExec's own -i <console session> -d.

    $uiConf = WriteConf 'ui.conf' ($base + @('>post-ui "C:\Program Files\Example\app.exe" --restored'))
    $script:Published = 0
    $out = Capture { Sync-Main @('win11', '-c', $uiConf) }
    CheckTrue 'a ui run rule runs, and says so' ($out -match [regex]::Escape('run (post/ui): "C:\Program Files\Example\app.exe" --restored'))
    $launch = @($script:Sent | Where-Object { $_ -match 'PsExec\.exe' })
    Check     'the launch script was sent once' 1 $launch.Count
    CheckTrue 'it launches on the console session' `
        ($launch[0] -match [regex]::Escape("'-accepteula -i ' + `$sid + ' -d ' + "))
    CheckTrue 'it carries the rule as a raw command line' `
        ($launch[0] -match [regex]::Escape("'`"C:\Program Files\Example\app.exe`" --restored'"))
    CheckTrue 'and the run still completes' ($out -match 'copy complete -> win11')

    # PsExec not staged yet: the fix is named, with contract section 5's code.
    $script:UiRc = 97
    $code = 0
    try { Capture { Sync-Main @('win11', '-c', $uiConf) } | Out-Null }
    catch { $why = $_.Exception.Message; $code = [int]$_.Exception.Data['VirutilCode'] }
    CheckTrue 'a missing PsExec names the fix' ($why -match 'virutil ui setup win11')
    Check     'and exits 97' 97 $code
    $script:UiRc = 0

    # --- a whole run --------------------------------------------------------

    $confPath = WriteConf 'sync.conf' $base
    $script:Published = 0; $script:Unpublished = 0; $script:GuestRc = 0
    $out = Capture { Sync-Main @('win11', '-c', $confPath) }

    Check 'the share went up and came down again' '1 1' "$($script:Published) $($script:Unpublished)"
    CheckTrue 'the config it read is named'  ($out -match 'config: ')
    CheckTrue 'the fetch says where from'    ($out -match 'fetch: ')
    CheckTrue 'the map destination is shown as the guest spells it' `
        ($out -match [regex]::Escape('-> C:\Program Files\Example'))
    CheckTrue 'the delivery line names the guest root' ($out -match 'deliver: .* -> win11 C:\\')
    CheckTrue 'the pre rule ran, and said so'  ($out -match 'run \(pre\): Stop-Service')
    CheckTrue 'the post rule ran, and said so' ($out -match 'run \(post\): Start-Service')
    CheckTrue 'it reports what was offered'    ($out -match 'win11: 2 files offered')
    CheckTrue 'it ends by saying so'           ($out -match 'copy complete -> win11')

    # The excluded file is the assertion here: !*.pdb is applied to the fetch,
    # so it is not in the staging tree, and therefore cannot reach the guest
    # however the map rules are written.
    $staged = Join-Path $script:VirutilsStagingRoot 'proj'
    CheckTrue 'the fetch brought the exe'  (Test-Path -LiteralPath (Join-Path $staged 'app.exe'))
    CheckTrue 'the fetch brought the subdirectory' `
        (Test-Path -LiteralPath (Join-Path $staged 'res\one.txt'))
    CheckTrue 'an excluded file never reached staging' `
        (-not (Test-Path -LiteralPath (Join-Path $staged 'app.pdb')))

    # What the guest was actually offered: the payload is one robocopy of the
    # share onto C:\, and the share's UNC is the one the session handed out.
    $payload = DeliveryPayload
    CheckTrue 'the guest is sent the shared sync payload' ($payload -match 'robocopy')
    CheckTrue 'it copies onto the root of C:'  ($payload -match '\$dst = "C:\\"')
    CheckTrue 'and it is /E, never /MIR'       (($payload -match '/E ') -and -not ($payload -match '/MIR'))
    CheckTrue 'the source is the published share' ($payload -match '\$src = .\\\\10\.0\.2\.2\\')

    # The cleanup rules reached the guest as absolute guest paths.
    $clean = @($script:Sent | Where-Object { $_ -match 'emptied' })
    Check 'the cleanup script was sent once' 1 $clean.Count
    CheckTrue 'the cleanup pattern is absolute in the guest' `
        ($clean[0] -match [regex]::Escape('C:\ProgramData\Example\logs'))

    CheckTrue 'a run that completed left no staged tree' `
        (-not (Test-Path -LiteralPath $script:LastScratch))

    # --- a second run moves nothing -----------------------------------------
    #
    # The guest reporting "0" for robocopy's bit 0 is what "nothing had to
    # move" looks like on the wire, and it has to read as success rather than
    # as an empty delivery.
    $script:GuestOut = '0 12'
    $out = Capture { Sync-Main @('win11', '-c', $confPath) }
    CheckTrue 'an unchanged tree reports as current' ($out -match 'all already current in the guest')
    CheckTrue 'and still says it completed'          ($out -match 'copy complete')
    $script:GuestOut = '1 1234'

    # --- the guest went away mid-run ----------------------------------------
    #
    # A guest that is gone has no agent to run anything and nothing worth
    # stopping either, so the rules are skipped with a note rather than failing
    # a copy that already landed.
    $script:Running = $false
    $out = Capture { Sync-Main @('win11', '-c', $confPath) }
    CheckTrue 'run rules are skipped when the guest went away' ($out -match 'run rules skipped')
    CheckTrue 'and the run still completes'                    ($out -match 'copy complete')
    $script:Running = $true

    # --- nothing matched ----------------------------------------------------
    #
    # Refused before the share goes up, which is the same ordering point as the
    # two refusals above: an elevation prompt followed by "nothing matched" is
    # the worst available sequence.
    $nada = WriteConf 'nada.conf' (@("@repo=$repo", '@staging=proj2', '<bin/Release|.', 'no-such-*|'))
    $script:Published = 0
    $why = Dies { Capture { Sync-Main @('win11', '-c', $nada) } }
    CheckTrue 'an empty delivery is refused'      ($why -match 'nothing to deliver')
    Check     'and no share was published for it' 0 $script:Published

    # --- the guest failed the copy ------------------------------------------
    #
    # The guest's own exit code becomes virutil's, and the teardown still runs:
    # a failed delivery must not leave a share, an account or a staged tree.
    $script:GuestRc = 93
    $script:Published = 0; $script:Unpublished = 0
    $why = Dies { Capture { Sync-Main @('win11', '-c', $confPath) } }
    CheckTrue 'a failed delivery is diagnosed' ($why -match 'robocopy could not deliver')
    CheckTrue 'and says the cleanup rules did not run' ($why -match 'no .post rule has run')
    Check 'the share came down anyway' '1 1' "$($script:Published) $($script:Unpublished)"
    CheckTrue 'a run that failed left no staged tree either' `
        (-not (Test-Path -LiteralPath $script:LastScratch))
    $script:GuestRc = 0

    # --- preconditions come first -------------------------------------------
    $script:ReadyFails = $true
    $script:Published = 0
    $why = Dies { Capture { Sync-Main @('win11', '-c', $confPath) } }
    CheckTrue 'a guest that is not ready stops the run' ($why -match 'not running')
    Check 'before the fetch and before any prompt' 0 $script:Published
    $script:ReadyFails = $false

    # --- usage --------------------------------------------------------------
    CheckTrue 'no VM is a usage error' `
        ((Dies { Sync-Main @() }) -match 'usage: virutil sync')
    CheckTrue 'a removed flag is refused with its reason' `
        ((Dies { Sync-Main @('win11', '--disk') }) -match '--disk is gone')
    CheckTrue 'a missing config names the path it looked for' `
        ((Dies { Sync-Main @('win11', '-c', (Join-Path $conf 'absent.conf')) }) -match 'config not found')

} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:VIRUTILS_DIR -Recurse -Force -ErrorAction SilentlyContinue
}

[Console]::Out.WriteLine('')
[Console]::Out.WriteLine("$script:Pass passed, $script:Fail failed")
if ($script:Fail) { exit 1 }
