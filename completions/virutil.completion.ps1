<#
  PowerShell completion for virutil -- mirrors the dispatch in
  modules\parser.ps1, the way completions\_virutil mirrors modules/parser.

  Dot-source it from your $PROFILE:

      . "$HOME\.dotfiles\virutils\completions\virutil.completion.ps1"

  install.ps1 adds that line for you.

  This completes the *Windows* driver, so it offers domain and exec and
  nothing else. snapshot, sync, push, pull, ui and usb are in the bash tree
  only, and offering a name this driver would reject is worse than offering
  nothing -- $MODULES in modules\parser.ps1 is the list to keep this in step
  with.

  Everything lives inside the scriptblock rather than in functions beside it:
  a completer dot-sourced into a profile should leave nothing behind in the
  global scope but the registration itself.
#>

$completer = {
    param($wordToComplete, $commandAst, $cursorPosition)

    # --- what the driver would see ------------------------------------------

    # CommandElements[0] is the command; the rest are its arguments. When the
    # cursor sits mid-word that partial word is an element too, and it is not
    # an argument yet -- dropping it is what makes position mean "the index of
    # the word being completed".
    $words = @($commandAst.CommandElements | Select-Object -Skip 1 |
               ForEach-Object { $_.ToString() })
    # The empty case is spelled out rather than sliced: $words[0..-1] counts
    # backwards from the end and hands back the whole array, which is the same
    # trap Get-RestArgs in modules\parser.ps1 exists to avoid. Getting it wrong
    # here means the first word never completes at all.
    if ($wordToComplete -and $words.Count -gt 0) {
        $words = if ($words.Count -eq 1) { @() } else { @($words[0..($words.Count - 2)]) }
    }

    # Flags do not consume a slot, so the positional index counts only the
    # words that are not flags. Without this, `virutil exec ps -d <TAB>` would
    # be offered VM names a second time.
    $positional = @($words | Where-Object { -not $_.StartsWith('-') })
    $pos = $positional.Count

    # --- the state the driver reads -----------------------------------------

    # modules\paths.ps1: VIRUTILS_ first, then the singular VIRUTIL_, then the
    # default. Completion that disagrees with the driver about where the
    # images live is a completion that offers domains that do not exist.
    function Get-Root([string]$Name, [string]$Default) {
        foreach ($p in "VIRUTILS_$Name", "VIRUTIL_$Name") {
            $v = [Environment]::GetEnvironmentVariable($p)
            if ($v) { return $v }
        }
        return $Default
    }

    $root     = Get-Root 'DIR'       (Join-Path $env:USERPROFILE '.virutils')
    $imageDir = Get-Root 'IMAGE_DIR' (Join-Path $root 'images')
    $portDir  = Get-Root 'PORT_DIR'  (Join-Path $root 'ports')

    # A domain is a launcher in the image dir -- the same thing `domain list`
    # counts. Its running state is deliberately not shown: telling it needs a
    # monitor connection per domain, which is far too much to do on a keypress.
    function Get-Domains {
        if (-not (Test-Path -LiteralPath $imageDir)) { return @() }
        Get-ChildItem -LiteralPath $imageDir -Filter '*.cmd' -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) }
    }

    # The host ports this domain currently forwards; the guest side is the
    # tooltip, as in the zsh completion.
    function Get-Ports([string]$Vm) {
        if (-not (Test-Path -LiteralPath $portDir)) { return @() }
        Get-ChildItem -LiteralPath $portDir -Filter 'tcp-*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $hostPort = $_.Name -replace '^tcp-', ''
                $guest = (Get-Content -LiteralPath $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue)
                [pscustomobject]@{ Text = $hostPort; Tip = "-> $guest" }
            }
    }

    # --- emitting ------------------------------------------------------------

    $out = [Collections.Generic.List[Management.Automation.CompletionResult]]::new()

    function Add-Match([string]$Text, [string]$Tip) {
        if ($Text -notlike "$wordToComplete*") { return }
        $out.Add([Management.Automation.CompletionResult]::new(
            $Text, $Text, 'ParameterValue', $(if ($Tip) { $Tip } else { $Text })))
    }

    # --- the grammar ---------------------------------------------------------

    $modules = [ordered]@{
        domain = 'the domain lifecycle: create, delete, list, start, shutdown, addr, port'
        exec   = 'run commands inside a guest via the QEMU guest agent'
        help   = 'the module list'
    }

    $domainVerbs = [ordered]@{
        create   = 'make a disk and a launcher from an install ISO, and start it'
        delete   = 'remove the disk, the nvram and the launcher; never asks'
        list     = 'the domains on this host and their state'
        start    = 'boot an existing domain'
        shutdown = 'ask the guest to shut itself down over ACPI'
        addr     = "the guest's address"
        port     = 'list, open or close a host->guest port forward'
    }

    $execVerbs = [ordered]@{
        ping = 'is the guest agent answering'
        cmd  = 'run a command through cmd.exe in a Windows guest'
        ps   = 'run a command through powershell.exe in a Windows guest'
        sh   = 'run a command through /bin/sh in a Linux guest'
    }

    $module = if ($positional.Count -ge 1) { $positional[0] } else { $null }
    $verb   = if ($positional.Count -ge 2) { $positional[1] } else { $null }

    # Flags first: a leading `-` means the answer is never a positional one.
    if ($wordToComplete.StartsWith('-')) {
        Add-Match '-h' 'this message'
        Add-Match '--help' 'this message'

        if ($module -eq 'domain' -and $verb -eq 'create') {
            Add-Match '-s' 'disk size in GiB (default 64)';           Add-Match '--size' 'disk size in GiB (default 64)'
            Add-Match '-m' "guest RAM in MiB (default: half the host's)"; Add-Match '--memory' "guest RAM in MiB (default: half the host's)"
            Add-Match '-c' "virtual CPUs (default: half the host's, max 8)"; Add-Match '--vcpus' "virtual CPUs (default: half the host's, max 8)"
            Add-Match '-o' 'accepted and ignored: no libosinfo here';  Add-Match '--osinfo' 'accepted and ignored: no libosinfo here'
            Add-Match '-v' 'virtio-win ISO, or "none"';               Add-Match '--virtio' 'virtio-win ISO, or "none"'
            Add-Match '-p' 'a port forward, repeatable (default 13389:3389)'; Add-Match '--port' 'a port forward, repeatable'
            Add-Match '-N' 'create it without starting it';            Add-Match '--no-start' 'create it without starting it'
        }
        elseif ($module -eq 'domain' -and $verb -eq 'start') {
            Add-Match '-G' 'accepted and not honoured: WHPX has no headless console'
            Add-Match '--no-gui' 'accepted and not honoured: WHPX has no headless console'
        }
        elseif ($module -eq 'domain' -and $verb -eq 'port') {
            Add-Match '-c' 'close the forward on host PORT'
            Add-Match '--close' 'close the forward on host PORT'
        }
        elseif ($module -eq 'exec' -and $verb -in @('cmd', 'ps', 'sh')) {
            Add-Match '-d' 'fire and forget: print the guest pid and exit 0'
            Add-Match '--detach' 'fire and forget: print the guest pid and exit 0'
            Add-Match '--' 'end of flags'
        }
        return $out
    }

    # The word after -c/--close on `domain port` is a host port, not a domain.
    $prev = if ($words.Count -ge 1) { $words[-1] } else { $null }
    if ($module -eq 'domain' -and $verb -eq 'port' -and $prev -in @('-c', '--close')) {
        foreach ($p in Get-Ports $positional[2]) { Add-Match $p.Text $p.Tip }
        return $out
    }

    switch ($pos) {
        0 {
            foreach ($k in $modules.Keys) { Add-Match $k $modules[$k] }
        }
        1 {
            if ($module -eq 'domain') { foreach ($k in $domainVerbs.Keys) { Add-Match $k $domainVerbs[$k] } }
            elseif ($module -eq 'exec') { foreach ($k in $execVerbs.Keys) { Add-Match $k $execVerbs[$k] } }
        }
        2 {
            # `domain create` names a domain that does not exist yet, and
            # `domain list` takes nothing at all; everything else here wants
            # one that does.
            if ($module -eq 'domain' -and $verb -notin @('create', 'list')) {
                foreach ($d in Get-Domains) { Add-Match $d 'domain' }
            }
            elseif ($module -eq 'exec') {
                foreach ($d in Get-Domains) { Add-Match $d 'domain' }
            }
        }
        3 {
            # `domain create VM ISO` is not here on purpose. Returning nothing
            # lets PowerShell fall back to its own file completion, which
            # already handles relative paths, spaces and quoting -- all of
            # which a hand-rolled ISO matcher gets wrong for the sake of
            # filtering on an extension.
            #
            # `domain port VM SPEC` -- PORT, or HOSTPORT:GUESTPORT.
            if ($module -eq 'domain' -and $verb -eq 'port') {
                foreach ($p in Get-Ports $positional[2]) { Add-Match $p.Text $p.Tip }
            }
        }
    }

    return $out
}

# Both spellings: PowerShell finds the script on PATH as `virutil`, but an
# explicit `virutil.ps1` or a .\virutil.ps1 is the same command and should
# complete the same way.
Register-ArgumentCompleter -CommandName 'virutil', 'virutil.ps1' -Native -ScriptBlock $completer
