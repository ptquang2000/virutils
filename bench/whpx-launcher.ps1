# whpx-launcher.ps1 NAME DISK VARS -Ssh PORT -Agent PORT -Monitor PORT [-Cpu 4] [-MemMB 8192] [-NoNet] [-Cache writeback|none]
# Writes ~\.virutils\images\NAME.cmd: a virutil domain in the shape `virutil domain create`
# makes (q35, Skylake-Client, OVMF, virtio-blk, virtio-net on user-mode net, qemu-ga),
# pointed at a bench disk, with the bench's vCPU/RAM and forwards for ssh, iperf3 (5201)
# and RDP. virutil domain start/shutdown/exec/push then work on it; delete the .cmd at the end.
param(
    [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Disk, [Parameter(Mandatory)][string]$Vars,
    [Parameter(Mandatory)][int]$Ssh, [Parameter(Mandatory)][int]$Agent, [Parameter(Mandatory)][int]$Monitor,
    [int]$Iperf = 0, [int]$Rdp = 0, [int]$Cpu = 4, [int]$MemMB = 8192, [switch]$NoNet,
    [ValidateSet('writeback', 'none')][string]$Cache = 'writeback'
)
$img  = "$HOME\.virutils\images"
$qemu = "$HOME\scoop\apps\qemu\current"
$fwd = "hostfwd=tcp::$Ssh-:22"
if ($Iperf) { $fwd += ",hostfwd=tcp::$Iperf-:5201" }
if ($Rdp)   { $fwd += ",hostfwd=tcp::$Rdp-:3389" }
$net = if ($NoNet) { '    -nic none ^' } else { @(
    "    -netdev `"user,id=net0,$fwd`" ^"
    '    -device "virtio-net-pci,netdev=net0" ^') -join "`r`n" }
$text = @"
@echo off
rem virutil domain: $Name -- regenerate with: virutil domain create $Name <iso>
rem This file is the domain. virutil reads the monitor port and the port
rem forwards back out of it; edit it by hand and virutil follows the edit.
rem le11-vm-bench: written by bench\whpx-launcher.ps1; delete when the bench ends.
start /b "" "$qemu\qemu-system-x86_64w.exe" ^
    -name $Name ^
    -accel whpx ^
    -machine "q35,smm=off,vmport=off" ^
    -cpu Skylake-Client ^
    -smp "$Cpu,sockets=1,cores=$Cpu,threads=1" ^
    -m $MemMB ^
    -drive "if=pflash,format=raw,readonly=on,file=$qemu\share\edk2-x86_64-code.fd" ^
    -drive "if=pflash,format=raw,file=$Vars" ^
    -drive "file=$Disk,if=none,id=hd0,format=qcow2,cache=$Cache,discard=unmap" ^
    -device "virtio-blk-pci,drive=hd0,num-queues=$Cpu,bootindex=0" ^
$net
    -vga std ^
    -device "qemu-xhci,id=xhci" ^
    -device usb-tablet ^
    -display gtk ^
    -audiodev "none,id=snd0" ^
    -debugcon file:$img\$Name-ovmf.log ^
    -global isa-debugcon.iobase=0x402 ^
    -chardev "socket,id=qga0,host=127.0.0.1,port=$Agent,server=on,wait=off" ^
    -device virtio-serial ^
    -device "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0" ^
    -monitor "tcp:127.0.0.1:$Monitor,server,nowait" ^
    2> "$img\$Name-qemu.log"
"@
Set-Content -LiteralPath "$img\$Name.cmd" -Value $text -Encoding ascii
"wrote $img\$Name.cmd"
