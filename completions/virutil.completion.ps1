<#
  PowerShell completion for virutil -- mirrors the dispatch in
  modules\parser.ps1, the way completions\_virutil mirrors modules/parser.

  Dot-source it from your $PROFILE:

      . "$HOME\.dotfiles\virutils\completions\virutil.completion.ps1"

  install.ps1 adds that line for you.

  This completes the *Windows* driver, so it offers domain, snapshot, exec
  and usb and nothing else. sync, push, pull and ui are in the bash tree
  only, and offering a name this driver would reject is worse than offering
  nothing -- $MODULES in modules\parser.ps1 is the list to keep this in step
  with. usb and snapshot are on both drivers, spelled the same way on each.

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

    # The flags that take a value, as the driver reads them. A flag and the
    # word after it are one thing to the parser and have to be one thing here
    # too -- both halves are dropped from the positional count below, and the
    # value half is answered by Get-FlagValues rather than by whatever the
    # positional index would have offered.
    #
    # Keyed on the flag alone rather than on module+verb: -c means --vcpus
    # under `domain create` and --close under `domain port`, but both take a
    # value, which is all this table is asked. What the value *is* is
    # Get-FlagValues' problem, and that one does look at the verb.
    $valueFlags = @(
        '-s', '--size', '-m', '--memory', '-c', '--vcpus', '-o', '--osinfo',
        '-v', '--virtio', '-p', '--port', '--close'
    )

    # Flags do not consume a slot, so the positional index counts only the
    # words that are not flags and not a flag's value. Without this,
    # `virutil exec ps -d <TAB>` would be offered VM names a second time, and
    # `domain create win11 x.iso -m 8192 <TAB>` would count 8192 as a word of
    # the grammar and answer as if it were two arguments further along.
    $positional = @()
    $skip = $false
    foreach ($w in $words) {
        if ($skip) { $skip = $false; continue }
        if ($w.StartsWith('-')) { if ($w -in $valueFlags) { $skip = $true }; continue }
        $positional += $w
    }
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

    # The host's USB devices as VENDOR:PRODUCT, the way `usb list` spells
    # them, with the Windows name as the tooltip. ~200ms on this host, which is
    # inside what a keypress can spend; the WQL filter is what keeps it there.
    function Get-UsbIds {
        $seen = @{}
        Get-CimInstance -ClassName Win32_PnPEntity -Filter "DeviceID LIKE 'USB\\VID[_]%'" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $m = [regex]::Match([string]$_.PNPDeviceID, '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})')
                if (-not $m.Success) { return }
                $id = ('{0}:{1}' -f $m.Groups[1].Value, $m.Groups[2].Value).ToLowerInvariant()
                if ($seen.ContainsKey($id)) { return }
                $seen[$id] = $true
                [pscustomobject]@{ Text = $id; Tip = $_.Name }
            }
    }

    # The devices one domain passes through, read out of its launcher -- the
    # same place `usb show` reads them, so detach completes only what is there.
    function Get-DomainUsbIds([string]$Vm) {
        $path = Join-Path $imageDir "$Vm.cmd"
        if (-not (Test-Path -LiteralPath $path)) { return @() }
        $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
        [regex]::Matches([string]$text, '-device\s+"?usb-host,vendorid=0x([0-9a-fA-F]{4}),productid=0x([0-9a-fA-F]{4})') |
            ForEach-Object { ('{0}:{1}' -f $_.Groups[1].Value, $_.Groups[2].Value).ToLowerInvariant() }
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

    # **A native completer that returns nothing hands the word to PowerShell's
    # own file completion.** That is right for an ISO path and wrong for
    # everything else this completer knows about: `-m <TAB>` offered .git and
    # README.md for a number of MiB, and `domain port VM -c <TAB>` offers the
    # same list whenever the domain has no forwards open -- an empty answer and
    # a wrong answer look identical from here.
    #
    # So a branch that owns the answer sets $hint to what it would say if it
    # found nothing, and a branch that wants the file fallback leaves $hint
    # null. That is one variable doing both jobs on purpose: "who owns this
    # word" and "what is true about it when the list comes back empty" are the
    # same question, and keeping them apart is how the two drift.
    #
    # The text is a space because a CompletionResult may not be empty: Tab then
    # inserts whitespace, which the driver's own parser discards, and the
    # reason shows in the menu beside it.
    $hint = $null
    function Add-NoMatch([string]$Why) {
        $out.Add([Management.Automation.CompletionResult]::new(
            ' ', "($Why)", 'ParameterValue', $Why))
    }

    # --- the grammar ---------------------------------------------------------

    $modules = [ordered]@{
        domain   = 'the domain lifecycle: create, delete, list, start, shutdown, addr, port'
        snapshot = 'qcow2 internal snapshots: create, list, revert, delete'
        exec     = 'run commands inside a guest via the QEMU guest agent'
        usb      = 'pass a host USB device through to a guest'
        help     = 'the module list'
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

    # Disk-only, and every verb but `list` wants the domain shut off: WHPX
    # blocks saving a running guest's memory. The tooltips say so, because a
    # snapshot that quietly held no memory is the thing docs/contract.md spent
    # longest refusing to ship.
    $snapshotVerbs = [ordered]@{
        create = 'snapshot the disk (default name snap-<timestamp>; needs the domain shut off)'
        list   = 'the snapshots inside the domain disk'
        revert = 'put the disk back to a snapshot (needs the domain shut off)'
        delete = 'remove a snapshot from the disk (needs the domain shut off)'
    }

    $usbVerbs = [ordered]@{
        list   = 'the host USB devices, as VENDOR:PRODUCT'
        show   = 'what a domain passes through, live and persistent'
        attach = 'pass a host device through to a domain'
        detach = 'take one back from a domain'
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

    # --- a flag's value ------------------------------------------------------
    #
    # The word after a value-taking flag is that flag's value, never the next
    # word of the grammar. Answering it matters twice over: the positional
    # index is already stepped past it above, and **a completer that returns
    # nothing hands the word to PowerShell's own file completion**, so `-m
    # <TAB>` offered the contents of the working directory -- .git, README.md
    # and the rest -- for a flag whose value is a number of MiB.
    #
    # So every value-taking flag answers with something. Sizes and counts are
    # free-form numbers and the best a completion can do is offer sensible
    # round values and let anything else be typed over them, which is what
    # _virutil_size, _virutil_memory and _virutil_vcpus do in
    # completions\_virutil; the lists here are those lists.
    #
    # -v/--virtio is the one exception and falls through deliberately: its
    # value is a path to an ISO, and PowerShell's file completion handles
    # relative paths, spaces and quoting better than anything written here
    # would -- the same reason `domain create VM ISO` is not in the switch
    # below. `none` is still offered once there is a prefix to match it on.
    $prev = if ($words.Count -ge 1) { $words[-1] } else { $null }
    if ($prev -in $valueFlags) {
        # -v/--virtio is the one that wants the fallback, so it is the one that
        # leaves $hint null.
        $hint = if ($prev -in @('-v', '--virtio')) { $null }
                elseif ($module -eq 'domain' -and $verb -eq 'port') { "$($positional[2]) has no forwards open" }
                else { "$prev takes a value, and it is not a path" }
        switch ($prev) {
            { $_ -in @('-s', '--size') } {
                foreach ($n in 32, 64, 128, 256, 512) { Add-Match "$n" 'GiB' }
            }
            { $_ -in @('-m', '--memory') } {
                foreach ($n in 2048, 4096, 8192, 12288, 16384, 24576, 32768) { Add-Match "$n" 'MiB' }
            }
            { $_ -in @('-c', '--vcpus', '--close') } {
                # -c is --vcpus under create and --close under port, and the
                # two answer with entirely different things.
                if ($module -eq 'domain' -and $verb -eq 'port') {
                    foreach ($p in Get-Ports $positional[2]) { Add-Match $p.Text $p.Tip }
                } else {
                    foreach ($n in 1, 2, 4, 6, 8, 12, 16) { Add-Match "$n" 'vcpus' }
                }
            }
            { $_ -in @('-o', '--osinfo') } {
                Add-Match 'win11' 'accepted and ignored here: there is no libosinfo on this host'
            }
            { $_ -in @('-p', '--port') } {
                Add-Match '13389:3389' 'HOSTPORT:GUESTPORT (the default forward)'
            }
            { $_ -in @('-v', '--virtio') } {
                # Only once there is a prefix to match it on: offering `none`
                # for an empty word would return a non-empty list and so
                # suppress the file completion that is the point of this case.
                if ($wordToComplete) { Add-Match 'none' 'attach no virtio-win ISO' }
            }
        }
        if ($hint -and $out.Count -eq 0) { Add-NoMatch $hint }
        return $out
    }

    # The domains, read once: three branches below want them, and two want to
    # know whether there are any in order to say the right thing when nothing
    # matched.
    $domains = @(Get-Domains)
    $noDomain = if ($domains.Count -eq 0) {
        'no domains yet -- virutil domain create'
    } else {
        "no domain starts with '$wordToComplete'"
    }

    switch ($pos) {
        0 {
            $hint = "no module starts with '$wordToComplete' -- see virutil help"
            foreach ($k in $modules.Keys) { Add-Match $k $modules[$k] }
        }
        1 {
            $hint = "$module has no verb starting with '$wordToComplete'"
            if ($module -eq 'domain') { foreach ($k in $domainVerbs.Keys) { Add-Match $k $domainVerbs[$k] } }
            elseif ($module -eq 'snapshot') { foreach ($k in $snapshotVerbs.Keys) { Add-Match $k $snapshotVerbs[$k] } }
            elseif ($module -eq 'exec') { foreach ($k in $execVerbs.Keys) { Add-Match $k $execVerbs[$k] } }
            elseif ($module -eq 'usb') { foreach ($k in $usbVerbs.Keys) { Add-Match $k $usbVerbs[$k] } }
        }
        2 {
            # `domain create` names a domain that does not exist yet, and
            # `domain list` takes nothing at all; everything else here wants
            # one that does.
            #
            # The first two still claim the word. There is nothing to *offer*
            # for either, but that is not the same as having no answer, and a
            # completer that says nothing here gets PowerShell's file list --
            # which is how `domain create <TAB>` came to propose .git as the
            # name of a virtual machine. `_virutil` spells the same intent as
            # an empty action on line 348: "the new domain's name: nothing to
            # complete".
            if ($module -eq 'domain' -and $verb -eq 'create') {
                $hint = 'the new domain name -- anything not already a domain'
            }
            elseif (($module -eq 'domain' -or $module -eq 'usb') -and $verb -eq 'list') {
                $hint = "$module list takes nothing else"
            }
            elseif ($module -eq 'domain') {
                $hint = $noDomain
                foreach ($d in $domains) { Add-Match $d 'domain' }
            }
            elseif ($module -in @('exec', 'snapshot')) {
                $hint = $noDomain
                foreach ($d in $domains) { Add-Match $d 'domain' }
            }
            elseif ($module -eq 'usb') {
                $hint = $noDomain
                foreach ($d in $domains) { Add-Match $d 'domain' }
            }
        }
        3 {
            # `domain create VM ISO` is the one word here that wants the file
            # fallback, so it is the one that leaves $hint null: PowerShell
            # already handles relative paths, spaces and quoting, all of which
            # a hand-rolled ISO matcher gets wrong for the sake of filtering on
            # an extension.
            #
            # `domain port VM SPEC` -- PORT, or HOSTPORT:GUESTPORT.
            if ($module -eq 'domain' -and $verb -eq 'port') {
                $hint = "$($positional[2]) has no forwards open"
                foreach ($p in Get-Ports $positional[2]) { Add-Match $p.Text $p.Tip }
            }
            # attach names a device on the host; detach names one the domain
            # already has, which is a much shorter and more useful list.
            elseif ($module -eq 'usb' -and $verb -eq 'attach') {
                $hint = 'no USB devices on this host'
                foreach ($u in Get-UsbIds) { Add-Match $u.Text $u.Tip }
            }
            # `snapshot revert VM SNAP` completes nothing on purpose, where
            # the zsh completion offers the names. Reading them means running
            # qemu-img against the domain's disk -- a subprocess per keypress,
            # and one that must not touch the image of a running domain, which
            # in turn needs a monitor connection to rule out. That is far more
            # than a Tab should cost; the names are one `virutil snapshot list`
            # away, and saying so beats listing the working directory.
            elseif ($module -eq 'snapshot' -and $verb -in @('revert', 'delete')) {
                $hint = "the snapshot name -- see: virutil snapshot list $($positional[2])"
            }
            elseif ($module -eq 'usb' -and $verb -eq 'detach') {
                $hint = "$($positional[2]) passes through no USB devices"
                foreach ($u in Get-DomainUsbIds $positional[2]) { Add-Match $u 'attached' }
            }
        }
    }

    # The empty-but-owned answer, said rather than fallen through.
    if ($hint -and $out.Count -eq 0) { Add-NoMatch $hint }

    return $out
}

# Both spellings: PowerShell finds the script on PATH as `virutil`, but an
# explicit `virutil.ps1` or a .\virutil.ps1 is the same command and should
# complete the same way.
Register-ArgumentCompleter -CommandName 'virutil', 'virutil.ps1' -Native -ScriptBlock $completer
