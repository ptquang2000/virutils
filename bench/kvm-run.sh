#!/bin/sh
# kvm-run.sh OS[-hv|-snap] -- start one bench guest under QEMU/KVM in the WSL distro le11-vm-bench.
# OS is linux or win. A fresh overlay over /var/lib/bench/OS/base.qcow2 and a fresh copy of
# its UEFI vars each start, so every run boots the same disk. Same machine as the WHPX
# launcher (tools\whpx-launcher.ps1): q35, Skylake-Client, 4 vCPU, 8 GiB, OVMF from the
# Windows QEMU, virtio-blk (writeback, discard), virtio-net on user-mode net, qemu-ga;
# only -accel and the display (none here, gtk there) differ. Runs in the foreground: the
# wsl.exe that started it is what keeps the distro alive. Writes the start time (epoch ms)
# to /var/lib/bench/OS/t0. OS-hv adds the Hyper-V enlightenments libvirt gives a Windows guest; OS-snap keeps the UEFI vars in qcow2, so savevm/loadvm work (a raw pflash refuses them).
set -eu
os=${1%-hv}; os=${os%-snap}
varsfmt=raw; vars=run_VARS.fd
[ "$1" != "$os-snap" ] || { varsfmt=qcow2; vars=run_VARS.qcow2; }
cpu=Skylake-Client
[ "$1" != "$os-hv" ] || cpu=Skylake-Client,hv-relaxed,hv-vapic,hv-spinlocks=0x1fff,hv-vpindex,hv-runtime,hv-time,hv-synic,hv-stimer,hv-frequencies,hv-tlbflush,hv-ipi
d=/var/lib/bench/$os
case $os in
    linux) ssh=10222; iperf=15211; qga=24921; mon=24922 ;;
    win)   ssh=10232; iperf=15212; qga=24931; mon=24932 ;;
    *) echo "usage: kvm-run.sh linux|win" >&2; exit 2 ;;
esac
modprobe kvm_intel
rm -f "$d/run.qcow2" "$d/run_VARS.fd"
qemu-img create -q -f qcow2 -o cluster_size=1M -b "$d/base.qcow2" -F qcow2 "$d/run.qcow2"
cp "$d/base_VARS.fd" "$d/run_VARS.fd"
[ $varsfmt = raw ] || { rm -f "$d/run_VARS.qcow2"; qemu-img convert -O qcow2 "$d/run_VARS.fd" "$d/run_VARS.qcow2"; }
echo $(( $(date +%s%N) / 1000000 )) > "$d/t0"   # uutils date (26.04) has no %3N
exec qemu-system-x86_64 \
    -name "bench-$os-kvm" \
    -accel kvm \
    -machine "q35,smm=off,vmport=off" \
    -cpu "$cpu" \
    -smp "4,sockets=1,cores=4,threads=1" \
    -m 8192 \
    -drive "if=pflash,format=raw,readonly=on,file=/opt/bench/edk2-x86_64-code.fd" \
    -drive "if=pflash,format=$varsfmt,file=$d/$vars" \
    -drive "file=$d/run.qcow2,if=none,id=hd0,format=qcow2,cache=writeback,discard=unmap" \
    -device "virtio-blk-pci,drive=hd0,num-queues=4,bootindex=0" \
    -netdev "user,id=net0,hostfwd=tcp::$ssh-:22,hostfwd=tcp::$iperf-:5201" \
    -device "virtio-net-pci,netdev=net0" \
    -vga std \
    -device "qemu-xhci,id=xhci" \
    -device usb-tablet \
    -display none \
    -audiodev "none,id=snd0" \
    -chardev "socket,id=qga0,host=127.0.0.1,port=$qga,server=on,wait=off" \
    -device virtio-serial \
    -device "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0" \
    -monitor "tcp:127.0.0.1:$mon,server,nowait" \
    2> "$d/qemu.log"
