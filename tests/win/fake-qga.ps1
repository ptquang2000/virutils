<#
.SYNOPSIS
  A stand-in qemu-ga behind a stand-in qemu chardev, for tests/win/agent.ps1.

.DESCRIPTION
  What it copies is what made two virutil runs collide on a real domain
  (docs/qga-multi-client.md): one client at a time, a listen backlog of 1, the
  requests answered strictly in order, and a reply whose client has gone
  delivered to whoever connects next rather than thrown away. It answers
  guest-sync-delimited behind an 0xFF the way qemu-ga does, drops a partial
  request at an 0xFF, and echoes "id" -- or, with -RejectId, refuses a request
  that carries one, as virtio-win's qemu-ga 7.6.2 does.

  Commands: guest-sync-delimited, guest-sync, guest-ping, guest-info,
  guest-get-osinfo, guest-exec / guest-exec-status (the "output" is the argv,
  joined), and two of its own: guest-echo returns its arguments, and guest-slow
  returns them after arguments.ms.

    fake-qga.ps1 -Port N [-RejectId] [-StaleOnConnect N] [-BootDelayMs N] [-Log FILE]

  -StaleOnConnect writes N replies nobody asked for to each new client, before
  reading anything: the leftovers of a client that left early. -BootDelayMs
  reads nothing at all for that long after starting, as an agent that is not up
  yet. -Log appends one line per accepted connection.
#>
param(
    [Parameter(Mandatory)][int]$Port,
    [switch]$RejectId,
    [int]$StaleOnConnect = 0,
    [int]$BootDelayMs = 0,
    [string]$Log = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
$listener.Start(1)
if ($Log) { Add-Content -LiteralPath $Log -Value 'ready' }
$clock = [Diagnostics.Stopwatch]::StartNew()
$procs = @{}
$nextPid = 1000
$carry = New-Object Collections.Generic.List[byte[]]

# A write to a peer that has closed usually "succeeds" into a dead socket, so
# the peer is asked first: readable with nothing to read is a closed peer.
function Out-Reply {
    param($Stream, [string]$Json, [switch]$Delimited)
    $b = [Text.Encoding]::UTF8.GetBytes($Json + "`n")
    if ($Delimited) { $b = @([byte]0xFF) + $b }
    $gone = $false
    try {
        $gone = $script:client.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead) -and $script:client.Available -eq 0
    } catch { $gone = $true }
    if (-not $gone) {
        try { $Stream.Write($b, 0, $b.Length); $Stream.Flush(); return } catch { }
    }
    # The client has gone. qemu would hand this to the next one.
    $carry.Add($b)
}

function Get-Answer {
    param($Req)
    $names = $Req.PSObject.Properties.Name
    $a = if ($names -contains 'arguments') { $Req.arguments } else { $null }
    switch ($Req.execute) {
        'guest-sync'       { return @{ return = $a.id } }
        'guest-ping'       { return @{ return = @{} } }
        'guest-info'       { return @{ return = @{ version = 'fake' } } }
        'guest-get-osinfo' { return @{ return = @{ id = 'mswindows' } } }
        'guest-echo'       { return @{ return = $a } }
        'guest-slow'       { Start-Sleep -Milliseconds ([int]$a.ms); return @{ return = $a } }
        'guest-exec' {
            $script:nextPid++
            # Exited after a poll or two, so a caller has to poll.
            $procs[$script:nextPid] = @{ Text = (@($a.arg) -join ' '); Polls = ($script:nextPid % 3) }
            return @{ return = @{ pid = $script:nextPid } }
        }
        'guest-exec-status' {
            $p = [int]$a.pid
            if (-not $procs.ContainsKey($p)) {
                return @{ error = @{ class = 'GenericError'; desc = "Invalid parameter 'pid'" } }
            }
            if ($procs[$p].Polls -gt 0) { $procs[$p].Polls--; return @{ return = @{ exited = $false } } }
            $out = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($procs[$p].Text + "`r`n"))
            $procs.Remove($p)
            return @{ return = @{ exited = $true; exitcode = 0; 'out-data' = $out } }
        }
        default { return @{ error = @{ class = 'CommandNotFound'; desc = "The command $($Req.execute) has not been found" } } }
    }
}

while ($true) {
    $script:client = $listener.AcceptTcpClient()
    if ($Log) { Add-Content -LiteralPath $Log -Value "connect $($clock.ElapsedMilliseconds)" }
    $s = $script:client.GetStream()
    foreach ($b in @($carry)) { try { $s.Write($b, 0, $b.Length) } catch { } }
    $carry.Clear()
    for ($i = 0; $i -lt $StaleOnConnect; $i++) {
        Out-Reply $s ('{"return": {"stale": ' + $i + '}, "id": 77' + $i + '}')
    }
    $line = New-Object IO.MemoryStream
    $buf = New-Object byte[] 4096
    while ($true) {
        $wait = $BootDelayMs - $clock.ElapsedMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([Math]::Min($wait, 200)); continue }
        $n = 0
        try { $n = $s.Read($buf, 0, $buf.Length) } catch { $n = 0 }
        if ($n -le 0) { break }
        for ($k = 0; $k -lt $n; $k++) {
            $c = $buf[$k]
            if ($c -eq 0xFF) { $line.SetLength(0); continue }
            if ($c -ne 0x0A) { $line.WriteByte($c); continue }
            $text = [Text.Encoding]::UTF8.GetString($line.ToArray())
            $line.SetLength(0)
            if (-not $text.Trim()) { continue }
            $req = $null
            try { $req = $text | ConvertFrom-Json } catch { }
            if ($null -eq $req -or -not ($req.PSObject.Properties.Name -contains 'execute')) {
                Out-Reply $s '{"error": {"class": "GenericError", "desc": "Invalid JSON syntax"}}'
                continue
            }
            if ($req.execute -eq 'guest-sync-delimited') {
                Out-Reply $s ('{"return": ' + $req.arguments.id + '}') -Delimited
                continue
            }
            $hasId = $req.PSObject.Properties.Name -contains 'id'
            if ($RejectId -and $hasId) {
                Out-Reply $s '{"error": {"class": "GenericError", "desc": "QMP input object member ''id'' is unexpected"}}'
                continue
            }
            $ans = Get-Answer $req
            if ($hasId) { $ans['id'] = $req.id }
            Out-Reply $s ($ans | ConvertTo-Json -Depth 10 -Compress)
        }
    }
    try { $script:client.Close() } catch { }
}
