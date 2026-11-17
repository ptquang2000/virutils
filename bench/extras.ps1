# extras.ps1 -- the one-off checks beside the measured runs (le11-vm-bench), Linux guest:
#  1. coexistence: the WHPX guest and the KVM-in-WSL guest running at once, both answering ssh;
#  2. live snapshot: HMP savevm / loadvm / delvm on each (WHPX refuses; KVM needs kvm-run.sh linux-snap);
#  3. offline disk snapshot on the WHPX side: qemu-img snapshot -c / -a on the shut-off overlay.
# Prints one line per step; both guests are powered off at the end.
$ErrorActionPreference = 'Stop'
$T = $PSScriptRoot; $B = "$HOME\.virutils\bench"
$o = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=2')
function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Wait-Ssh($port) {
    $t = NowMs
    while ((NowMs) - $t -lt 600000) { & ssh @o -p $port test@127.0.0.1 true 2>$null; if ($LASTEXITCODE -eq 0) { return $true }; Start-Sleep 1 }
    $false
}

# fresh overlays, as the runs use
Remove-Item "$B\linux\run.qcow2", "$B\linux\run_VARS.fd" -ErrorAction SilentlyContinue
qemu-img create -q -f qcow2 -o cluster_size=1M -b "$B\linux\base.qcow2" -F qcow2 "$B\linux\run.qcow2"
Copy-Item "$B\linux\base_VARS.fd" "$B\linux\run_VARS.fd"
& "$T\whpx-launcher.ps1" -Name bench-u2604 -Disk "$B\linux\run.qcow2" -Vars "$B\linux\run_VARS.fd" -Ssh 10122 -Iperf 15201 -Agent 24901 -Monitor 24902 | Out-Null

# 1. coexistence
virutil domain start bench-u2604 | Out-Null
$svc = New-Object -ComObject Schedule.Service; $svc.Connect()
$null = $svc.GetFolder('\').GetTask('le11-vm-bench-kvm').Run('linux-snap')   # qcow2 UEFI vars: a raw pflash refuses savevm
$w = Wait-Ssh 10122; $k = Wait-Ssh 10222
"coexist: whpx ssh=$w kvm ssh=$k free_mb=$([int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1KB))"
foreach ($p in 10122, 10222) { "  $p load: " + (& ssh @o -p $p test@127.0.0.1 'cat /proc/loadavg') }

# 2. live snapshots
"whpx: " + ((python -I "$T\hmp.py" 24902 'savevm s1' 'info snapshots') -join ' || ')
$hmp = (wsl.exe -d le11-vm-bench -- wslpath -u "$T\hmp.py")   # this folder, as WSL sees it
"kvm:  " + ((wsl.exe -d le11-vm-bench -u root -- python3 -I $hmp 24922 'savevm s1' 'info snapshots' 'loadvm s1' 'delvm s1') -join ' || ')
"kvm ssh after loadvm: " + (Wait-Ssh 10222)
"kvm overlay after delvm: " + (wsl.exe -d le11-vm-bench -u root -- sh -c 'du -h /var/lib/bench/linux/run.qcow2 | cut -f1')

# power off both
& ssh @o -p 10122 test@127.0.0.1 'sudo poweroff' 2>$null; & ssh @o -p 10222 test@127.0.0.1 'sudo poweroff' 2>$null
$n = 0; while ((Get-CimInstance Win32_Process -Filter "Name like 'qemu-system%'") -and $n -lt 60) { Start-Sleep 2; $n++ }
$n = 0; while ((wsl.exe -d le11-vm-bench -u root -- pgrep -x qemu-system-x86) -and $n -lt 60) { Start-Sleep 2; $n++ }
"both off"

# 3. offline disk snapshot, WHPX side (the shut-off overlay)
$t = NowMs; qemu-img snapshot -c off1 "$B\linux\run.qcow2"; $c = (NowMs) - $t
$t = NowMs; qemu-img snapshot -a off1 "$B\linux\run.qcow2"; $a = (NowMs) - $t
qemu-img snapshot -d off1 "$B\linux\run.qcow2"
"whpx offline: qemu-img snapshot create ${c} ms, apply ${a} ms"
