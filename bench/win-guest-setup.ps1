# win-guest-setup.ps1 PUBKEY -- prepare the Windows bench base (le11-vm-bench). Runs in the
# guest as SYSTEM (virutil exec) once, with the tools pushed to C:\bench\dl. Installs 7-Zip,
# Win32-OpenSSH (sshd, key auth for Administrators, PowerShell as the shell), DiskSpd,
# iperf3 and w64devkit (gcc + make, for the zstd build); opens 22 and 5201 inbound.
param([Parameter(Mandatory)][string]$PubKey)
$ErrorActionPreference = 'Stop'
$dl = 'C:\bench\dl'

Start-Process "$dl\7z2501-x64.exe" -ArgumentList '/S' -Wait
Expand-Archive "$dl\OpenSSH-Win64.zip" 'C:\Program Files' -Force
& 'C:\Program Files\OpenSSH-Win64\install-sshd.ps1' | Out-Null
Set-Service sshd -StartupType Automatic
New-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Force `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' | Out-Null
New-Item -ItemType Directory -Force C:\ProgramData\ssh | Out-Null
Start-Service sshd   # writes the host keys and default sshd_config
Set-Content C:\ProgramData\ssh\administrators_authorized_keys $PubKey -Encoding ascii
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
Restart-Service sshd

Expand-Archive "$dl\DiskSpd.zip" C:\bench\diskspd -Force
Expand-Archive "$dl\iperf3-win64.zip" C:\bench\iperf3 -Force
Start-Process "$dl\w64devkit-x64-2.11.0.7z.exe" -ArgumentList '-oC:\bench', '-y' -Wait
Copy-Item "$dl\zstd-1.5.7.tar.gz" C:\bench\

foreach ($r in @(@{n = 'bench-sshd'; p = 22 }, @{n = 'bench-iperf3'; p = 5201 })) {
    if (-not (Get-NetFirewallRule -Name $r.n -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $r.n -DisplayName $r.n -Direction Inbound -Protocol TCP -LocalPort $r.p -Action Allow | Out-Null
    }
}
Remove-Item -Recurse -Force $dl
"7z: " + (Test-Path 'C:\Program Files\7-Zip\7z.exe')
"sshd: " + (Get-Service sshd).Status
"diskspd: " + (Get-ChildItem -Recurse C:\bench\diskspd -Filter diskspd.exe | ? FullName -match 'amd64' | % FullName)
"iperf3: " + (Get-ChildItem -Recurse C:\bench\iperf3 -Filter iperf3.exe | % FullName)
"gcc: " + (Test-Path C:\bench\w64devkit\bin\gcc.exe)
