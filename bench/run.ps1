# run.ps1 -Backend whpx|kvm|kvmhv -Os linux|win -Run N [-T 20] [-Settle S]
# One measured run of a bench guest (le11-vm-bench): boot from a fresh overlay of the frozen
# base, time boot to ssh-ready (and, Windows, to the desktop), let it settle, run the
# in-guest pass (bench-linux.sh / bench-win.ps1), iperf3 host<->guest both ways, power it
# off. Writes ~\.virutils\bench\logs\OS-BACKEND-rN.json and prints it.
param(
    [Parameter(Mandatory)][ValidateSet('whpx', 'kvm', 'kvmhv')][string]$Backend,
    [Parameter(Mandatory)][ValidateSet('linux', 'win')][string]$Os,
    [Parameter(Mandatory)][int]$Run,
    [int]$T = 20, [int]$Settle = 0
)
$ErrorActionPreference = 'Stop'
$Bench  = "$HOME\.virutils\bench"
$Tools  = $PSScriptRoot
$Distro = 'le11-vm-bench'
if (-not $Settle) { $Settle = if ($Os -eq 'win') { 120 } else { 90 } }

$cfg = @{
    'whpx-linux' = @{ dom = 'bench-u2604'; ssh = 10122; iperf = 15201; agent = 24901; mon = 24902 }
    'whpx-win'   = @{ dom = 'bench-win11'; ssh = 10132; iperf = 15202; agent = 24911; mon = 24912 }
    'kvm-linux'  = @{ dom = 'bench-linux-kvm'; ssh = 10222; iperf = 15211 }
    'kvm-win'    = @{ dom = 'bench-win-kvm';   ssh = 10232; iperf = 15212 }
}["$($Backend -replace 'kvmhv','kvm')-$Os"]   # kvmhv: kvm with Hyper-V enlightenments (kvm-run.sh OS-hv)
$user = if ($Os -eq 'win') { 'test' } else { 'test' }
$sshO = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
    '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=2', '-p', "$($cfg.ssh)", "$user@127.0.0.1")
function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Sh([string]$cmd) { & ssh @sshO $cmd }
$res = [ordered]@{ backend = $Backend; os = $Os; run = $Run; started = (Get-Date -Format s) }

# --- host state before ------------------------------------------------------------------
$n = 0   # the previous run's qemu can still be exiting
do { $others = @(Get-CimInstance Win32_Process -Filter "Name like 'qemu-system%'"); if ($others) { Start-Sleep 2; $n++ } } while ($others -and $n -lt 30)
if ($others) { throw "another qemu is running: $($others.CommandLine -join ' | ')" }
$res.host_free_mb_before = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
$res.wsl_running = @(wsl.exe -l --running -q 2>$null | % { $_ -replace "`0", '' } | ? { $_.Trim() })
$cpu0 = @{}; Get-Process | % { $cpu0["$($_.Id)"] = $_.CPU }

# --- boot -----------------------------------------------------------------------------
if ($Backend -eq 'whpx') {
    $d = "$Bench\$Os"
    Remove-Item "$d\run.qcow2", "$d\run_VARS.fd" -ErrorAction SilentlyContinue
    qemu-img create -q -f qcow2 -o cluster_size=1M -b "$d\base.qcow2" -F qcow2 "$d\run.qcow2"
    Copy-Item "$d\base_VARS.fd" "$d\run_VARS.fd"
    $la = @{ Name = $cfg.dom; Disk = "$d\run.qcow2"; Vars = "$d\run_VARS.fd"; Ssh = $cfg.ssh; Iperf = $cfg.iperf
             Agent = $cfg.agent; Monitor = $cfg.mon }
    if ($Os -eq 'win') { $la.Rdp = 13399 }
    & "$Tools\whpx-launcher.ps1" @la | Out-Null
    virutil domain start $cfg.dom | Out-Null
    $q = $null; $n = 0
    while (-not $q -and $n -lt 100) {
        $q = Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64w.exe'" | ? CommandLine -match "-name $($cfg.dom) "
        if (-not $q) { Start-Sleep -Milliseconds 100; $n++ }
    }
    if (-not $q) { throw 'qemu did not start' }
    $t0 = ([DateTimeOffset]$q.CreationDate).ToUnixTimeMilliseconds()
    $qpid = $q.ProcessId
} else {
    # WMI process creation is denied on LE11 (ReturnValue 2): start it through the per-user
    # task le11-vm-bench-kvm (conhost --headless wsl.exe ... kvm-run.sh $(Arg0)), which also
    # keeps it out of this shell's job, as virutil-domain-start does for WHPX guests.
    wsl.exe -d $Distro -u root -- rm -f "/var/lib/bench/$Os/t0"
    $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
    $null = $svc.GetFolder('\').GetTask('le11-vm-bench-kvm').Run($(if ($Backend -eq 'kvmhv') { "$Os-hv" } else { $Os }))
    $t0 = $null; $n = 0
    while (-not $t0 -and $n -lt 300) {
        Start-Sleep -Milliseconds 100; $n++
        $t0 = (wsl.exe -d $Distro -u root -- cat "/var/lib/bench/$Os/t0" 2>$null)
    }
    if (-not $t0) { throw 'kvm qemu did not start' }
    $t0 = [int64]"$t0".Trim()
    $wslPid = (Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | ? CommandLine -match "kvm-run\.sh $Os").ProcessId | Select -First 1
}
$res.t0 = $t0

$ready = if ($Os -eq 'win') { 'exit 0' } else { 'true' }
$tSsh = $null; $tDesk = $null
$deadline = (NowMs) + 900000
while (-not $tSsh -and (NowMs) -lt $deadline) {
    & ssh @sshO $ready 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $tSsh = NowMs } else { Start-Sleep -Milliseconds 500 }
}
if (-not $tSsh) { throw 'no ssh in 15 min' }
$res.boot_ssh_s = [math]::Round(($tSsh - $t0) / 1000, 1)
if ($Os -eq 'win') {
    while (-not $tDesk -and (NowMs) -lt $deadline) {
        & ssh @sshO 'if (Get-Process explorer -EA 0) { exit 0 } else { exit 1 }' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $tDesk = NowMs } else { Start-Sleep -Milliseconds 500 }
    }
    $res.boot_desktop_s = [math]::Round(($tDesk - $t0) / 1000, 1)
}

# --- settle, sampling the host while the guest idles ---------------------------------------------
function Start-Sampler($file) {
    Remove-Item $file -ErrorAction SilentlyContinue
    Start-Process typeperf -ArgumentList '"\Processor(_Total)\% Processor Time" -si 2 -f CSV -y -o', "`"$file`"" `
        -WindowStyle Hidden -PassThru
}
function Stop-Sampler($p, $file) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 1
    $v = Import-Csv $file -ErrorAction SilentlyContinue | % { @($_.PSObject.Properties)[1].Value } | ? { $_ -match '^[0-9.]+$' } | % { [double]$_ }
    if ($v) { [math]::Round(($v | Measure -Average).Average, 1) } else { $null }
}
$tag = "$Os-$Backend-r$Run"
$sp = Start-Sampler "$Bench\logs\$tag-idle.csv"
Start-Sleep $Settle
$res.host_cpu_pct_guest_idle = Stop-Sampler $sp "$Bench\logs\$tag-idle.csv"

# --- the in-guest pass --------------------------------------------------------------------
$sp = Start-Sampler "$Bench\logs\$tag-bench.csv"
$cmd = if ($Os -eq 'win') { "powershell -NoProfile -ExecutionPolicy Bypass -File C:\bench\bench-win.ps1 -T $T" }
       else { "sudo T=$T /opt/bench/bench-linux.sh" }
$ssh2 = $sshO -replace '^ConnectTimeout=2$', 'ConnectTimeout=10'
$out = & ssh @ssh2 $cmd
$res.host_cpu_pct_bench = Stop-Sampler $sp "$Bench\logs\$tag-bench.csv"
foreach ($l in $out) { if ("$l" -match '^([A-Za-z0-9_]+)=(.*)$') { $res[$Matches[1]] = $Matches[2].Trim() } }
if (-not $res.done) { $res.bench_error = ($out | Select -Last 5) -join ' / ' }

# --- network: iperf3 server in the guest, client on the host -------------------------------------------
# A stalled connection hangs iperf3 for good (the KVM Windows guest did): give each test 45 s,
# then call it 'stall'. -Wsl runs the client inside the WSL distro instead of on the host.
function Get-Iperf([string[]]$a, [switch]$Wsl) {
    $job = Start-Job -ScriptBlock { param($a, $w)
        if ($w) { wsl.exe -d le11-vm-bench -- iperf3 @a -J } else { & iperf3 @a -J } } -ArgumentList $a, $Wsl.IsPresent
    if (-not (Wait-Job $job -Timeout 45)) {
        Stop-Job $job; Remove-Job $job -Force
        Get-Process iperf3 -ErrorAction SilentlyContinue | Stop-Process -Force
        if ($Wsl) { wsl.exe -d le11-vm-bench -- pkill -x iperf3 }
        return 'stall'
    }
    $o = Receive-Job $job | Out-String; Remove-Job $job -Force
    try { $j = $o | ConvertFrom-Json; [math]::Round($j.end.sum_received.bits_per_second / 1e6) } catch { 'error' }
}
if ($Os -eq 'linux') { Sh 'iperf3 -s -D' | Out-Null; $job = $null }
else { $job = Start-Job -ScriptBlock { param($o) & ssh @o 'C:\bench\iperf3\iperf3.exe -s' } -ArgumentList (, $sshO) }
Start-Sleep 2
$res.net_host_to_guest_mbps = Get-Iperf @('-c', '127.0.0.1', '-p', "$($cfg.iperf)", '-t', '10')
$res.net_guest_to_host_mbps = Get-Iperf @('-c', '127.0.0.1', '-p', "$($cfg.iperf)", '-t', '10', '-R')
if ($Backend -ne 'whpx') {   # the same, from inside WSL: no wslrelay in the path
    $res.net_wsl_to_guest_mbps = Get-Iperf @('-c', '127.0.0.1', '-p', "$($cfg.iperf)", '-t', '10') -Wsl
    $res.net_guest_to_wsl_mbps = Get-Iperf @('-c', '127.0.0.1', '-p', "$($cfg.iperf)", '-t', '10', '-R') -Wsl
}
if ($Os -eq 'linux') { Sh 'pkill iperf3' | Out-Null }
else { Sh 'Stop-Process -Name iperf3 -Force -EA 0' | Out-Null; $job | Stop-Job -PassThru | Remove-Job -Force }

# --- power off -------------------------------------------------------------------------------
$res.host_free_mb_running = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
$tOff0 = NowMs
# a busy guest can miss a 2 s connect: retry with a longer one
$offCmd = if ($Os -eq 'win') { 'Stop-Computer -Force' } else { 'sudo poweroff' }
$sshOff = $sshO -replace '^ConnectTimeout=2$', 'ConnectTimeout=15'
foreach ($try in 1..3) { & ssh @sshOff $offCmd 2>$null | Out-Null; if ($LASTEXITCODE -eq 0 -or ($LASTEXITCODE -eq 255 -and $try -gt 1)) { break }; Start-Sleep 5 }
$gone = $false; $n = 0
while (-not $gone -and $n -lt 1200) {
    Start-Sleep -Milliseconds 250; $n++
    $gone = if ($Backend -eq 'whpx') { -not (Get-Process -Id $qpid -ErrorAction SilentlyContinue) }
            else { -not (Get-Process -Id $wslPid -ErrorAction SilentlyContinue) }
}
$res.shutdown_s = if ($gone) { [math]::Round(((NowMs) - $tOff0) / 1000, 1) } else { 'timeout' }

$top = Get-Process | % { $c0 = $cpu0["$($_.Id)"]; if ($null -ne $c0 -and $_.CPU) { [pscustomobject]@{ n = $_.ProcessName; d = $_.CPU - $c0 } } } |
    ? { $_.n -notmatch '^(qemu-system|vmmem|vmmemWSL|wsl|wslhost|wslrelay|ssh|typeperf)' } | Sort d -Descending | Select -First 5
$res.host_top_other_cpu_s = ($top | % { "{0}:{1:N0}" -f $_.n, $_.d }) -join ' '
$res.finished = (Get-Date -Format s)
$res | ConvertTo-Json | Set-Content "$Bench\logs\$tag.json" -Encoding UTF8
[pscustomobject]$res
