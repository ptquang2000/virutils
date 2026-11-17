# summarize.ps1 [-Os linux|win] -- the table: per metric, per backend, the median of the runs
# in ~\.virutils\bench\logs\OS-BACKEND-rN.json and the spread (min-max, and max-min as % of
# the median), plus KVM/WHPX as a ratio of medians. Markdown on stdout.
param([ValidateSet('linux', 'win')][string]$Os = 'linux', [string[]]$Backends = @('whpx', 'kvm'))
$logs = "$HOME\.virutils\bench\logs"
$runs = @{}
foreach ($be in $Backends) {
    $runs[$be] = @(Get-ChildItem "$logs\$Os-$be-r*.json" | ? Name -match '-r[1-9]\d*\.json$' | % { Get-Content $_ -Raw | ConvertFrom-Json })
}
$metrics = if ($Os -eq 'linux') {
    [ordered]@{
        boot_ssh_s = 'boot to ssh-ready (s), lower better'
        '7z_mips_1t' = '7-Zip b, 1 thread (MIPS)'; '7z_mips_nt' = '7-Zip b, 4 threads (MIPS)'
        sb_cpu_eps_1t = 'sysbench cpu, 1 thread (events/s)'; sb_cpu_eps_nt = 'sysbench cpu, 4 threads (events/s)'
        mem_mibs_1t = 'sysbench memory, 1 thread (MiB/s)'; mem_mibs_nt = 'sysbench memory, 4 threads (MiB/s)'
        fio_4k_randread_iops = 'fio 4k random read QD32 (IOPS)'; fio_4k_randwrite_iops = 'fio 4k random write QD32 (IOPS)'
        fio_1m_seqread_mbs = 'fio 1M sequential read QD8 (MB/s)'; fio_1m_seqwrite_mbs = 'fio 1M sequential write QD8 (MB/s)'
        net_host_to_guest_mbps = 'iperf3 Windows host -> guest (Mbit/s)'; net_guest_to_host_mbps = 'iperf3 guest -> Windows host (Mbit/s)'
        build_zstd_s = 'cold zstd build, make -j4 (s), lower better'
        shutdown_s = 'poweroff to process exit (s), lower better'
        host_cpu_pct_guest_idle = 'host CPU % while the guest idles'
    }
} else {
    [ordered]@{
        boot_ssh_s = 'boot to sshd answering (s), lower better'; boot_desktop_s = 'boot to desktop: explorer running (s), lower better'
        '7z_mips_1t' = '7-Zip b, 1 thread (MIPS)'; '7z_mips_nt' = '7-Zip b, 4 threads (MIPS)'
        mem_mibs_1t = 'memcpy bandwidth, 1 thread (MiB/s)'; mem_mibs_nt = 'memcpy bandwidth, 4 threads (MiB/s)'
        ds_4k_randread_iops = 'DiskSpd 4k random read QD32 (IOPS)'; ds_4k_randwrite_iops = 'DiskSpd 4k random write QD32 (IOPS)'
        ds_1m_seqread_mbs = 'DiskSpd 1M sequential read QD8 (MB/s)'; ds_1m_seqwrite_mbs = 'DiskSpd 1M sequential write QD8 (MB/s)'
        net_host_to_guest_mbps = 'iperf3 Windows host -> guest (Mbit/s)'; net_guest_to_host_mbps = 'iperf3 guest -> Windows host (Mbit/s)'
        build_zstd_s = 'cold zstd build, w64devkit make -j4 (s), lower better'
        shutdown_s = 'Stop-Computer to process exit (s), lower better'
        host_cpu_pct_guest_idle = 'host CPU % while the guest idles'
    }
}
function Med([double[]]$v) { $s = $v | Sort-Object; $n = $s.Count; if ($n % 2) { $s[[int][math]::Floor($n / 2)] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 } }
function Fmt([double]$x) { if ([math]::Abs($x) -ge 100) { '{0:N0}' -f $x } else { '{0:N1}' -f $x } }
$names = @{ whpx = 'QEMU/WHPX'; kvm = 'QEMU/KVM in WSL2'; kvmhv = 'QEMU/KVM in WSL2 + hv-* enlightenments' }
$others = @($Backends | ? { $_ -ne 'whpx' })
"| metric | " + (($Backends | % { "$($names[$_]) median (min-max, spread)" }) -join ' | ') + ' | ' + (($others | % { "$_ / whpx" }) -join ' | ') + ' |'
'|---|' + ('---|' * ($Backends.Count + $others.Count))
foreach ($k in $metrics.Keys) {
    $cell = @{}; $med = @{}
    foreach ($be in $Backends) {
        $v = @($runs[$be] | % { $_.$k } | ? { "$_" -match '^-?[0-9.]+$' } | % { [double]$_ })
        if ($v.Count -eq 0) { $cell[$be] = 'n/a (all stalled)'; continue }
        $m = Med $v; $med[$be] = $m
        $lo = ($v | Measure -Minimum).Minimum; $hi = ($v | Measure -Maximum).Maximum
        $sp = if ($m) { '{0:N0}%' -f (100 * ($hi - $lo) / $m) } else { '-' }
        $cell[$be] = "**$(Fmt $m)** ($(Fmt $lo)-$(Fmt $hi), $sp; n=$($v.Count))"
    }
    $ratios = $others | % { if ($med.whpx -and $med[$_]) { '{0:N2}x' -f ($med[$_] / $med.whpx) } else { '-' } }
    "| $($metrics[$k]) | " + (($Backends | % { $cell[$_] }) -join ' | ') + ' | ' + ($ratios -join ' | ') + ' |'
}
if ($Os -eq 'linux' -or $Os -eq 'win') {
    foreach ($be in $others) {
        $v = @($runs[$be] | % { $_.net_wsl_to_guest_mbps } | ? { "$_" -match '^[0-9.]+$' } | % { [double]$_ }); $w = @($runs[$be] | % { $_.net_guest_to_wsl_mbps } | ? { "$_" -match '^[0-9.]+$' } | % { [double]$_ })
        if ($v.Count) { "`n$($names[$be]), iperf3 from inside WSL (no wslrelay), per run: WSL -> guest $($v -join ', ') Mbit/s; guest -> WSL $($w -join ', ') Mbit/s." }
    }
}
"`nPer run: " + (($Backends | % { $runs[$_] } | % { "$($_.backend) r$($_.run) host_free_mb_before=$($_.host_free_mb_before) running=$($_.host_free_mb_running) host_cpu_bench=$($_.host_cpu_pct_bench)% top_other=[$($_.host_top_other_cpu_s)]" }) -join '; ')
