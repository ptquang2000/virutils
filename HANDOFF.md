# Handoff: Win11 domain on a Windows host, native QEMU

Date: 2026-09-13. Host: Windows 11 Enterprise 26100, 22 logical CPUs, 32 GiB.

## What exists now

`virutil-qemu.ps1` (repo root, **untracked** -- nothing committed) is
`virutil domain create` rewritten for a Windows host. There is no libvirt
here, so there is no domain to define: it creates the qcow2 and the UEFI
nvram, writes a per-VM `.cmd` launcher, and starts it. **The launcher is the
domain** -- run it again to boot the VM.

```
.\virutil-qemu.ps1 NAME ISO [-Size 64] [-Memory MiB] [-Vcpus N]
                            [-Cpu Skylake-Client] [-Virtio PATH|none]
                            [-Port 13389:3389] [-MonitorPort 55555] [-NoStart]
```

Defaults follow the Linux original: half the host's RAM, half its CPUs capped
at 8, disk at `$VIRUTIL_IMAGE_DIR\NAME.qcow2` (default
`~\.virutils\images`), virtio-win ISO found beside the install ISO.

State for the VM created in that session:

| file | what |
|---|---|
| `~\.virutils\images\win11.qcow2` | 64 GiB disk |
| `~\.virutils\images\win11_VARS.fd` | its UEFI nvram (per-VM copy of `edk2-i386-vars.fd`) |
| `~\.virutils\images\win11.cmd` | the launcher -- run this to boot it |

The VM was left **mid-install**: Windows Setup on screen, nothing installed to
disk yet. ISO is `~\work\iso\Win11_24H2_English_x64_v2_tiny.iso`; the
virtio-win CD (`virtio-win-0.1.285.iso`) is attached as a second drive.

## Picking up where it stopped

1. `~\.virutils\images\win11.cmd` -- boots to Windows Setup.
2. At *"Where do you want to install"* the disk is **missing** until
   **Load driver -> virtio-win CD -> `amd64\w11`**. virtio-blk has no
   inbox driver.
3. After install: virtio-net needs the same treatment (Device Manager, or run
   `virtio-win-guest-tools.exe` off the CD).
4. RDP reaches it at `localhost:13389` (`mstsc /v:localhost:13389`). User-mode
   NAT: that forward is the only way in from the host.

## The four things that differ from Linux virutil, and why

Each was bisected against this host, not guessed. Do not "fix" them back.

| `domain create` on Linux | here | why |
|---|---|---|
| `--cpu host-passthrough` | `-cpu Skylake-Client` | under WHPX, `host` **and** `max` hang OVMF in `CpuMpPei` -- no display output, ever. Every *named* model boots. Skylake-Client is the oldest one carrying the SSE4.2/POPCNT/AES that Win11 requires. |
| `topology.threads=2` | `threads=1` | an SMT topology hangs MP init identically, at any vcpu count. Cores only. |
| `cache=none,io=io_uring` | `cache=writeback` | on Windows `cache=none` opens the image unbuffered and qemu then cannot read its own qcow2 header back: *"Image is not in qcow2 format"*. io_uring is Linux-only. |
| `--video virtio` | `-vga std` | virtio-vga never brought the display up under WHPX, and Setup has no virtio-gpu driver regardless. |

Not config differences, but gone and not worked around: **kvm** (whpx instead,
so none of the hyperv enlightenments -- expect an idle guest to cost more host
CPU than under kvm), **swtpm** (fine for this debloated ISO; a stock Win11 ISO
would stop at *"This PC can't run Windows 11"*), and the **libvirt network**.

## Two traps worth knowing

- **The boot prompt.** Windows Setup boots from CD only if a key is pressed at
  *"Press any key to boot from CD"*. Unanswered, the firmware falls through to
  the UEFI shell -- which looks exactly like a hang if you are reading a
  screenshot. The launcher opens a QEMU monitor on `127.0.0.1:55555` and the
  script spams `sendkey ret` over it for the first ~28s.
- **Diagnosing a black window.** `-debugcon file:ovmf.log -global
  isa-debugcon.iobase=0x402` gets OVMF's own log out. A boot that reaches the
  EFI shell writes ~110 KB; one that hangs in MP init stops at ~7.8 KB with
  `CpuMpPei: 5-Level Paging = 0` as the last line. That size difference is how
  all four findings above were bisected.

## Not done

- Nothing committed, no tests, no README change. `virutil-qemu.ps1` and this
  file are the only additions.
- Only `create` was ported. No Windows equivalent of `domain
  delete/start/list/port`, and none of the other modules (sync, snapshot,
  guest, usb, xfer) -- they are all `virsh`-driven.
- `-Port` is create-time only; changing a forward means editing the `.cmd`.
- The qemu monitor is left open on a fixed port; two VMs at once need
  different `-MonitorPort`.
