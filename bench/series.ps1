# series.ps1 -Os linux|win [-Runs 3] [-Start 1] -- the measured runs for one guest OS, the two
# backends interleaved (whpx r1, kvm r1, whpx r2, ...) so drift over time (heat, background
# work) falls on both alike. Before each WHPX run the WSL distro is terminated, so no WSL
# guest or distro work runs beside it. One line per run to ~\.virutils\bench\logs\series-OS.log.
param([Parameter(Mandatory)][ValidateSet('linux', 'win')][string]$Os, [int]$Runs = 3, [int]$Start = 1)
$log = "$HOME\.virutils\bench\logs\series-$Os.log"
foreach ($i in $Start..$Runs) {
    foreach ($be in 'whpx', 'kvm') {
        # every run starts with the distro stopped: WSL keeps a KVM guest's 8 GB after it exits.
        # Before WHPX, also wait out the WSL VM's idle timeout so no vmmemWSL runs beside it.
        wsl.exe --terminate le11-vm-bench 2>$null | Out-Null
        Start-Sleep $(if ($be -eq 'whpx') { 75 } else { 15 })
        try {
            $r = & "$PSScriptRoot\run.ps1" -Backend $be -Os $Os -Run $i
            "$(Get-Date -Format s) $Os $be r$i ok boot=$($r.boot_ssh_s) done=$($r.done)" | Add-Content $log
        } catch {
            "$(Get-Date -Format s) $Os $be r$i FAIL $($_.Exception.Message)" | Add-Content $log
        }
    }
}
"$(Get-Date -Format s) $Os series end" | Add-Content $log
