# bench: WHPX against KVM in WSL2, on one Windows host

The scripts behind the README's
[WHPX or KVM in WSL2 on a Windows host](../README.md#whpx-or-kvm-in-wsl2-on-a-windows-host)
(2026-11-18). Rerun them when that choice is worth asking again: a new WSL kernel
or QEMU, another host, or a Linux guest that would move to KVM.

They are not part of `virutil`. Each run boots a fresh qcow2 overlay of a frozen
base disk on one backend, times boot to ssh, measures in the guest, runs iperf3 from
the host and powers the guest off. Both backends get the same machine: q35,
Skylake-Client, 4 vCPU, 8 GiB, OVMF, virtio-blk `cache=writeback`, virtio-net on
user-mode networking. Only one guest runs at a time.

| file | runs on | does |
|---|---|---|
| `series.ps1 -Os linux\|win [-Runs 3]` | Windows host | the measured series, backends interleaved (WHPX r1, KVM r1, WHPX r2, ...); stops the distro before each run |
| `run.ps1 -Backend whpx\|kvm\|kvmhv -Os linux\|win -Run N` | Windows host | one run; writes `~\.virutils\bench\logs\OS-BACKEND-rN.json`. `kvmhv` is KVM with the Hyper-V enlightenments |
| `summarize.ps1 -Os linux\|win [-Backends whpx,kvm,kvmhv]` | Windows host | the table from those JSON files: median, min–max and spread per metric, KVM ÷ WHPX |
| `whpx-launcher.ps1` | Windows host | writes a virutil launcher (`~\.virutils\images\NAME.cmd`) for a bench disk, so `virutil domain start` runs it under WHPX |
| `kvm-run.sh OS[-hv\|-snap]` | the WSL distro, as root | starts the same guest under KVM, in the foreground; `-snap` keeps the UEFI vars in qcow2 so `savevm` works |
| `bench-linux.sh` | Linux guest, root | 7-Zip, sysbench cpu and memory, fio, a cold zstd build; `KEY=VALUE` lines |
| `bench-win.ps1` | Windows guest, elevated | 7-Zip, `memband`, DiskSpd, a cold zstd build with w64devkit |
| `memband.c` | Windows guest | memcpy bandwidth (`winsat mem` needs a D3D device and fails over ssh) |
| `win-guest-setup.ps1 PUBKEY` | Windows guest, SYSTEM | prepares the Windows base: OpenSSH with key auth, 7-Zip, DiskSpd, iperf3, w64devkit, firewall |
| `extras.ps1` | Windows host | one-off checks: both backends at once, live `savevm`/`loadvm` timing, an offline `qemu-img snapshot` |
| `hmp.py PORT CMD...` | host or distro | sends monitor commands and times each |

## Before a run

What the scripts take as given, set up by hand once:

- **Bases.** A copy of each guest disk, prepared once (packages above; timers,
  updates and snap refreshes off; an ssh key for user `test`) and then left alone, with
  its UEFI vars, at `~\.virutils\bench\{linux,win}\base.qcow2` and `base_VARS.fd`;
  and a byte-identical copy at `/var/lib/bench/{linux,win}/` in the distro. Linux
  guest: `/opt/bench/bench-linux.sh` and `zstd-1.5.7.tar.gz`. Windows guest:
  `C:\bench\` with `bench-win.ps1`, `memband.exe`, `diskspd`, `iperf3`, `w64devkit` and
  the zstd tarball.
- **The distro.** `wsl --install Ubuntu-26.04 --name le11-vm-bench`, then apt
  `qemu-system-x86 qemu-utils iperf3`; the Windows QEMU's `edk2-x86_64-code.fd` copied
  to `/opt/bench/`. `kvm-run.sh` loads `kvm_intel` itself.
- **The task.** WMI process creation can be denied, and the `wsl.exe` running qemu has
  to outlive the script, so KVM guests start through a per-user scheduled task
  `le11-vm-bench-kvm`: action `conhost.exe --headless wsl.exe -d le11-vm-bench -u root
  -- sh <this folder in WSL>/kvm-run.sh $(Arg0)`, multiple instances allowed; `run.ps1`
  passes the OS as its argument.
- **A quiet host.** Every other VM off (`series.ps1` terminates only its own distro)
  and no build running, for the whole series.
- **iperf3** on the Windows host (`scoop install iperf3`).

Remove it all afterwards: `wsl --unregister le11-vm-bench` (the `ext4.vhdx` never
shrinks), the task, the `bench-*` launchers in `~\.virutils\images` and
`~\.virutils\bench\`.
