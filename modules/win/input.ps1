# input -- drive a running domain's pointer and keyboard from this host.
#
# The input side of modules/win/shot.ps1, and the counterpart of
# modules/linux/input and modules/mac/input. All three hand the events to qemu,
# which delivers them through the domain's emulated tablet and keyboard. Nothing
# runs in the guest, so to Windows they are hardware input: they reach whatever
# window has the focus at whatever integrity level, the UAC prompt and the logon
# screen included, which a SendInput from a process in the guest cannot do.
#
# **The pointer is absolute, and the human monitor cannot send absolute
# events.** This driver's only handle on a running domain is the human monitor
# (-monitor in the launcher; there is no QMP socket), and its `mouse_move`
# queues *relative* motion. Measured on v11.1.0-12130 with qemu's input_event
# trace on, against a q35 with a usb-tablet:
#
#   mouse_move 100 200   ->  input_event_rel con -1, axis x, value 100
#                            input_event_rel con -1, axis y, value 200
#
# A relative event goes to the PS/2 mouse, never to the tablet, and Windows
# scales it by its own pointer acceleration, so where it lands is not
# knowable from here. QMP's input-send-event takes absolute axes, but a monitor
# cannot be added to a running qemu, and adding -qmp to the launcher would mean
# restarting the domain.
#
# What the human monitor can do is create an object, and qemu has one that
# turns a network peer's absolute pointer into tablet events: input-barrier,
# the client half of the Barrier (Synergy) protocol. object_add makes qemu
# connect out, synchronously, to a listener this file opens on loopback; the
# listener then plays the Barrier server for one run, and object_del takes the
# object away again. The same trace, for a DMMV of 16384,8192 sent that way:
#
#   input_event_abs con -1, axis x, value 0x4000
#   input_event_abs con -1, axis y, value 0x2000
#
# The object is given width=height=32767, so qemu's scaling is the identity and
# the value sent is the value the tablet reports: Get-InputAbs maps a screen
# pixel to the centre of its own slice of the 0..32767 range. The screen size
# comes from a screendump, taken over the same monitor connection.
#
# Keys go over `sendkey`, which takes qemu's own key names (qcodes) and queues
# each press and release with a hold time, in order, behind the one before.
#
# The monitor serves one client at a time, so the whole run is one connection:
# Invoke-DomainMonitor's connect-send-drain costs two seconds a command, which
# would make `type` a matter of minutes.

$script:InputBarrierButtons = @{ left = 1; middle = 2; right = 3 }

# Key names a COMBO may use, as aliases of a qcode. A single letter, digit,
# f1-f12 or punctuation character is a key by itself, and so is any qcode in
# $script:InputQcodes below.
$script:InputKeyAliases = @{
    ctrl = 'ctrl'; control = 'ctrl'; rctrl = 'ctrl_r'
    alt = 'alt'; ralt = 'alt_r'; altgr = 'alt_r'
    shift = 'shift'; rshift = 'shift_r'
    win = 'meta_l'; super = 'meta_l'; meta = 'meta_l'; cmd = 'meta_l'
    enter = 'ret'; return = 'ret'; esc = 'esc'; escape = 'esc'; tab = 'tab'
    space = 'spc'; backspace = 'backspace'; bksp = 'backspace'
    delete = 'delete'; del = 'delete'; insert = 'insert'; ins = 'insert'
    home = 'home'; end = 'end'; pgup = 'pgup'; pageup = 'pgup'; pgdn = 'pgdn'; pagedown = 'pgdn'
    up = 'up'; down = 'down'; left = 'left'; right = 'right'
    # The PC context-menu key is qemu's compose (scancode e0 5d); qemu's own
    # `menu` is a different key that Windows ignores.
    menu = 'compose'; apps = 'compose'; printscreen = 'print'; prtsc = 'print'
    capslock = 'caps_lock'; numlock = 'num_lock'; scrolllock = 'scroll_lock'; pause = 'pause'
    minus = 'minus'; equal = 'equal'; comma = 'comma'; dot = 'dot'; period = 'dot'; slash = 'slash'
    backslash = 'backslash'; semicolon = 'semicolon'; apostrophe = 'apostrophe'
    grave = 'grave_accent'; grave_accent = 'grave_accent'
    bracket_left = 'bracket_left'; bracket_right = 'bracket_right'
}

# The rest of qemu's QKeyCode, accepted by its own name: the keypad, the media
# keys, f13-f24 and whatever else no alias reaches.
$script:InputQcodes = -split @'
shift shift_r alt alt_r ctrl ctrl_r menu esc minus equal backspace tab ret semicolon
apostrophe grave_accent backslash comma dot slash asterisk spc caps_lock num_lock
scroll_lock kp_divide kp_multiply kp_subtract kp_add kp_enter kp_decimal sysrq kp_0
kp_1 kp_2 kp_3 kp_4 kp_5 kp_6 kp_7 kp_8 kp_9 less print home pgup pgdn end left up
down right insert delete stop again props undo front copy open paste find cut lf help
meta_l meta_r compose pause ro hiragana henkan yen muhenkan katakanahiragana kp_comma
kp_equals power sleep wake audionext audioprev audiostop audioplay audiomute volumeup
volumedown mediaselect mail calculator computer ac_home ac_back ac_forward ac_refresh
ac_bookmarks lang1 lang2 f13 f14 f15 f16 f17 f18 f19 f20 f21 f22 f23 f24
'@

# The US layout: each printable ASCII character as the key that types it and
# whether shift is held. Unshifted punctuation is also how a COMBO names it.
$script:InputUsPlain = @{
    '-' = 'minus'; '=' = 'equal'; '[' = 'bracket_left'; ']' = 'bracket_right'; '\' = 'backslash'
    ';' = 'semicolon'; "'" = 'apostrophe'; '`' = 'grave_accent'; ',' = 'comma'; '.' = 'dot'; '/' = 'slash'
    ' ' = 'spc'; "`t" = 'tab'; "`n" = 'ret'
}
$script:InputUsShifted = @{
    '!' = '1'; '@' = '2'; '#' = '3'; '$' = '4'; '%' = '5'; '^' = '6'; '&' = '7'; '*' = '8'; '(' = '9'; ')' = '0'
    '_' = 'minus'; '+' = 'equal'; '{' = 'bracket_left'; '}' = 'bracket_right'; '|' = 'backslash'
    ':' = 'semicolon'; '"' = 'apostrophe'; '~' = 'grave_accent'; '<' = 'comma'; '>' = 'dot'; '?' = 'slash'
}

function Get-InputUsage {
    @(
        'usage: virutil input click VM X Y [-b BUTTON] [--double]'
        '       virutil input move  VM X Y'
        '       virutil input drag  VM X1 Y1 X2 Y2 [-b BUTTON]'
        '       virutil input wheel VM X Y N'
        '       virutil input key   VM COMBO...'
        '       virutil input type  VM TEXT...'
        ''
        "Drive VM's pointer and keyboard from this host: the input side of"
        "'virutil shot'. X and Y are pixels of the guest's screen, the same as in"
        'a shot PNG, with 0,0 its top-left corner.'
        ''
        '  click   move to X,Y and click'
        '  move    move the pointer to X,Y'
        '  drag    press at X1,Y1, move to X2,Y2 and release there'
        '  wheel   scroll N notches at X,Y: positive up, negative down'
        '  key     press and release each COMBO in turn: ctrl+a, alt+f4, enter,'
        '          win, ctrl+alt+delete, f5, shift+tab'
        '  type    type TEXT, its words joined by one space, as US-layout keys'
        ''
        '  -b, --button B  left (default), right or middle'
        '      --double    click twice, as a double-click'
        '  -h, --help      this message'
        ''
        'Key names: a-z 0-9 f1-f12 ctrl alt shift win enter esc tab space'
        'backspace delete insert home end pgup pgdn up down left right menu'
        'printscreen capslock, the unshifted punctuation keys by character'
        '(- = [ ] \ ; '' ` , . /), and any qemu key name (qcode).'
        ''
        'type sends key presses, not characters: a guest on another layout gets'
        "that layout's characters, and caps lock inverts letters. It types"
        'printable ASCII, tab and newline, and refuses anything else before'
        'sending a key.'
        ''
        'Nothing runs in the guest: qemu delivers the events through the'
        "domain's emulated tablet and keyboard, so Windows takes them as"
        'hardware input, elevated windows and the UAC prompt included. The'
        'pointer needs an absolute device (usb-tablet); key and type do not.'
    )
}

function Input-Main {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { Usage (Get-InputUsage) 1 }
    $verb = $Arguments[0]
    if ($verb -in @('-h', '--help')) { Usage (Get-InputUsage) 0 }
    if ($verb -notin @('click', 'move', 'drag', 'wheel', 'key', 'type')) {
        Die "virutil input: unknown command: $verb (see: virutil input -h)"
    }

    $button = 'left'; $double = $false; $pos = @()
    $rest = Get-RestArgs $Arguments 1
    $i = 0
    while ($i -lt $rest.Count) {
        $a = $rest[$i]
        # type's words and key's combos are taken as they are once VM is read,
        # so a TEXT that starts with a dash is typed rather than refused.
        if ($verb -in @('key', 'type') -and $pos.Count -ge 1) {
            $pos += $a
        } elseif ($a -in @('-h', '--help')) {
            Usage (Get-InputUsage) 0
        } elseif ($a -in @('-b', '--button') -and $verb -in @('click', 'drag')) {
            $i++
            if ($i -ge $rest.Count) { Die "virutil input: $a needs a value" }
            $button = $rest[$i]
            if (-not $script:InputBarrierButtons.ContainsKey($button)) {
                Die "virutil input: $a takes left, right or middle, not '$button'"
            }
        } elseif ($a -eq '--double' -and $verb -eq 'click') {
            $double = $true
        } elseif ($a -match '^-\D') {
            Die "virutil input: unknown flag for $verb`: $a (see: virutil input -h)"
        } else {
            $pos += $a
        }
        $i++
    }

    $want = @{ click = 3; move = 3; drag = 5; wheel = 4 }
    if ($want.ContainsKey($verb)) {
        if ($pos.Count -ne $want[$verb]) { Usage (Get-InputUsage) 1 }
        $nums = @(foreach ($p in $pos[1..($pos.Count - 1)]) {
            if ($p -notmatch '^-?\d+$') { Die "virutil input: expected a number, got '$p'" }
            [int]$p
        })
    } elseif ($pos.Count -lt 2) {
        Usage (Get-InputUsage) 1
    }
    $vm = $pos[0]

    # Everything that can be refused without the guest is refused first, so a
    # combo with a typo or a character with no key sends nothing at all.
    if ($verb -eq 'key') {
        $combos = @(foreach ($c in $pos[1..($pos.Count - 1)]) { ,(Read-InputCombo $c) })
    } elseif ($verb -eq 'type') {
        $text = ($pos[1..($pos.Count - 1)]) -join ' '
        $combos = ConvertTo-InputCombos $text
    }

    if (-not (Test-Domain $vm)) { Die "no such domain: $vm (see: virutil domain list)" }
    if (-not (Test-DomainRunning $vm)) { Die "$vm is not running: there is nothing to send input to" }

    $s = Open-InputSession $vm
    try {
        Assert-InputRunning $s
        if ($verb -in @('key', 'type')) {
            # A shorter hold for text: it is many keys, and 30ms is still three
            # frames of a 100Hz keyboard scan.
            $hold = if ($verb -eq 'type') { 30 } else { 100 }
            foreach ($c in $combos) { Send-InputKeys $s $c $hold }
            # sendkey returns as soon as the keys are queued. Waiting out the
            # queue means the next virutil command -- a shot -- sees the result.
            Wait-Input ($combos.Count * ($hold + 10) + 100)
            $what = if ($verb -eq 'type') { "typed $($text.Length) characters" } else { "key $($pos[1..($pos.Count - 1)] -join ' ')" }
            Say "$vm`: $what"
            return
        }

        Assert-InputAbsolute $s
        $size = Get-InputScreenSize $s
        for ($k = 0; $k -lt $nums.Count; $k += 2) {
            if ($verb -eq 'wheel' -and $k -eq 2) { break }
            if ($nums[$k] -lt 0 -or $nums[$k] -ge $size.Width -or $nums[$k + 1] -lt 0 -or $nums[$k + 1] -ge $size.Height) {
                Die "$($nums[$k]),$($nums[$k + 1]) is outside $vm's $($size.Width)x$($size.Height) screen"
            }
        }
        Open-InputPointer $s
        $x = $nums[0]; $y = $nums[1]
        switch ($verb) {
            'move' {
                Send-InputMove $s $size $x $y
                $what = "move $x,$y"
            }
            'click' {
                Send-InputMove $s $size $x $y
                Wait-Input 50
                foreach ($n in 1..$(if ($double) { 2 } else { 1 })) {
                    if ($n -gt 1) { Wait-Input 80 }
                    Send-InputButton $s $button $true
                    Wait-Input 50
                    Send-InputButton $s $button $false
                }
                $what = "$(if ($double) { 'double-' })click $x,$y$(if ($button -ne 'left') { " ($button)" })"
            }
            'drag' {
                $x2 = $nums[2]; $y2 = $nums[3]
                Send-InputMove $s $size $x $y
                Wait-Input 100
                Send-InputButton $s $button $true
                Wait-Input 100
                # In steps, so the guest sees a drag rather than a jump: a
                # window or a slider follows motion, not the end point alone.
                $steps = 10
                foreach ($n in 1..$steps) {
                    Send-InputMove $s $size ([int]($x + ($x2 - $x) * $n / $steps)) ([int]($y + ($y2 - $y) * $n / $steps))
                    Wait-Input 25
                }
                Wait-Input 100
                Send-InputButton $s $button $false
                $what = "drag $x,$y -> $x2,$y2$(if ($button -ne 'left') { " ($button)" })"
            }
            'wheel' {
                $notches = $nums[2]
                Send-InputMove $s $size $x $y
                Wait-Input 50
                for ($n = 0; $n -lt [Math]::Abs($notches); $n++) {
                    if ($n -gt 0) { Wait-Input 40 }
                    Send-InputWheel $s ($notches -gt 0)
                }
                $what = "wheel $notches at $x,$y"
            }
        }
        # The barrier events are delivered as qemu reads them; give it the time
        # to before the object and its socket go.
        Wait-Input 50
        Say "$vm`: $what on $($size.Width)x$($size.Height)"
    } finally {
        Close-InputSession $s
    }
}

# --- what is sent, decided before anything is ---------------------------------

# Read-InputCombo COMBO -- 'ctrl+alt+delete' as its qcodes, or a usage error
# naming the key it does not know.
function Read-InputCombo {
    param([string]$Combo)
    $keys = @()
    # '+' separates keys, so a COMBO of '+' alone or ending in '++' means the
    # key itself; on a US keyboard that is shift+equal, which is how it is sent.
    foreach ($part in ($Combo -split '\+(?!$)')) {
        $k = $part.ToLowerInvariant()
        if ($k -eq '') { Die "virutil input: empty key in '$Combo'" }
        if ($script:InputKeyAliases.ContainsKey($k)) { $keys += $script:InputKeyAliases[$k] }
        elseif ($k -match '^[a-z0-9]$') { $keys += $k }
        elseif ($k -match '^f([1-9]|1[0-2])$') { $keys += $k }
        elseif ($script:InputUsPlain.ContainsKey($k) -and $k.Trim()) { $keys += $script:InputUsPlain[$k] }
        elseif ($script:InputUsShifted.ContainsKey($k)) { $keys += 'shift', $script:InputUsShifted[$k] }
        elseif ($k -in $script:InputQcodes) { $keys += $k }
        else { Die "virutil input: unknown key '$part' in '$Combo' (see: virutil input -h)" }
    }
    return ,$keys
}

# ConvertTo-InputCombos TEXT -- one combo per character on the US layout, or a
# usage error listing every character that has no key there.
function ConvertTo-InputCombos {
    param([string]$Text)
    $combos = @(); $bad = @()
    $chars = [Globalization.StringInfo]::GetTextElementEnumerator(($Text -replace "`r`n", "`n"))
    while ($chars.MoveNext()) {
        $c = [string]$chars.Current
        if ($c -cmatch '^[a-z0-9]$') { $combos += ,@($c) }
        elseif ($c -cmatch '^[A-Z]$') { $combos += ,@('shift', $c.ToLowerInvariant()) }
        elseif ($script:InputUsPlain.ContainsKey($c)) { $combos += ,@($script:InputUsPlain[$c]) }
        elseif ($script:InputUsShifted.ContainsKey($c)) { $combos += ,@('shift', $script:InputUsShifted[$c]) }
        else {
            $cp = [Char]::ConvertToUtf32($c, 0)
            $bad += "'$c' (U+{0:X4})" -f $cp
        }
    }
    if ($bad.Count -gt 0) {
        Die @(
            "virutil input: cannot type $(@($bad | Select-Object -Unique) -join ', ')."
            'type sends US-layout key presses and covers printable ASCII, tab and'
            'newline only. Nothing was sent.'
        )
    }
    return ,$combos
}

# Get-InputAbs PIXEL SPAN -- the 0..32767 tablet value at the centre of PIXEL on
# a screen SPAN pixels across. The guest maps the range back onto its screen by
# scaling, so the centre of the pixel's slice survives rounding either way where
# its edge would not.
function Get-InputAbs {
    param([int]$Pixel, [int]$Span)
    $v = [Math]::Floor((2.0 * $Pixel + 1) * 32768 / (2.0 * $Span))
    return [int][Math]::Min(32767, [Math]::Max(0, $v))
}

# --- the session: one monitor connection, and the barrier pointer -----------

# Wait-Input MS -- a pause between events. Its own function so the tests can
# take the sleeping out.
function Wait-Input { param([int]$Ms) Start-Sleep -Milliseconds $Ms }

# Open-InputSession VM -- the monitor, connected, past its banner.
#
# A second client is accepted by the OS and then never served, so a banner that
# does not come is the monitor being held, not a slow qemu.
function Open-InputSession {
    param([string]$Vm)
    $port = Get-DomainMonitorPort $Vm
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        if (-not $tcp.ConnectAsync('127.0.0.1', $port).Wait(2000)) { throw 'timeout' }
    } catch {
        $tcp.Close()
        Die "could not reach $Vm's QEMU monitor on 127.0.0.1:$port"
    }
    $s = @{ Vm = $Vm; Tcp = $tcp; Stream = $tcp.GetStream(); Listener = $null; Barrier = $null; Object = $null }
    $s.Stream.ReadTimeout = 5000
    if ($null -eq (Read-InputPrompt $s)) {
        Close-InputSession $s
        Die @(
            "$Vm's QEMU monitor accepted the connection but never answered. It"
            'serves one client at a time, so something else -- another virutil, a'
            'shot -- may be holding it. Nothing was sent.'
        )
    }
    return $s
}

# Read-InputPrompt SESSION -- everything up to the next "(qemu) " prompt, with
# the terminal escapes taken out, or $null if it never came.
function Read-InputPrompt {
    param($S)
    $buf = New-Object byte[] 8192
    $sb = New-Object Text.StringBuilder
    try {
        while ($true) {
            $n = $S.Stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { return $null }
            [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
            $clean = $sb.ToString() -replace "$([char]27)\[[0-9;]*[A-Za-z]", ''
            if ($clean -match '\(qemu\) $') { return $clean }
        }
    } catch {
        return $null
    }
}

# Invoke-InputHmp SESSION COMMAND -- the monitor's answer to one line, without
# its echo and its prompt.
#
# "`n" alone ends the line: the monitor takes "`r`n" as two, and answers the
# empty second one with a prompt of its own that the next read would take for
# this command's.
function Invoke-InputHmp {
    param($S, [string]$Command)
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Command`n")
    try { $S.Stream.Write($bytes, 0, $bytes.Length) } catch { $null = $_ }
    $reply = Read-InputPrompt $S
    if ($null -eq $reply) { Die "$($S.Vm)'s QEMU monitor stopped answering at: $Command" }
    $nl = $reply.IndexOf("`n")
    $body = if ($nl -ge 0) { $reply.Substring($nl + 1) } else { '' }
    return ($body -replace '\(qemu\) $', '').Trim()
}

# Assert-InputHmp SESSION COMMAND -- Invoke-InputHmp, dying on a refusal. The
# monitor reports one as prose and every success here is silent.
function Assert-InputHmp {
    param($S, [string]$Command)
    $reply = Invoke-InputHmp $S $Command
    if ($reply -match '(?im)^\s*(Error: .*|Could not .*|could not .*|unknown .*|invalid .*|Parameter .*)$') {
        Die "$($S.Vm)'s QEMU monitor refused '$Command': $($Matches[1].Trim())"
    }
}

# qemu drops input sent to a paused guest without a word, so a paused domain is
# refused rather than "sent" to.
function Assert-InputRunning {
    param($S)
    $status = Invoke-InputHmp $S 'info status'
    if ($status -notmatch 'VM status: running') {
        Die "$($S.Vm) is not running ($($status -replace '^VM status: ', '')): qemu drops input sent to a stopped guest"
    }
}

# The tablet is what makes an absolute position mean anything. Every domain
# virutil creates has one; a launcher edited by hand may not.
function Assert-InputAbsolute {
    param($S)
    $mice = Invoke-InputHmp $S 'info mice'
    if ($mice -notmatch '\(absolute\)') {
        $list = (@($mice -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join '; ')
        Die @(
            "$($S.Vm) has no absolute pointer, so a screen position cannot be sent to it."
            "qemu lists: $(if ($list) { $list } else { 'no mouse at all' })"
            "Add '-device usb-tablet' to $(Get-DomainLauncher $S.Vm) (on the qemu-xhci"
            'or -usb bus) and restart the domain. key and type work without one.'
        )
    }
}

# Get-InputScreenSize SESSION -- @{ Width; Height } of the guest's screen now,
# from a screendump: the size the guest last set, which is what a shot PNG is.
function Get-InputScreenSize {
    param($S)
    $tmp = New-VirutilsDir $script:VirutilsTmpDir
    $token = [Guid]::NewGuid().ToString('N')
    $file = Join-Path $tmp "input-$token.png"
    try {
        $quoted = '"' + ($file -replace '\\', '\\' -replace '"', '\"') + '"'
        $reply = Invoke-InputHmp $S "screendump $quoted -f png"
        if ($reply -match '(?i)libpng|png support') {
            $file = Join-Path $tmp "input-$token.ppm"
            $quoted = '"' + ($file -replace '\\', '\\' -replace '"', '\"') + '"'
            $reply = Invoke-InputHmp $S "screendump $quoted -f ppm"
        }
        Assert-ShotWritten $S.Vm $file $reply
        if ($file.EndsWith('.png')) { return (Get-ShotPngSize $file) }
        $bytes = [IO.File]::ReadAllBytes($file)
        $head = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(64, $bytes.Length))
        $m = [regex]::Match(($head -replace '#[^\n]*\n', ''), '^P6\s+(\d+)\s+(\d+)')
        if (-not $m.Success) { Die "$($S.Vm)'s screendump is not a PPM: $file" }
        return @{ Width = [int]$m.Groups[1].Value; Height = [int]$m.Groups[2].Value }
    } finally {
        Remove-VirutilsFile $file | Out-Null
    }
}

# Open-InputPointer SESSION -- an input-barrier object in qemu, connected to a
# listener here and past the protocol's opening, held in the session.
#
# The listener takes any free loopback port: it is open only for this run and
# nothing writes it down, so the ephemeral range's reshuffles cannot reach it.
function Open-InputPointer {
    param($S)
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start()
    $S.Listener = $l
    $port = $l.LocalEndpoint.Port
    $id = "virutil-input-$PID"
    Assert-InputHmp $S "object_add input-barrier,id=$id,name=virutil,server=127.0.0.1,port=$port,width=32767,height=32767"
    $S.Object = $id

    # object_add connects before it returns, so the peer is already queued.
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while (-not $l.Pending() -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    if (-not $l.Pending()) { Die "$($S.Vm)'s qemu took the input-barrier object but never connected to it" }
    $c = $l.AcceptTcpClient()
    $c.NoDelay = $true
    $S.Barrier = $c
    $c.GetStream().ReadTimeout = 3000

    # The server speaks first: "Barrier" and a version no older than the 1.6
    # qemu's client was written against. The client answers with its own and
    # its name, and is then asked for its screen (QINF/DINF) and told it is in.
    Send-InputBarrierFrame $S ([byte[]]([Text.Encoding]::ASCII.GetBytes('Barrier') + (ConvertTo-InputBe16 1) + (ConvertTo-InputBe16 6)))
    $hello = Read-InputBarrierFrame $S
    if ([Text.Encoding]::ASCII.GetString($hello, 0, [Math]::Min(7, $hello.Length)) -ne 'Barrier') {
        Die "$($S.Vm)'s input-barrier object did not answer the protocol's hello"
    }
    Send-InputBarrier $S 'QINF'
    [void](Read-InputBarrierFrame $S)
    Send-InputBarrier $S 'CIAK'
    Send-InputBarrier $S 'CINN' ([byte[]]((ConvertTo-InputBe16 0) + (ConvertTo-InputBe16 0) + [byte[]](0, 0, 0, 1) + (ConvertTo-InputBe16 0)))
}

function ConvertTo-InputBe16 {
    param([int]$Value)
    $v = $Value -band 0xffff
    return [byte[]]@((($v -shr 8) -band 0xff), ($v -band 0xff))
}

# Send-InputBarrierFrame SESSION PAYLOAD -- one length-prefixed message. qemu
# reads a frame's payload in a single read, so each goes in one write.
function Send-InputBarrierFrame {
    param($S, [byte[]]$Payload)
    $n = $Payload.Length
    $frame = [byte[]](@(0, 0, (($n -shr 8) -band 0xff), ($n -band 0xff)) + $Payload)
    try {
        $S.Barrier.GetStream().Write($frame, 0, $frame.Length)
    } catch {
        Die "$($S.Vm)'s input-barrier connection closed mid-run: qemu disconnects on anything it cannot parse"
    }
}

function Send-InputBarrier {
    param($S, [string]$Code, [byte[]]$Payload = @())
    Send-InputBarrierFrame $S ([byte[]]([Text.Encoding]::ASCII.GetBytes($Code) + $Payload))
}

function Read-InputBarrierFrame {
    param($S)
    $stream = $S.Barrier.GetStream()
    $read = {
        param([int]$Count)
        $b = New-Object byte[] $Count; $got = 0
        while ($got -lt $Count) {
            $n = 0
            try { $n = $stream.Read($b, $got, $Count - $got) } catch { $n = 0 }
            if ($n -le 0) { Die "$($S.Vm)'s input-barrier object stopped answering" }
            $got += $n
        }
        return ,$b
    }
    $h = & $read 4
    $len = ([int]$h[0] -shl 24) -bor ([int]$h[1] -shl 16) -bor ([int]$h[2] -shl 8) -bor [int]$h[3]
    if ($len -le 0 -or $len -gt 1024) { Die "$($S.Vm)'s input-barrier object sent a frame of $len bytes" }
    return (& $read $len)
}

function Send-InputMove {
    param($S, $Size, [int]$X, [int]$Y)
    Send-InputBarrier $S 'DMMV' ([byte[]]((ConvertTo-InputBe16 (Get-InputAbs $X $Size.Width)) + (ConvertTo-InputBe16 (Get-InputAbs $Y $Size.Height))))
}

function Send-InputButton {
    param($S, [string]$Button, [bool]$Down)
    Send-InputBarrier $S $(if ($Down) { 'DMDN' } else { 'DMUP' }) ([byte[]]@($script:InputBarrierButtons[$Button]))
}

# One notch: qemu presses and releases wheel-up for a positive y, wheel-down
# for anything else. 120 is a Windows notch, though only the sign is read.
function Send-InputWheel {
    param($S, [bool]$Up)
    Send-InputBarrier $S 'DMWM' ([byte[]]((ConvertTo-InputBe16 0) + (ConvertTo-InputBe16 $(if ($Up) { 120 } else { -120 }))))
}

function Send-InputKeys {
    param($S, [string[]]$Keys, [int]$HoldMs)
    Assert-InputHmp $S "sendkey $($Keys -join '-') $HoldMs"
}

# Close-InputSession SESSION -- the object out of qemu, then every socket.
# object_del closes qemu's end; it is asked even after a failure, so a run that
# died part-way leaves nothing connected behind it.
function Close-InputSession {
    param($S)
    if ($S.Object) {
        try { [void](Invoke-InputHmp $S "object_del $($S.Object)") } catch { $null = $_ }
        $S.Object = $null
    }
    foreach ($k in @('Barrier', 'Tcp')) {
        if ($S[$k]) { try { $S[$k].Close() } catch { $null = $_ }; $S[$k] = $null }
    }
    if ($S.Listener) { try { $S.Listener.Stop() } catch { $null = $_ }; $S.Listener = $null }
}
