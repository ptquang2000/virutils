# The virutil contract

virutil ships as two programs: `virutil`, a bash driver for a Linux host
(libvirt/KVM), and `virutil.ps1`, a PowerShell driver for a Windows host (raw
QEMU under WHPX). They share no source. This file is what they do share -- the
observable surface a user and a script may rely on, identically, on either host.

A change to anything below is a change to both implementations or it is a bug.
Anything *not* below is each implementation's own business: how it talks to the
hypervisor, how it serves a payload, what it shells out to.

## 1. The two axes

Keep them apart; conflating them is how the fork rots.

- **Host axis.** What the driver runs on. This is the fork. libvirt/virsh,
  smbd, `ip`/`ss`, `sudo` on one side; qemu-system-x86_64.exe, `New-SmbShare`,
  `Get-NetIPAddress` on the other.
- **Guest axis.** What is on the other side of the transfer, keyed on the
  guest's OS, *not* the host's. A Windows guest fetches with robocopy over SMB;
  a Linux guest fetches with rsync. This axis is identical in both
  implementations and its payloads are shared as data (section 6).

## 2. Command grammar

The full observable CLI. Flags are long-and-short as written; `-h`/`--help` on
every module, exit 0 for an asked-for help and 1 for a usage error.

```
virutil domain create   VM ISO [-s GiB] [-m MiB] [-c N] [-o ID] [-v ISO|none]
                               [-p SPEC] [-N]            # Windows host only
virutil domain delete   VM
virutil domain list
virutil domain start    VM [-s GiB] [-m MiB] [-c N] [-G]
virutil domain shutdown VM
virutil domain addr     VM
virutil domain port     VM [PORT | HOSTPORT:GUESTPORT] [-c PORT]

virutil snapshot create VM [SNAP]        # default snap-<timestamp>
virutil snapshot list   VM
virutil snapshot revert VM SNAP
virutil snapshot delete VM SNAP

virutil sync VM [-c NAME|PATH]
virutil push VM SRC DST
virutil pull VM SRC DST

virutil exec {ping|cmd|ps|sh} VM [-d] [--] [CMD...|-]

virutil ui  {setup|run} VM [ARGS]

virutil usb {list|show|attach|detach} [VM] [VENDOR:PRODUCT]
```

`usb` is on both drivers and holds to one grammar over two mechanisms -- a
libvirt `<hostdev>` on the bash side, `device_add` over the QEMU monitor on the
Windows one. What is on neither is the WSL case, where the device is plugged
into Windows and the domain is inside the Linux kernel's view: getting it across
is a `usbipd` recipe in the README rather than a command. See section 7.

`domain create -p SPEC` (a port forward, repeatable) and `-N` (create without
starting) exist on the Windows driver only, and are marked as such above. They
are in this section rather than buried in section 9 because a reader working out
what a command line means should not have to find them somewhere else -- but a
script using them is a script for one host. Everything else above is both
drivers'. Section 9 says what each flag *does* where the two cannot agree.

Invariants that are contract, not implementation:

- `push`/`pull`/`sync` require the domain **running**; delivery goes over the
  guest's own network and touches neither the disk image nor guest uptime.
- `SRC`/`DST` guest paths are relative to the guest root -- `C:\` on Windows,
  `/` on Linux. Backslashes and a `C:\` prefix are tolerated; `..` is refused.
  A trailing slash means a directory, as with rsync.
- `pull` wildcards match with the *guest's* own matching: case-insensitive on
  Windows, case-sensitive on Linux.
- `domain delete` never prompts and removes disks, backing chain, snapshot
  overlays and memory files, mount points and port forwards; files another
  domain uses are kept.
- `snapshot delete` takes SNAP's descendants with it and commits no disk data.
- A running domain snapshots memory too; a shut-off one is disk-only.
- `exec` runs as SYSTEM (Windows) / root (Linux) and the guest's exit code
  becomes virutil's.
- The disk is always `<image dir>/VM.qcow2`.

## 3. State layout

One root, everything under it, one variable relocates the lot.

| path | holds |
|---|---|
| `<root>/conf` | sync configs, looked up here first |
| `<root>/images` | domain disks, snapshot overlays, memory files, UEFI nvram, and -- Windows host only -- the per-VM `.cmd` launcher and its OVMF log |
| `<root>/staging` | sync's incremental staging trees |
| `<root>/ports` | port-forward state and logs |
| `<root>/mnt` | host mount points for guest filesystems |
| `<root>/tmp` | transfer payload scratch |
| `<root>/cache` | third-party tools fetched once (PsExec) |

Root is `~/.virutils` on Linux and `%USERPROFILE%\.virutils` on Windows. The
staging tree must survive a reboot -- this is why it is not an XDG/`%TEMP%`
directory.

Every driver knows the whole layout and relocates it from the same variables,
but a driver only creates the directories it actually writes to. The Windows
driver currently writes to `images` alone: `conf`, `staging`, `tmp` and `mnt`
belong to `sync`, `push` and `pull`, which are not ported there yet, and `ports`
holds the relay state and logs of a mechanism it does not have -- under
user-mode NAT a forward is a `hostfwd` on the qemu command line, so it lives in
the launcher with every other qemu argument and needs no state of its own.
`cache` follows `ui`. **An empty directory is not a promise**: what section 3
fixes is where a thing goes when there is one, not that every driver puts
something in each.

## 4. Environment

**The prefix is `VIRUTILS_`, plural, for every variable either driver reads.**

This was open, and it was a real bug rather than a matter of taste:
`modules/paths` spelled the roots `VIRUTILS_*`, `modules/domain` read
`VIRUTIL_IMAGE_DIR` (singular) *in preference to it*, and the first draft of the
PowerShell driver followed the singular -- so one config pointed the two drivers
at two different directories. Settled: plural everywhere, and the singular is
still read, second, with a one-line deprecation note. Both drivers do this, in
`modules/paths` and `modules/paths.ps1`, and neither will stop reading the old
spelling.

| variable | meaning |
|---|---|
| `VIRUTILS_DIR` | the root; moves everything at once |
| `VIRUTILS_{CONF,IMAGE,PORT,TMP,CACHE}_DIR`, `VIRUTILS_{STAGING,MNT}_ROOT` | move one piece |
| `VIRUTILS_OSINFO` | fallback osinfo id when the ISO is not recognised |
| `VIRUTILS_VIRTIO` | virtio-win ISO path, or `none` |
| `VIRUTILS_NETWORK` | guest NIC spec |
| `VIRUTILS_FIRMWARE` | `uefi` (default) or `bios` |

The last three have no meaning on a Windows host -- there is no libosinfo, no
libvirt network, and WHPX will not boot Windows 11 without UEFI -- so that
driver reads them, says they are ignored, and carries on. A variable being in
this table means both drivers must *accept* it, not that both can act on it.

## 5. Exit codes

0 success, 1 usage or a plain failure, and these specific ones, which callers
match on:

| code | meaning |
|---|---|
| 90 | the guest has no rsync |
| 92 | mkdir failed in the guest (push) |
| 93 | robocopy failed, exit >= 8 (push) |
| 94 | SRC matched nothing in the guest (pull) |
| 95 | robocopy failed, exit >= 8 (pull) |
| 97 | PsExec is not present in the guest (ui) |

Otherwise the guest's own exit code passes through (`exec`).

## 6. Shared payloads

The scripts virutil sends *into* a guest are keyed on the guest OS, so they are
byte-identical under both drivers. They live in `payloads/` as data that each
implementation reads and interpolates -- not as code in either language:

```
payloads/probe.sh       Linux guest    refuse early when the guest has no rsync
payloads/push-dir.ps1   Windows guest  robocopy a served tree into a directory
payloads/push-file.ps1  Windows guest  Copy-Item one served file onto a path
payloads/push-dir.sh    Linux guest    rsync a served tree into a directory
payloads/push-file.sh   Linux guest    rsync one served file onto a path
payloads/pull.ps1       Windows guest  robocopy matches of a pattern out
payloads/pull.sh        Linux guest    rsync matches of a pattern out
payloads/sync.ps1       Windows guest  robocopy the whole share onto C:\
payloads/sync.sh        Linux guest    rsync the whole export onto /
```

Nine files rather than the five this section first guessed at, because push
needs two shapes on each side: robocopy cannot rename onto a new name, so a
single file goes through Copy-Item, and the rsync side is split to match rather
than to differ.

### The placeholder grammar

A driver reads one of these and substitutes two kinds of hole, and nothing else:

| form | meaning |
|---|---|
| `@NAME@` | a value, interpolated as a **quoted string literal** in the payload's own language. The driver quotes; the payload never carries its own quotes around one of these. |
| `@@NAME@@` | raw text: the exit codes in section 5, and `@@PROBE@@`, which expands to the whole of `probe.sh`. |

Rules both drivers keep:

- Comment-only and blank lines are stripped at render time. A PowerShell payload
  is base64'd as UTF-16LE onto a command line Windows caps at 32767 characters,
  and an sh payload travels as one argv entry Linux caps at 128KB; the budget is
  for the transfer, not for the prose.
- A hole left unfilled is refused. An unsubstituted `@DST@` reaching a guest
  fails there in a way that reads as an unrelated error.
- A *value* containing something spelled like a placeholder is refused too. One
  renderer fills the holes in a single pass and the other one at a time, so such
  a value would be rescanned by one and not the other; refusing in both is what
  keeps them provably identical for every input either accepts.

This is the only code the two implementations share, and it is the most
carefully bisected code in the repo -- robocopy's exit code is a bitmap, not an
error level; robocopy always takes a source *directory*, so a file is named as
a filter on its parent. Keep it in one place. `tests/payloads.sh` and
`tests/payloads.ps1` render all nine under both drivers and diff the result
against one golden file, which is what makes "byte-identical" a fact rather than
an intention.

## 7. Scope

Not every module ports. The Windows driver is complete at:

`domain`, `sync`, `push`, `pull`, `exec` -- and `snapshot`, which has now been
weighed and does not earn it yet (below). Four modules that work beat ten
half-ported.

**Where it actually is:** `domain` and `exec` are ported, and the guest agent
channel they both stand on is in place. `sync`, `push` and `pull` are not, and
they are blocked on one unanswered question rather than on effort -- see
"The transfer layer" below. `snapshot` and `ui` are bash-only. `usb` is on
both, and was the last thing to become so.

### `snapshot`: not yet, and the criterion for changing that

This was left open as "does `snapshot` port, or is the Windows driver four
modules?". The answer is **four modules for now**, and the reason is not effort.

Half of `snapshot` ports almost for free: the overlay chain is policy and
`qemu-img` is the platform, so `create`, `delete` and the chain walk are the
same work on either host. The other half does not. Section 2 says "a running
domain snapshots memory too; a shut-off one is disk-only", and memory is
libvirt's `snapshot-create` doing a managed save -- on a raw QEMU host that is
`migrate "exec:..."` or `savevm` over the monitor, against a WHPX guest, with
`revert` having to put the domain back afterwards. That is a new mechanism with
its own failure modes, not a port.

Shipping only the disk half would be worse than shipping nothing: `snapshot
create` on a running domain would silently mean something different on the two
hosts, and a snapshot that quietly did not capture memory is the kind of thing
found out at `revert`.

**Port it when** the memory half has an answer that has been tested against a
running guest -- or when section 2 is changed to say that snapshots are
disk-only on a Windows host, which is a contract change and needs to be made
deliberately rather than arrived at.

`ui` (PsExec) ports: it is Windows-*guest*-only, but host-portable -- it
delivers over the same transport as `push`, which means smbd on a Linux host
and `New-SmbShare` on a Windows one.

### The transfer layer, and what is not settled about it

`sync`, `push` and `pull` all deliver the same way: **the host serves a tree and
the guest fetches it.** That direction is not an implementation detail and must
not be inverted. Under user-mode NAT the host cannot open a connection to the
guest at all, but the guest can always reach the host at `10.0.2.2` -- the
architecture happens to be exactly what slirp allows.

The plan for the Windows host is to collapse both guest OSes onto SMB, since
Windows *is* an SMB server natively (`New-SmbShare`, no smbd to install, no
privileged-port dance) and a Linux guest can `mount -t cifs` and rsync against
the mount. The guest-side split survives untouched; only what the guest mounts
changes. That deletes the whole samba and rsyncd half of `modules/xfer`.

**The open question is authentication, and it has no answer yet.** The bash
driver's smbd is configured `map to guest = Bad User` with `guest ok = yes`, so
the guest fetches with no credential at all. Windows' own SMB server has no
equivalent that is on by default: the `Guest` account is disabled, and since
Windows 10 1709 the SMB *client* refuses insecure guest logons as well -- so a
Windows guest would decline the share even if the host offered it. Every way
out costs something:

- a throwaway local account per transfer, created and deleted around it. Needs
  Administrator and puts account churn on the host for every push.
- the invoking user's own credential, handed to the guest in the payload. Puts
  a real password into a script sent over a virtio channel; not acceptable.
- re-enabling guest logons on both sides. Turns off a protection the host has
  for reasons that have nothing to do with virutil.

This is written down rather than guessed at because picking wrong here is a
security decision, not a plumbing one. **Verify the client-side refusal against
the actual guest before designing around it** -- it is stated here from
documented Windows defaults, not from a measurement on this host.

**`usb` is one grammar over two mechanisms, and the WSL case is not a command
at all.** There used to be a bash `usb` module that drove `usbipd.exe` on the
Windows side, `vhci_hcd` in the WSL kernel to receive the import, and `virsh
attach-device` to hand the result to the domain. It was three moving parts held
together by facts about one WSL setup -- a hardcoded distro name, the import
address read off `eth0` -- and only the last of the three was about USB
passthrough at all.

What replaced it is the same four verbs on each driver, each carrying them the
way its own host does:

| | bash driver | Windows driver |
| --- | --- | --- |
| attach | `virsh attach-device` with a `<hostdev>` | `device_add usb-host` over the QEMU monitor |
| detach | `virsh detach-device` | `device_del` |
| persists in | the domain's XML (`--config`) | the `.cmd` launcher |
| host devices | sysfs | Win32 PnP |

That is the host axis of section 1 doing exactly what it is for: the grammar
and the naming are the contract, and the plumbing under them is the fork.

The usbipd round trip did not survive the split and should not be added back to
either driver. On a WSL host the device is on the Windows side of the kernel
boundary, so `virutil usb list` in WSL is empty until usbipd hands a device
over -- and once it has, the ordinary bash `attach` takes it from there, because
by then it is just a device in sysfs. That is the whole seam: usbipd puts the
device in front of the Linux kernel, and virutil passes a device the kernel can
see through to a guest. The README documents the first half as a recipe.

Three things hold across both drivers and are part of the contract, not of
either implementation:

- **A device is named by `VENDOR:PRODUCT`, lowercase hex, never by a bus path.**
  Both qemu and libvirt accept a bus/port address, and it is the more precise of
  the two, but it names a *port* -- it changes when the device moves sockets.
  The old module's busids were the single most common way to get that wrong.
- **An attach is live and persistent at once**, so a device attached once is
  still attached after the next boot, and a detach removes both. `domain port`
  works the same way for the same reason.
- **What it takes for the device to actually arrive is the host's business.**
  libvirt with `managed='yes'` detaches it from the host driver itself; qemu on
  Windows goes through libusb, which cannot open a device a Windows class driver
  owns, so it needs UsbDk or WinUSB. Only the second one has to be said out
  loud, and it is, in `virutil usb -h` and the README.

One asymmetry is real and is in the XML: the bash driver writes
`startupPolicy='optional'` on a persisted hostdev, because libvirt otherwise
refuses to start a domain whose passed-through device is unplugged. qemu just
waits for the device, so the Windows driver has nothing to set.

## 8. Conformance

A test that drives both drivers against a real guest and diffs the observable
behaviour is worth more than any shared library, because there is no shared
library. At minimum: every `--help` exits 0; every usage error exits 1; `push`
then `pull` round-trips a tree byte-for-byte; a second `push` of an unchanged
tree moves nothing; `exec` propagates a non-zero guest exit code; `domain
create` leaves exactly the files section 3 says it does.

`tests/conformance.sh` runs the part of that which needs no guest, against both
drivers:

| | |
|---|---|
| `tests/conformance.sh` | the runner. Every `--help` exits 0, every usage error exits 1, in both drivers; drives the two below. |
| `tests/payloads.sh`, `tests/payloads.ps1` | render all nine payloads under each driver and diff both against `tests/golden/payloads.txt`. This is what makes section 6's "byte-identical" checkable. |
| `tests/domain.ps1` | the launcher round trip: monitor port, agent channel and port forwards written, read back, edited and read again. |

The PowerShell half skips itself, loudly, on a host with no `pwsh`.

**Still missing, and named so it is not mistaken for covered:** everything that
needs a running guest with an agent in it -- the `push`/`pull` round trip, the
second `push` moving nothing, `exec` propagating an exit code, and `domain
create` leaving exactly the files section 3 names.

## 9. Host-specific behaviour that is *not* contract

Documented so nobody "fixes" one driver to match the other. See `HANDOFF.md`
for how each was bisected on the Windows host: `-cpu Skylake-Client` rather
than host-passthrough, `threads=1` rather than an SMT topology,
`cache=writeback` rather than `cache=none,io=io_uring`, `-vga std` rather than
virtio. No kvm (WHPX instead, so no hyperv enlightenments), no swtpm, no
libvirt network.

### Where the grammar bends, and why

Four places, each because the host cannot mean what the other one means.

A flag or command in section 2 always *parses* under both drivers -- neither
will tell you it has never heard of `-o`. What it then does is what varies, and
there are only three honest possibilities: honour it, ignore it and say so, or
refuse it and say why. Silently accepting a flag that changes nothing is the one
thing neither driver may do, because it reports a change that was not made.

- **`domain addr` has no answer on a Windows host.** Under user-mode NAT the
  guest is 10.0.2.15 on a network that exists inside the qemu process; nothing
  on the host routes to it, and there is no bridge, tap or libvirt network that
  would put it there. So the Windows driver prints the port forwards -- which
  are the only way in -- and says plainly that the guest address is not
  reachable, rather than printing 10.0.2.15 and letting someone spend an
  afternoon pinging it. It exits 0: the question has an answer, and that is it.
- **`domain create -o ID` is accepted and ignored there.** There is no
  libosinfo, and nothing on that host consults an os id. It stays in the grammar
  so a command line written for one driver parses under the other, and it says
  so when used.
- **`domain create -p SPEC` and `-N` are Windows-only additions.** `-p` names a
  port forward, repeatable; without a libvirt network a forward is the only way
  into the guest, so create has to be able to make one. `-N` creates the domain
  without starting it. Neither exists on the Linux driver, and a script using
  them is a script for one host.
- **`domain start -s/-m/-c` is refused on a Windows host, not ignored**, which
  is the third possibility above rather than an exception to the rule. Those
  three rewrite a libvirt domain config, and there is no domain config there --
  the launcher is the domain, and the honest answer is "edit it, or recreate
  the domain". `domain start -G` is accepted, warned about and not honoured:
  qemu under WHPX has no headless console to detach from, and `-display none`
  would leave the guest with no way in at all.

The same rule covers the environment. `VIRUTILS_OSINFO`, `VIRUTILS_NETWORK` and
`VIRUTILS_FIRMWARE` are read by the Windows driver and acted on by none of it,
so `domain create` names each one that has actually been set and says it is
being ignored. `VIRUTILS_FIRMWARE=bios` gets more than that: it asks for a
machine Windows 11 will not install on, so it is called out as unhonourable
rather than merely unused.
