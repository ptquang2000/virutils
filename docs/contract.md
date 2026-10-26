# The virutil contract

virutil ships as two programs: `virutil`, a bash driver, and `virutil.ps1`, a
PowerShell driver for a Windows host (raw QEMU under WHPX). The bash driver
carries two module trees and loads the one `uname` names: `modules/linux` for a
Linux host (libvirt/KVM) and `modules/mac` for a macOS host (raw QEMU under
hvf). That is three host implementations, and they share no source. This file
is what they do share -- the observable surface a user and a script may rely
on, identically, on any host.

The fork is the directory layout too: `modules/linux`, `tests/linux` and
`completions/linux` are the bash driver's and `modules/win`, `tests/win` and
`completions/win` are the PowerShell driver's, each driver loading only its own
half. `modules/mac` is the bash driver's second tree; it shares the bash
driver's entry point, tests and completion, each of which asks `uname` which
tree it is looking at, and no module source with `modules/linux`. The exceptions are the two things that are *shared* rather than forked --
`payloads/`, which is split on the guest's OS instead (section 6), and
`tests/golden/`, which is one file precisely because both drivers must render
it.

A change to anything below is a change to both implementations or it is a bug.
Anything *not* below is each implementation's own business: how it talks to the
hypervisor, how it serves a payload, what it shells out to.

## 1. The two axes

Keep them apart; conflating them is how the fork rots.

- **Host axis.** What the driver runs on. This is the fork. libvirt/virsh,
  smbd, `ip`/`ss`, `sudo` on a Linux host; qemu-system-x86_64.exe,
  `New-SmbShare`, `Get-NetIPAddress` on a Windows one; qemu-system-aarch64,
  swtpm and QMP over Unix sockets on a Mac.
- **Guest axis.** What is on the other side of the transfer, keyed on the
  guest's OS, *not* the host's. A Windows guest fetches with robocopy over SMB;
  a Linux guest fetches with rsync. This axis is identical in both
  implementations and its payloads are shared as data (section 6).

## 2. Command grammar

The full observable CLI. Flags are long-and-short as written; `-h`/`--help` on
every module, exit 0 for an asked-for help and 1 for a usage error.

```
virutil domain create   VM ISO [-s GiB] [-m MiB] [-c N] [-o ID] [-v ISO|none]
                               [-p SPEC] [-N]            # Windows and macOS hosts
                               [-u FILE]                 # Windows host, -o winxp only
                               # -c N: Linux and macOS hosts; a Windows host creates
                               #       at 1 vcpu and refuses it (section 9)
virutil domain delete   VM
virutil domain list
virutil domain start    VM [-s GiB] [-m MiB] [-c N] [-G]
virutil domain shutdown VM
virutil domain addr     VM
virutil domain port     VM [PORT | HOSTPORT:GUESTPORT] [-c PORT]

virutil snapshot create VM [SNAP]        # Linux and macOS hosts; default snap-<timestamp>
virutil snapshot list   VM               # Linux and macOS hosts
virutil snapshot revert VM SNAP          # Linux and macOS hosts
virutil snapshot delete VM SNAP          # Linux and macOS hosts

virutil sync VM [-c NAME|PATH]
virutil push VM SRC DST
virutil pull VM SRC DST

virutil exec {ping|cmd|ps|sh} VM [-d] [--] [CMD...|-]

virutil ui  run VM [-i N] [-s] [--elevated] [--] APP...

virutil shot VM [-o FILE]

virutil input click VM X Y [-b left|right|middle] [--double]
virutil input move  VM X Y
virutil input drag  VM X1 Y1 X2 Y2 [-b left|right|middle]
virutil input wheel VM X Y N                      # N > 0 up, N < 0 down
virutil input key   VM COMBO...                   # ctrl+a alt+f4 enter win
virutil input type  VM TEXT...                    # US layout, printable ASCII

virutil usb {list|show|attach|detach} [VM] [VENDOR:PRODUCT]

virutil xfer {setup|remove|status}       # Windows host only
```

`xfer` is the one command in this grammar that is a host's by nature rather
than by a gap in a port. It registers, once and elevated, the scheduled task
that lets `push`, `pull` and `sync` on a Windows host get Administrator without
a UAC prompt per transfer (section 7). A Linux host's transport has its own
`smbd` and nothing to elevate, and macOS has no transport yet, so the bash
driver refuses `virutil xfer` by name on both, with that reason.

`usb` is on both drivers and holds to one grammar over two mechanisms -- a
libvirt `<hostdev>` on the bash side, `device_add` over the QEMU monitor on the
Windows one. What is on neither is the WSL case, where the device is plugged
into Windows and the domain is inside the Linux kernel's view: getting it across
is a `usbipd` recipe in the README rather than a command. See section 7.

`domain create -p SPEC` (a port forward, repeatable) and `-N` (create without
starting) exist on the Windows and macOS drivers, and are marked as such above:
both run guests on user-mode NAT, where a forward is the only way in. They
are in this section rather than buried in section 9 because a reader working out
what a command line means should not have to find them somewhere else -- but a
script using them is a script for one host. `snapshot` is marked the same way
for the same reason, the other way round: it was on both drivers and was taken
out of the Windows one (section 7). Everything else above is on the Linux and
Windows drivers; the macOS driver carries `domain`, `snapshot`, `exec`, `shot` and `input` so far
and refuses the rest by name (section 7). Section 9 says what each flag *does*
where the drivers cannot agree.

Invariants that are contract, not implementation:

- `push`/`pull`/`sync` require the domain **running**; delivery goes over the
  guest's own network and touches neither the disk image nor guest uptime.
- `SRC`/`DST` guest paths are relative to the guest root -- `C:\` on Windows,
  `/` on Linux. Backslashes and a `C:\` prefix are tolerated; `..` is refused.
  A trailing slash means a directory, as with rsync. The rule is the same in
  both directions: a single file sent to a `DST` that does not exist, has no
  trailing slash and (for `pull`) came from a `SRC` with no wildcard *is* that
  file. Any other `DST` is a directory that the source lands inside.
  tests/win/xfer.ps1 and tests/linux/pull.sh hold `pull` to it.
- `pull` wildcards match with the *guest's* own matching: case-insensitive on
  Windows, case-sensitive on Linux.
- **On a Windows host, `push`, `pull` and `sync` reach a Windows guest only**,
  and say so by name when asked for any other kind -- `sync` by refusing
  `@guest=linux` out of the config, before it fetches anything. That is a gap in
  the port rather than in the grammar -- the Linux-guest side is payload
  selection against payloads that already exist -- and section 7 says what is
  still unmeasured about it. The same host also needs Administrator per
  transfer and mints a throwaway local account, because the share comes from
  its own SMB server -- from the scheduled task `virutil xfer setup` registers,
  or as one UAC prompt per transfer where setup never ran. The grammar, the
  guest-side behaviour and the exit codes are unchanged by either.
- **`sync`'s `>pre-ui` and `>post-ui` run rules are on both hosts**, because
  they are `virutil ui` and `ui` is on both (section 7). They were refused on
  the Windows driver while it had no `ui`; they now launch through the same
  guest script there as here. Every directive in a config means the same thing
  on both hosts, except that the Windows one still refuses `@guest=linux`.
- **On a macOS host, `sync`, `push`, `pull`, `ui` and `usb` are not there yet**,
  and each is refused by name with the reason rather than as an unknown module
  (section 7).
- `domain delete` never prompts and removes disks, backing chain, snapshot
  overlays and memory files, mount points and port forwards; files another
  domain uses are kept.
- `snapshot delete` takes SNAP's descendants with it and commits no disk data.
  On a macOS host a snapshot has no descendants to take: qcow2 internal
  snapshots are flat (section 7).
- **`snapshot` is a Linux- and macOS-host command.** On both, a running domain
  snapshots memory too and a shut-off one is disk-only, and a revert leaves the
  domain running at the snapshot. It is not on the Windows driver
  at all: WHPX installs a migration blocker, so `savevm` refuses before it
  reaches any disk (measured -- section 7 quotes it), and a snapshot that can
  only ever be a disk is not worth the name. `virutil snapshot` on a Windows
  host is refused by name with that reason, never silently.
- `exec` runs as SYSTEM (Windows) / root (Linux) and the guest's exit code
  becomes virutil's.
- `shot` requires the domain **running**, takes the frame from the hypervisor
  with nothing run in the guest, and always writes PNG. The frame is the
  emulated console's; an RDP session is a separate desktop and is never in it.
- `input` requires the domain **running**, sends its events through the
  domain's emulated tablet and keyboard with nothing run in the guest, and
  takes X,Y in the pixels of a `shot` PNG. It refuses, before sending anything,
  a key name it does not know, a character the US layout cannot type, a
  position off the screen and a pointer verb on a domain with no absolute
  pointer.
- The disk is always `<image dir>/VM.qcow2`.

## 3. State layout

One root, everything under it, one variable relocates the lot.

| path | holds |
|---|---|
| `<root>/conf` | sync configs, looked up here first |
| `<root>/images` | domain disks, snapshot overlays, memory files, UEFI nvram, and -- Windows host only -- the per-VM `.cmd` launcher, its firmware log (OVMF, or SeaBIOS for `-o winxp`) and, for `-o winxp -u`, the answer-file floppy `VM-a.img` |
| `<root>/staging` | sync's incremental staging trees |
| `<root>/ports` | port-forward state and logs |
| `<root>/mnt` | host mount points for guest filesystems |
| `<root>/tmp` | transfer payload scratch |
| `<root>/cache` | third-party tools fetched once (the macOS host's own qemu) |

The overlays and memory files in the `images` row are the Linux host's alone:
`snapshot` is not on the Windows driver (section 7), so a Windows host's
`images` holds disks, nvram, launchers and logs and nothing any snapshot left
behind. A macOS host's snapshots are *internal* -- named states inside the disk
and nvram qcow2s, memory included -- so its `images` holds, per domain, the
disk, the nvram (`VM_VARS.qcow2`), the launcher (`VM.sh`), the qemu log, and
while it runs a pidfile and two Unix sockets (`VM.qmp`, `VM.qga`), plus a
`VM.tpm/` directory holding swtpm's state and the copies a disk-only snapshot
keeps of it. Nothing outside that list is ever written there.

Root is `~/.virutils` on Linux and macOS and `%USERPROFILE%\.virutils` on
Windows. The
staging tree must survive a reboot -- this is why it is not an XDG/`%TEMP%`
directory.

Every driver knows the whole layout and relocates it from the same variables,
but a driver only creates the directories it actually writes to. The Windows
driver writes to `images`, `tmp`, `staging` and `cache`, and reads `conf`:
`staging` and `conf` arrived with `sync`, and `cache` with `ui`. (`conf` is read on both hosts
and written by neither -- a config is the user's file, and a missing one is
reported at the path it was looked for rather than created.) `mnt` is for host
mount points it never makes, and `ports` holds the relay state and logs of a
mechanism it does not have --
under user-mode NAT a forward is a `hostfwd` on the qemu command line, so it
lives in the launcher with every other qemu argument and needs no state of its
own. **An empty directory is not a promise**: what section
3 fixes is where a thing goes when there is one, not that every driver puts
something in each.

`tmp` stopped being an empty promise on the Windows host when `push` and `pull`
landed there. Each transfer gets `<root>/tmp/<token>/`, holding its staging
tree, the request the elevated helper reads its orders from, the status file it
answers through, and -- when the transfer elevates by prompt -- that helper
itself; all of it goes at teardown. It is deliberately not the system temp
directory: under elevation `%TEMP%` resolves to an 8.3 short path that an
ordinary recursive remove refuses to delete through.

The one thing a Windows host keeps outside the root is the scheduled task's
copy of that helper, in `%ProgramFiles%\virutil\`, written by `virutil xfer
setup` and removed by `virutil xfer remove`. It is outside on purpose: the
root is the user's to write, and a file a task runs elevated without a prompt
has to be one only Administrators can change (section 7).

**A transfer's staging tree is under `tmp`, not under `staging`**, and the
distinction is what each row means rather than an inconsistency. `staging` holds
`sync`'s *incremental* trees, which outlive a run and are what make the next one
cheap; a transfer's staged copy exists for one transfer and is deleted with the
share and the account it was published for. Putting it under `staging` would put
something disposable in the one directory whose contents are meant to survive.
So `staging` stays `sync`'s, on both hosts.

`sync` on a Windows host makes that distinction visible rather than blurring it,
because one run uses both rows: `staging` holds the incremental tree the fetch
refreshes, and `tmp/<token>/share` holds the *delivery* tree the map rules build
for that one run and the share is published over. The second is built straight
into the transfer's own staging directory rather than assembled elsewhere and
copied in, which is the whole of what `sync` added to the transport there -- see
`Invoke-XferTransfer` in `modules/win/xfer.ps1`.

**One directory, not two, for named configs on a Windows host.** The bash driver
falls back from `<root>/conf` to `~/.config/virutils` so an install predating
`VIRUTILS_CONF_DIR` keeps working. There is no such install on a Windows host --
`sync` has never run there before now, and `%USERPROFILE%\.config\virutils` is a
path nothing has ever written -- so that fallback would be a compatibility
promise to nobody. "Looked up here first" is therefore also "looked up here
only" on that host. A path spelled out with `-c` is unaffected on either.

## 4. Environment

**The prefix is `VIRUTILS_`, plural, for every variable either driver reads.**

This was open, and it was a real bug rather than a matter of taste:
`modules/linux/paths` spelled the roots `VIRUTILS_*`, `modules/linux/domain` read
`VIRUTIL_IMAGE_DIR` (singular) *in preference to it*, and the first draft of the
PowerShell driver followed the singular -- so one config pointed the two drivers
at two different directories. Settled: plural everywhere, and the singular is
still read, second, with a one-line deprecation note. Both drivers do this, in
`modules/linux/paths` and `modules/win/paths.ps1`, and neither will stop reading the old
spelling.

| variable | meaning |
|---|---|
| `VIRUTILS_DIR` | the root; moves everything at once |
| `VIRUTILS_{CONF,IMAGE,PORT,TMP,CACHE}_DIR`, `VIRUTILS_{STAGING,MNT}_ROOT` | move one piece |
| `VIRUTILS_OSINFO` | fallback osinfo id when the ISO is not recognised |
| `VIRUTILS_VIRTIO` | virtio-win ISO path, or `none` |
| `VIRUTILS_NETWORK` | guest NIC spec |
| `VIRUTILS_FIRMWARE` | `uefi` (default) or `bios` |

The last three have no meaning on a Windows or macOS host -- there is no
libosinfo, no libvirt network, and neither WHPX booting Windows 11 nor an
arm64 guest has anything but UEFI -- so those drivers read them, say they are
ignored when one has actually been set, and carry on. A variable being in
this table means both drivers must *accept* it, not that both can act on it.

## 5. Exit codes

0 success, 1 usage or a plain failure, and these specific ones, which callers
match on:

| code | meaning |
|---|---|
| 90 | the guest has no rsync |
| 92 | mkdir failed in the guest (push) |
| 93 | robocopy failed, exit >= 8 (push, sync) |
| 94 | SRC matched nothing in the guest (pull) |
| 95 | robocopy failed, exit >= 8 (pull) |
| 96 | no user is logged on in the target session (ui run, sync's ui rules) |
| 97 | retired: was "PsExec is not present in the guest" (ui); no longer raised |
| 98 | the elevation prompt was declined (Windows host, push/pull/sync, when `virutil xfer setup` has not run) |
| 99 | the host could not publish the share (Windows host, push/pull/sync) |

Otherwise the guest's own exit code passes through (`exec`).

90 through 95 are the guest's, and are the same on both hosts. 98 and 99 are
the Windows host's alone: a transfer there publishes a share on the host's own
SMB server, which needs Administrator, and neither failure has any counterpart
on a Linux host. They are two codes rather than one because declining the
prompt is an answer rather than a fault -- a script wrapping `virutil push` has
to be able to tell "I clicked No" from "SMB is broken". 99 covers the rest of
the host setup (the share, the account, the filesystem ACL) with the specifics
in the diagnosis text.

93 is shared by `push` and `sync` rather than given one each, and that is
deliberate: it is the *guest's* code, raised by the robocopy line their payloads
have in common, and splitting it would mean the guest knowing which host command
sent it -- which it does not and should not.

## 6. Shared payloads

The scripts virutil sends *into* a guest are keyed on the guest OS, so they are
byte-identical under both drivers. They live in `payloads/` as data that each
implementation reads and interpolates -- not as code in either language, and
split into `payloads/linux` and `payloads/win` on the **guest's** OS rather
than the host's, so both drivers read both halves:

```
payloads/linux/probe.sh      Linux guest    refuse early when the guest has no rsync
payloads/win/push-dir.ps1    Windows guest  robocopy a served tree into a directory
payloads/win/push-file.ps1   Windows guest  Copy-Item one served file onto a path
payloads/linux/push-dir.sh   Linux guest    rsync a served tree into a directory
payloads/linux/push-file.sh  Linux guest    rsync one served file onto a path
payloads/win/pull.ps1        Windows guest  robocopy matches of a pattern out
payloads/linux/pull.sh       Linux guest    rsync matches of a pattern out
payloads/win/sync.ps1        Windows guest  robocopy the whole share onto C:\
payloads/linux/sync.sh       Linux guest    rsync the whole export onto /
payloads/win/mount.ps1       Windows guest  authenticate to a credentialled share
payloads/win/unmount.ps1     Windows guest  let go of it again
payloads/win/ui.ps1          Windows guest  start a process on a session's desktop
```

Nine of them rather than the five this section first guessed at, because push
needs two shapes on each side: robocopy cannot rename onto a new name, so a
single file goes through Copy-Item, and the rsync side is split to match rather
than to differ. The mount pair came later and is a different kind of thing;
`ui.ps1` came last, when `ui` stopped wrapping PsExec.

**The mount pair is keyed on the host, and it is the only pair that is.** Every
other payload is keyed on the guest, because what a guest can run is the guest's
business. These two exist because only one *host* has to authenticate: a Linux
host serves an anonymous share and sends neither of them, and a Windows host
cannot serve an anonymous one at all (section 7), so it sends them as their own
agent calls around the copier payload. `mount.ps1` drops the guest's existing
sessions to the host before mounting -- see the `1219` measurement in section 7
-- and maps no drive letter, so the copier payloads keep addressing the bare UNC
they are written and documented around.

Adding a credential hole to the three Windows payloads instead was rejected: a
hole left unfilled is refused by both renderers, so the bash driver would have
to carry forever a hole it can never fill. Both drivers render all eleven and
diff them against the one golden file, so this pair is held to the same identity
as everything else even though only one driver ever sends it.

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
a filter on its parent. Keep it in one place. `tests/linux/payloads.sh` and
`tests/win/payloads.ps1` render all eleven under both drivers and diff the result
against one golden file, which is what makes "byte-identical" a fact rather than
an intention.

## 7. Scope

Not every module ports. What the Windows driver ships today is:

`domain`, `exec`, `input`, `push`, `pull`, `shot`, `sync`, `ui` and `usb`. That is the whole
intended surface; `snapshot` is bash-only now. All of them are below. A module
that works beats two half-ported.

**Where it actually is:** `domain` and `exec` are ported, and the guest agent
channel they both stand on is in place. `usb` is on both drivers. `snapshot` was
ported and has been taken back out -- the question this section used to leave
open was measured, the answer was no, and the answer took the command with it,
below. `push`, `pull` and `sync` are ported, against a **Windows guest**: the
question `push` and `pull` were blocked on was measured and decided, and what was
decided is recorded below. What remains unported is a Linux guest from a Windows
host, which is a later pass on the transport that now exists rather than a new
question. `ui` is ported, below.

### The macOS host: `domain`, `snapshot` and `exec`

The macOS driver is `modules/mac`, loaded by the same `virutil` as
`modules/linux` when `uname` says Darwin. It runs an **arm64** guest -- Windows
11 on Arm -- because hvf accelerates the host's own architecture and nothing
else; an x64 guest on a Mac is TCG emulation, which is a different product.

Its shape is the Windows driver's, carried over to a Unix host: no libvirt, raw
QEMU, **the launcher is the domain** (`VM.sh`, one qemu argument per line),
user-mode NAT with `hostfwd` forwards as the only way in. Where it differs is in
how a running domain is reached: QMP and the guest agent over two Unix sockets
beside the disk, through `nc -U`, rather than a human monitor and an agent on
loopback ports. QMP because its replies are framed and matched by id; Unix
sockets because there is no port band to allocate and keep bindable, and a
socket under `~/.virutils` is reachable by its owner only, where a loopback
port is reachable by every local user.

**Stock qemu cannot boot Windows on Arm here, and the driver builds its own.**
Measured: the installer reads its `boot.wim` and then sits at the firmware
logo forever, its boot CPU parked on `b .` in the boot loader's exception
vector table, and qemu's trace names the cause --
`hvf_unknown_smc unknown SMC! 0x00000000c3000001`. Windows issues that OEM
SMCCC call by SMC at every boot; upstream's hvf answers an unknown SMC with -1
only when the PSCI conduit is SMC, and with an undefined-instruction exception
otherwise, and under hvf the virt board's conduit is HVC. UTM's qemu boots
Windows because it patches that one condition. `virtualization=on` makes the
conduit SMC, but the firmware then stalls at EL2, so it is not a way round.
So `patches/qemu/` carries the same one-line change, `install.sh --qemu` builds
a pinned qemu with it into `<root>/cache/qemu` (the cache row of section 3,
"third-party tools fetched once"), and the driver prefers that build to the
qemu on PATH -- and `domain create` warns, by name, when it is about to write a
launcher around stock qemu. With the patch, Windows Setup is on screen 30
seconds after `domain create`.

**What ships: `domain`, `snapshot`, `exec`, `shot` and `input`.** That is enough to build,
run, script and roll back a guest, and to see and drive its screen. `exec` is `modules/linux/exec` with the
agent reached over the socket and base64 spelled for BSD; `domain` and
`snapshot` are new code over QMP and `qemu-img`.

**`snapshot` is on this host because hvf saves memory**, the measurement that
took it off the Windows driver coming out the other way. Measured on an M5 Pro,
macOS 27, Homebrew qemu 11.1.1, against a guest booted on exactly the arguments
`modules/mac/domain` writes: `savevm` and `loadvm` complete (0.2s and 0.1s for
a firmware-only guest), and so do QMP's `snapshot-save` and `snapshot-load`
jobs, with the NVMe disk, the USB CD-ROMs, xHCI, ramfb, virtio-net,
virtio-serial and the swtpm TPM all attached. The snapshots are qcow2
*internal* ones -- the Windows driver's removed mechanism, now with its memory
half -- not the Linux driver's external overlays, because there is no libvirt
to keep records naming overlays. Three things follow, and are contract for this
host:

- The memory image goes in the disk (`vmstate=disk0`), never in the nvram, and
  a revert to it always happens in a **fresh** qemu: a running domain is
  powered off first, then qemu starts paused (`-S`), runs `snapshot-load` and
  continues. Startup `-loadvm` cannot be used: it looks for the memory on the
  first snapshot-capable drive, which is the nvram, and refuses with "This is a
  disk-only snapshot". And loading into the live process cannot be used either,
  which was learned against a real guest after a firmware-only one had passed:
  with Windows running, `snapshot-load` in place killed qemu on
  `Assertion failed: (!auto_alloc || *pptr == NULL), function
  vmstate_load_next` -- the NVMe controller's queue arrays, which its vmstate
  allocates on load and so needs empty, and which a live guest has filled. A
  fresh process has them empty. Measured through that path on Windows 11 on
  Arm with 8 GiB: create 1.7s while running, revert 2.2s, the guest back with
  its agent answering and a file written after the snapshot gone.
- Internal snapshots are flat. None has a parent or children, so "delete takes
  SNAP's descendants with it" holds with nothing to take, and deleting one
  never touches another.
- The TPM's state is outside both qcow2s. A memory snapshot carries it
  (swtpm hands it to qemu with the guest's RAM); a disk-only one copies swtpm's
  state file beside it and puts it back on revert, so a guest is never booted
  against TPM keys from a different moment than its disk.

**What is refused, by name, and why.** `sync`, `push` and `pull` need the
transfer layer, and the transfer layer on this host is an open question rather
than a port. The design every other host follows -- the host serves, the guest
fetches over SMB from 10.0.2.2 -- needs an SMB server the guest's client will
accept, and a Mac has two candidates, neither measured: macOS's own SMB server
(File Sharing, which needs Administrator and is offered on every interface, the
weakness section 7 records for the Windows host), or Samba run as the invoking
user and reached through a slirp `guestfwd`, which needs no root and is offered
on no host interface at all -- qemu's own `-nic user,smb=` is that mechanism.
The second is the likely answer and is what the next pass measures, against the
two refusals a stock 24H2 client brings (insecure guest logons off, signing
required). `ui` needs only `exec`, so it waits on nothing but being wired in. `usb` is
unmeasured: whether qemu under hvf can claim a device from macOS's own USB stack
at all is the first question, and it has not been asked.

### `sync`: ported, on the transport `push` and `pull` built

`sync` was the last module this section listed as intended and unwritten, and it
was unwritten for one reason: it is the transfer layer plus a config parser, and
the transfer layer did not exist on this host. Once it did, the port was that
parser and nothing else -- the guest half is `payloads/win/sync.ps1`, which both
drivers already shared byte for byte, sent over the same share `push` publishes.

**What it added to the transport is one thing.** `Invoke-XferTransfer` took a
path to copy into the transfer's staging directory; it now takes either that or
a builder to fill the directory itself. `sync` needs the second because its
delivery tree is *built* -- the map rules write it one rule at a time in a layout
that mirrors the guest's root -- and staging it the old way would have meant
assembling that tree somewhere else and then copying the whole of it in. For a
build tree that second copy is the expensive half of the run. Neither form is
optional: a transfer that staged nothing would publish an empty share and report
a successful delivery of no files, which is the one failure here that looks like
a success.

**The host half is robocopy, not rsync.** Both the fetch and the map are
host-to-host, so the copier is the host's own. The one place that is visible in
a config is the excludes: rsync's `--exclude=PAT` matches a name at any depth,
file or directory alike, and robocopy splits that across `/XF` and `/XD`, so
every pattern is given to both. What does not survive the mapping is an anchored
pattern -- rsync reads a leading or embedded `/` as a position in the tree, and
`/XF` matches on the name alone.

**One thing in a config is refused by name, before the fetch:** `@guest=linux`,
because this host reaches a Windows guest only. The obstacle is a property of
the *host*, known before the config is opened, so there is no reason to spend a
fetch, an elevation prompt and a delivery first. `>pre-ui`/`>post-ui` were
refused the same way while this driver had no `ui`; they run now, as they do on
the bash driver.

### `snapshot`: ported, measured, and taken back out

This section has said three things in turn. First "not yet, and here is the
criterion for changing that". Then "ported, disk-only, and that is not a
half-port". Now: **the command is gone from the Windows driver**, and what
follows is the evidence that took it out rather than an account of something
that still ships.

The order matters, because every measurement below was made while the command
existed and not one of them has been retracted. The disk half worked. What
changed is the judgement of whether a snapshot that is only a disk half earns
the name on this host, and the answer is no -- the thing a snapshot is reached
for, putting a running guest back the way it was, is exactly the half WHPX will
not give. A command that cannot do the thing it is named for is better absent,
and said to be absent, than present and explaining itself at every call.

**The memory half has an answer, and the answer is no.** It is not a matter of
choosing between `migrate "exec:..."` and `savevm`: WHPX installs a migration
blocker, and every route to a guest's RAM goes through the code that blocker
guards. Measured on a Windows host, qemu 11.1.0, against a guest booted on
exactly the command line `modules/win/domain.ps1` writes:

```
(qemu) savevm t1
Error: State blocked due to missing dirty memory tracking support,
And some system register/state save-restore
```

That is the accelerator refusing, before any disk is touched. The obvious
suspect is the wrong one and is worth naming so nobody re-runs the experiment:
the UEFI nvram is a writable **raw** pflash drive, which produces a second and
entirely separate refusal --

```
(qemu) loadvm t1
Error: Device 'pflash1' is writable but does not support snapshots
```

-- and converting that nvram to qcow2 clears it and changes nothing. `savevm`
still stops at the accelerator. So the memory half is closed for as long as the
Windows driver runs guests under WHPX, and no plumbing in virutil opens it.

**Re-measured against a real guest, and confirmed from upstream.** The first
measurement was taken against a probe domain whose guest was the OVMF shell,
which invites the fair objection that an empty guest is a degenerate case and
proves nothing about a real one. It is not, and it does. The same refusal comes
back in the same words from a Windows 11 guest installing from its own media,
running and paused alike. `savevm` is not the only door tried: `migrate -d
file:...` writes no file and is refused identically, and `info migrate` then
reports

```
Outgoing migration blocked:
  State blocked due to missing dirty memory tracking support,And some
  system register/state save-restore
```

which is the blocker saying in its own words that it guards every route out of
guest RAM rather than `savevm` alone. The wording is upstream's: it was written
in patch 33 of the WHPX x86 series for qemu 11.1 -- the series that *added*
XSAVE support and kept the blocker anyway, because dirty memory tracking is
still missing. So "no memory snapshot under WHPX" is qemu's own position on its
own accelerator, not an inference drawn from one host, and the thing to watch
for a change is dirty memory tracking landing in `whpx-all.c`.

**Shut off means shut off, not paused.** The blocker is not a property of the
run state: `savevm` on a guest stopped with the monitor's `stop` is refused in
exactly the same words, and qemu goes on holding its image open while paused.
There is no third state in which a snapshot becomes possible.

**And qemu on Windows does not protect the image, which makes the rule
virutil's to enforce.** On a Linux host qemu takes an OFD lock and `qemu-img`
refuses a locked image; the Windows file backend has no equivalent. Measured:
`qemu-img snapshot -c` against the disk of a *running* domain returned exit 0
and wrote the snapshot into the live image. While the command existed, the
module opened the disk exclusively before every write and refused if anything
held it. **That fact outlives the command:** two qemus on one qcow2 is silent
corruption here rather than an error, and anything written in future that
touches a disk image has to carry the check the snapshot module carried.

**And then it was taken out.** The disk half worked, and was measured working
against a real Windows 11 guest: `create` refused a running domain by name,
`list` answered over the monitor while the domain ran, and the shut-off round
trip of create/list/revert/delete was clean. The removal retracts none of that.
It answers a different question -- what is a disk-only snapshot actually *for*?

On a Linux host the question does not arise, because the memory half is there
when the domain runs and the disk half stands alone honestly when it does not.
Here there is only ever the disk half, and what it serves is already served: a
domain about to be changed can be copied while it is shut off, and a domain that
must come back exactly as it was is precisely what WHPX refuses. What was left
was a command whose usage text spent more words on what it could not do than on
what it could.

So section 2's four `snapshot` verbs are **Linux-host commands**, annotated
there as such, and `virutil snapshot` on a Windows host is refused by name with
the reason. What it must not do is fall through to "unknown module": the command
is in the grammar section 2 publishes, and it was on this driver one commit ago,
so whoever types it has been told twice that it exists. `$script:ELSEWHERE` in
`modules/win/parser.ps1` is where that reason lives. `push`, `pull`, `sync` and
`ui` were on the list of names waiting for it and have left it: they are in
`$MODULES` now.

The bash driver is untouched. Its `snapshot` is external overlays plus a memspec
through libvirt, it captures memory for a running domain, and none of this
reaches it.

**What the removal deleted,** for a reader comparing the two trees:
`modules/win/snapshot.ps1` -- qcow2 internal snapshots, `qemu-img snapshot
-c/-l/-a/-d`, one image, no overlay or memory files of its own -- and
`tests/win/snapshot.ps1`.
The bash module's in-use analysis (the sweep, the backing-chain walk, the
refusal to unlink a file the guest still reads) never had a counterpart here,
because an internal snapshot is a region of a disk image rather than a file.
That asymmetry is now moot rather than vacuously satisfied.

### `ui`: ported, on `exec` alone

`ui` was always going to port: it is Windows-*guest*-only, but host-portable.
Its guest half is `payloads/win/ui.ps1`, which both drivers render byte for
byte. It runs from the SYSTEM shell qemu-ga already provides. It stamps a
primary token with the session: `WTSQueryUserToken` for the logged-on user, or
its own SYSTEM token with `TokenSessionId` set for `-s`. It takes
`TokenLinkedToken` for `--elevated`, builds an environment block, and calls
`CreateProcessAsUser` onto `winsta0\default`. It needs nothing staged in the
guest and no transfer, so it costs no more than `exec`. docs/ui-psexec.md
records the PsExec reading this came from. `ui setup`, which used to deliver
PsExec over `push`, is retired: it exits 0 and says so, and exit 97 is no
longer raised.

### `shot`: on every host, from the hypervisor

`shot` asks the hypervisor for the frame and never the guest, so it needs no
agent and no payload. It works the same on a guest in firmware, in Setup, or
hung. Each host takes the frame its own way:

| | mechanism | format qemu writes |
| --- | --- | --- |
| Linux | `virsh screenshot`, which streams the bytes back through libvirt | PNG or PPM, as libvirt and qemu agree; a PPM is converted with `python3` |
| Windows | `screendump "FILE" -f png` on the human monitor | PNG; a qemu without libpng refuses the format by name and gets `-f ppm`, converted with System.Drawing |
| macOS | QMP `screendump` with `"format": "png"` | PNG; both qemus that driver runs are built with libpng |

On Linux the frame goes through virsh rather than through
`qemu-monitor-command`. With the monitor command, qemu writes the file itself,
as the qemu user and under the domain's security label, and so cannot write
into the caller's directory. On the Windows and macOS hosts qemu runs as the
caller, so it can write the file directly.

On every host the frame is written under `<root>/tmp` and moved onto `-o` only
after it has been read back as an image. A failed shot therefore never
truncates an existing file.

Measured on the Windows host (qemu v11.1.0-12130): `-f png` gives a PNG
directly. A q35 paused with `-S` and no disk gives a 640x480 frame, and that
paused qemu is what tests/win/shot.ps1 runs against. Against a live win11
(WHPX, `-vga std`), one capture wrote a 1280x800 PNG of the console desktop
in 7s end to end, pwsh start included, and nothing in the guest was touched.
The macOS module has run only with QMP stubbed, never yet on a Mac.

### `input`: on every host, through the emulated tablet and keyboard

`input` is the other half of `shot`. qemu delivers its events through the
domain's emulated devices, so nothing is staged in the guest, and Windows takes
them as hardware input. UIPI therefore does not apply, and an elevated window
or the UAC prompt takes them like any other. The grammar, the US-layout table
and the pixel mapping are the same on every host:

- A pixel P on a screen S pixels across is sent as `floor((2P+1) * 32768 /
  (2S))`, which is the centre of that pixel's slice of the tablet's 0..32767
  range. S is read from a screendump on every pointer command, so a guest
  that changed resolution is followed.
- `type` covers printable ASCII, tab and newline on the US layout and refuses
  everything else, naming each character by code point, before sending any
  key. A combo with an unknown key name is refused the same way.
- A paused or shut-off domain, a position off the screen and a domain with no
  absolute pointer (qemu's `query-mice` / `info mice` lists none) are refused
  before any event is sent. `key` and `type` do not need the pointer.
- One line on stderr and nothing on stdout. Exit 0 when sent, 1 otherwise.

| | pointer | keys |
| --- | --- | --- |
| Linux | QMP `input-send-event` (`abs`, `btn`) through `virsh qemu-monitor-command` | QMP `send-key`, the same way |
| Windows | an `input-barrier` object, `object_add`ed over the human monitor and pointed at a loopback listener `input` opens for the length of the command | `sendkey` on the human monitor |
| macOS | QMP `input-send-event` on the domain's socket | QMP `send-key` |

The Windows host needs the detour. Its launcher opens only the human monitor,
and that monitor's `mouse_move` queues *relative* motion. Measured with qemu's
`input_event_*` trace on, a `mouse_move 100 200` arrives as `input_event_rel ...
axis x, value 100`. A relative event is routed to the PS/2 mouse, not the
tablet, and the guest's acceleration then scales it. A QMP monitor cannot be
added to a running qemu. `input-barrier` is in every qemu build. Its
`width`/`height` properties are set to 32767, which makes qemu's scaling the
identity, and a Barrier `DMMV 16384 8192` then arrives as `input_event_abs ...
value 0x4000` and `... 0x2000`. The whole command is one monitor connection,
because `Invoke-DomainMonitor` costs about 2s per line and the monitor serves
one client at a time.

On Linux, libvirt marks a domain that has received a monitor command as
tainted (`custom-monitor`) in its log. Nothing else changes. `virsh send-key`
could send the keys without that, but the pointer has no virsh command, and
two mechanisms with two key-name sets are not worth that one log line.

Measured on the Windows host (qemu v11.1.0-12130): tests/win/input.ps1 runs the
driver against a throwaway running qemu with the input trace on, and asserts
that qemu took exactly the absolute positions, buttons, wheel notches and key
codes that were sent. Against winxp's disk booted read-only (`-snapshot`) in a
throwaway qemu at 1024x768, `move` put the cursor's tip on the requested pixel
at 0,0, 300,200, 517,383 and 1023,767. A right-click menu, a `drag` of a
window by 200,200, `key win+r`, `ctrl+a` and `alt+f4`, and `type` of every
ASCII punctuation character all did what they should. Against win11 (Windows
11 22H2, WHPX, 1280x800), a `click` on an In-Session tab put the cursor's tip
on the requested pixel and switched the tab. That window's process runs at
medium integrity, not elevated, so the UIPI claim is still unmeasured. The
macOS module has run only with QMP stubbed (tests/mac/input.sh).

### The transfer layer, and what is measured about it

`sync`, `push` and `pull` all deliver the same way: **the host serves a tree and
the guest fetches it.** That direction is not an implementation detail and must
not be inverted. Under user-mode NAT the host cannot open a connection to the
guest at all, but the guest can always reach the host at `10.0.2.2` -- the
architecture happens to be exactly what slirp allows.

The plan for the Windows host is to collapse both guest OSes onto SMB, since
Windows *is* an SMB server natively (`New-SmbShare`, no smbd to install, no
privileged-port dance) and a Linux guest can `mount -t cifs` and rsync against
the mount. The guest-side split survives untouched; only what the guest mounts
changes. That deletes the whole samba and rsyncd half of `modules/linux/xfer`.

**Authentication was the open question, and it has been measured.** The bash
driver's smbd is configured `map to guest = Bad User` with `guest ok = yes`, so
the guest fetches with no credential at all. Windows' own SMB server has no
equivalent that is on by default, and this section used to say so from
documented defaults while asking for a measurement against a real guest. The
measurement was taken -- Windows 11 24H2 guest, build 10.0.26100, qemu's slirp,
host serving with `New-SmbShare` -- and it moved more than it confirmed.

**The anonymous share is refused twice over, and the two refusals are
independent.** A stock guest ships `EnableInsecureGuestLogons: False` and
`RequireSecuritySignature: True`, so its client declines before the host is
consulted -- the claim this section made from documentation, now a fact about a
real guest. Relaxing *both* of those inside the guest gets past the client and
straight into the host's own refusal:

```
System error 1331 has occurred.
This user can't sign in because this account is currently disabled.
```

That is the host's `Guest` account. So the straight port of the Linux-host
design does not cost one protection, it costs two, on two machines, and neither
one alone is enough to make it work.

**The throwaway account works, and costs more than this section used to say.**
It was costed at "account churn on the host for every push". Measured, it is
account churn *plus an ACL edit*: granting the account read on the share and
nothing else produces a successful logon followed by

```
ERROR 5 (0x00000005) Getting File System Type of Source \\10.0.2.2\<share>
Access is denied.
```

because the staged tree is under `%USERPROFILE%` and an account minted seconds
ago has no NTFS rights inside another user's profile. The share ACL and the
filesystem ACL are two gates and the tighter one wins. With both granted, a
marker file crosses and is read back in the guest by content.

**Elevation is not a differentiator, and that is settled for all three.**
`New-SmbShare` requires Administrator whichever credential answer wins, so the
auth question does not decide whether `push` needs elevation. It does. What
*was* still open is whether it needs a person each time, and that is answered
below: once, at `virutil xfer setup`, and never per transfer after it.

**One credential per (client, server) pair, and this is the constraint that was
missing.** Windows permits a client exactly one identity toward a given server,
whatever the share:

```
System error 1219 has occurred.
Multiple connections to a server or shared resource by the same user, using
more than one user name, are not allowed.
```

Measured by accident and worth more than anything measured on purpose: a run
that died between its `net use` and its cleanup left the guest holding a session
under an account the teardown had already deleted, and the *next* run's
candidates both failed at the logon -- neither because the answer was wrong. Any
design minting a per-transfer identity inherits this, so a transfer that ends
badly wedges the next one, and a guest that merely has a drive mapped to the
host for its own reasons breaks transfers outright. Dropping the guest's
sessions to the host is therefore a precondition of a transfer and not tidying
after one.

**And a share cannot be scoped to an interface.** `xfer_smb_serve` binds smbd to
the single address that reaches the guest, never the wildcard, precisely so the
payload is not offered to every network the host is on. `New-SmbShare` takes no
bind address at all: the share is offered everywhere the host's SMB server
listens and only its ACL narrows it. Whatever is built here is weaker on this
point than the bash side, and the ACL is doing the work the bind address does
there -- which is a reason to prefer a named grantee over `Everyone` that has
nothing to do with authentication.

The invoking user's own credential in the payload was deliberately **not**
measured: the throwaway account proves the mechanism, and running it would put a
real password on a virtio channel and into a guest's command history to learn
nothing new. The Linux-guest side of the same share -- whether `mount -t cifs`
will take an anonymous mount a Windows client refuses -- is unmeasured, and it
matters, because the guest axis is where the two would differ. It is the one
fact a Linux guest from a Windows host still waits on.

**Decided, on those measurements: a throwaway local account, minted per
transfer.** `modules/win/xfer.ps1` is what that became, and these are the parts of
it that are contract rather than implementation:

- The account is `vxp-<token>`, inside Windows' 20-character cap on a local
  account name, with a 24-character alphanumeric password from a cryptographic
  RNG. Alphanumeric because a value spelled like a placeholder is refused by
  both renderers (section 6), and because the guest hands it to `net use`.
- It is in **no group**, is granted the network logon right and denied the
  interactive and remote-interactive ones, and is removed at teardown. The
  argument for preferring a throwaway over a real credential is that it cannot
  be used for anything else; restricting its rights is what makes that true
  rather than merely likely. The password does cross the virtio channel -- that
  is inherent to the guest running `net use` -- and the point is that this
  credential is worthless.
- The `vxp-` prefix is what makes "mine to reap" decidable **without a state
  file**. Strays are swept on the next run, and the sweep skips any candidate
  whose owning process is still alive, which each transfer's status file records.
  Concurrent transfers are independent and are not refused.
- **Only the share management elevates.** The run stays in the console the
  developer typed in -- keeping the guest's stdout, the diagnoses and the exit
  code where they belong -- and a short-lived elevated helper mints the account,
  publishes the share, fixes the filesystem ACL and takes all three away again.
  The helper keys its teardown on waiting for the *parent's* process to exit,
  which is the nearest thing this host has to the `trap ... EXIT` the bash
  transport relies on: teardown fires on Ctrl-C, on an exception, and on the
  run being killed while the agent hangs.
- **The helper is elevated one of two ways, and a person is needed at most
  once.** `virutil xfer setup`, run once from an elevated prompt, registers a
  scheduled task (`virutil-xfer-helper`): as that user, highest privileges,
  interactive token, no trigger, parallel instances, normal priority (the
  scheduler's default of 7 starved the helper for minutes on a busy host),
  readable and runnable by that user alone. A transfer starts it with the
  token as `$(Arg0)` -- `IRegisteredTask.Run` substitutes parameters into the
  action textually, which was measured -- and starting it raises no prompt.
  The start hands back the helper's process, so a helper slow to say it has
  begun is waited for rather than reported as one that never ran. Without the task,
  or with one whose installed helper is not the one this virutil would render
  (an update, a moved `VIRUTILS_TMP_DIR`), a transfer falls back to
  `Start-Process -Verb RunAs`: one UAC prompt, as before the task existed. A
  stale task is the one fallback that says so. An unattended run was the
  reason. A consent dialog nobody is there to answer stalls it for the whole
  ready timeout, and the sooner a run like that is told it will be asked, the
  better: `virutil xfer status` exits 0 only when it will not be.
- **What the task makes possible is bounded, because the helper decides
  nothing a caller passes.** Any process running as the user who set the task
  up can start it without a prompt, so the task runs a copy of the helper that
  setup wrote under `%ProgramFiles%\virutil\` -- writable by Administrators
  only -- and that copy takes one argument, the token. The scratch root and the
  account prefix are baked in when it is rendered; the share is always
  `<root>/tmp/<token>/share` and the account always `vxp-<token>`. The rest
  (password, ro or rw, the pid to wait on, the strays) is read from
  `request.json` and checked for shape. A scratch directory or a share tree
  with a reparse point in it is refused before anything is granted. The worst
  a hostile caller can have it do is what a transfer does. The checks are
  checks, not locks: a caller racing the helper could still swap a directory
  between the check and the use, and that is written down rather than
  claimed solved.
- The two halves cannot use a pipe, and the reason is measured rather than
  assumed: `Start-Process -Verb RunAs -RedirectStandardOutput` is a parameter-set
  error, because the verb requires ShellExecute and ShellExecute forbids
  redirection, and a task start has no pipe to offer either. On both paths the
  parent writes the transfer's orders into `request.json` in its scratch
  directory -- no longer onto a command line, where the password was readable
  by anything that lists processes -- and the helper answers upward through a
  status file. Its first record carries its own pid, which is how the parent
  learns what to watch when a task start hands it no process at all.
- **Every transfer stages**, into `<root>/tmp/<token>/`, and the staged copy is
  what the share points at. This diverges from the bash driver, which serves a
  directory source in place, and the divergence is deliberate: serving in place
  would mean editing the filesystem ACL of the developer's real tree and -- since
  a share here cannot be bound to an interface -- offering that tree on every
  network the host is attached to. `pull` seeds its staging tree from the
  destination first, so the guest still sees what the host already holds and
  still sends only what differs.
- **Nothing is created and nothing is elevated until the transfer is known
  to be possible.** Domain running, agent answering and source readable are all
  settled first. Being asked to approve Administrator and *then* told the guest
  is not running is the worst available ordering.
- The weakening against the Linux host stands and is not solved: the ACL is
  doing the work `smbd`'s bind address does there.

The prototype that took these measurements was on the
`prototype/xfer-windows-auth` branch, with the teardown and stray-reporting that
made each number checkable. Its own header said to delete it once the findings
were folded in. They are, and it is.

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

`tests/linux/conformance.sh` runs the part of that which needs no guest, against both
drivers:

| | |
|---|---|
| `tests/linux/conformance.sh` | the runner. Every `--help` exits 0, every usage error exits 1, in both drivers; drives the two below. |
| `tests/linux/payloads.sh`, `tests/win/payloads.ps1` | render all eleven payloads under each driver and diff both against `tests/golden/payloads.txt`. This is what makes section 6's "byte-identical" checkable. |
| `tests/win/domain.ps1` | the launcher round trip: monitor port, agent channel and port forwards written, read back, edited and read again. |
| `tests/mac/domain.sh` | the macOS driver against a real hvf domain with no OS: create's files, start, port forwards live and in the launcher, every snapshot verb with the domain running and shut off, the launcher edits, delete. Driven from the runner on a Mac; skips anywhere else. |
| `tests/win/xfer.ps1` | `push` and `pull` on a Windows host with both seams substituted -- the guest agent and the share publisher -- so the guest path rules, credential generation, the free-space refusal, the sweep's liveness decision, the rendered payload and the teardown all run with no VM and no Administrator. Under the publisher, its own three seams (the task lookup, the task start, the UAC start) are substituted instead, so the choice between task and prompt, the request the helper is handed and the helper pid read back from the status file are asserted too; and the real helper is run unelevated against the requests it must refuse. Nothing registers a task or elevates. |
| `tests/win/sync.ps1` | `sync` on a Windows host, over the same two seams, with a real staging tree and a real delivery tree built on the host: what each config directive parses to, that the two a Windows host cannot honour are refused **before anything is fetched**, the layout the map rules build, the payload the guest would have been sent, and that a failed delivery tears down as completely as a successful one. |
| `tests/win/shot.ps1`, `tests/linux/shot.sh` | `shot`'s grammar, its refusals, and the PPM fallback with pixels checked, behind a substituted monitor (Windows) or `virsh` (Linux). The Windows half also captures from a real paused qemu with no disk and no guest, and skips that part where no qemu is installed. |
| `tests/win/input.ps1`, `tests/linux/input.sh`, `tests/mac/input.sh` | `input`'s grammar, its refusals (before anything is sent), the pixel-to-tablet mapping, US-layout typing, and the events each verb sends, behind a substituted monitor and barrier (Windows), `virsh` (Linux) or `qmp()` (macOS, runnable on any host with bash and jq). The Windows half also drives a real running qemu with its `input_event_*` trace on and checks that qemu took exactly what was sent; it skips that part where no qemu is installed. |
| `tests/win/transfer.ps1` | the guest tier: the transfer minimum below, plus the property that a completed transfer and a killed one both leave no account, no share and no staged tree. |

On a Mac the bash half runs `modules/mac` -- the module list is read from
whichever tree `uname` selects -- and adds two things of its own: each command
the macOS driver does not carry is refused by name with the reason, and
`tests/mac/domain.sh` drives a real hvf domain with no OS in it (a blank ISO
leaves the firmware in its shell) through create, start, port, every snapshot
verb in both domain states, the launcher edits and delete -- including
section 8's "create leaves exactly the files section 3 names". What it cannot
reach is anything inside a guest. That half was measured by hand against
Windows 11 on Arm with the x64 qemu-ga, and is not yet a script: `exec`
propagates the guest's exit code (`exit 7` is virutil's 7), the agent answers
again after a guest reboot, `shutdown` through the agent powers the domain off
in 4s, a cold `start` has the agent answering in 12s, and a memory snapshot
round-trips (above).

The PowerShell half skips itself, loudly, on a host with no `pwsh`.

**A test that reaches a real guest has no default guest.**
`tests/win/transfer.ps1` is the one test that does: it pushes into the guest,
kills a push half-way, and deletes `C:\virutil-xfer-test*` there. It takes the
guest from `-Vm VM` or `VIRUTILS_TEST_VM` and from nowhere else: no fallback
name and no pick from `domain list`. With neither set it skips and says why.
It used to default to `win11`, and an unattended run of the Windows tests then
pushed into a `win11` that was leased to a UAT recording. Every other test
here runs under a scratch `VIRUTILS_DIR` with no launcher for a real domain,
or, like `tests/mac/domain.sh` and the real-qemu halves of `shot.ps1` and
`input.ps1`, against a qemu it starts and stops itself. A new test that needs
a real guest follows `transfer.ps1`, and the runner never names one for it.

`transfer.ps1` also skips when the guest it was given does not answer. Run
against a live guest, it is the only interactive test in the suite, unless
`virutil xfer setup` has been run on that host: without the task, a transfer
on a Windows host prompts for Administrator once.

**Still missing, and named so it is not mistaken for covered:** `exec`
propagating a guest exit code against a real guest, `domain create` leaving
exactly the files section 3 names, and `sync` against a real guest -- the whole
of `tests/win/sync.ps1` stops at the agent boundary, so what a guest does with
the delivery is asserted nowhere on this host. The `push`/`pull` round trip and
the second `push` moving nothing were on this list and are now in
`tests/win/transfer.ps1`.

The config parse is the one part of `sync` that is worth testing twice over
rather than once against a guest: the config file is contract, both drivers read
it, and neither reads the other's parser.

## 9. Host-specific behaviour that is *not* contract

Documented so nobody "fixes" one driver to match the other. The header of
`modules/win/domain.ps1` records how each was bisected on the Windows host, and is
the place to read before changing one: `-cpu Skylake-Client` rather
than host-passthrough, `threads=1` rather than an SMT topology,
`cache=writeback` rather than `cache=none,io=io_uring`, `-vga std` rather than
virtio. No kvm (WHPX instead, so no hyperv enlightenments), no swtpm, no
libvirt network.

The macOS host's equivalents are in the headers of `modules/mac/qemu` (what was
measured) and `modules/mac/domain` (what each device is for). In brief: `-cpu
host` under hvf, `virt,gic-version=3`, one thread per core (Apple silicon has
no SMT); the disk on **NVMe** rather than virtio-blk, because the arm64
installer has it inbox and it snapshots; the ISOs as **USB CD-ROMs** (`usb-bot`
plus `scsi-cd`), because the virt machine has no IDE or AHCI; **ramfb** for the
display; the nvram as **qcow2**, because a raw writable pflash blocks every
internal snapshot; `tpm-tis-device` with **`ppi=off`**, because PPI's RAM region
is smaller than the 16 KiB page hvf maps and qemu dies at startup on
`HV_BAD_ARGUMENT`; qemu **never `-daemonize`d**, because its forked child aborts
in the Objective-C runtime at the first snapshot; and every forward bound to
**127.0.0.1**, where the other two drivers' `tcp::H-:G` binds every interface.
That last one is a choice rather than a measurement, made because a Mac is
usually a laptop and the guest's RDP should not be offered to whatever network
it has joined; the other drivers may want it too, but are not changed here.

One more is a measurement, and it is the one most worth carrying to the
Windows driver: **every macOS domain gets its own hardware identity** -- an
SMBIOS UUID and serial, a NIC MAC, an NVMe serial -- generated once at create
and frozen in the launcher. On qemu's defaults every guest is the same machine
(MAC 52:54:00:12:34:56, no SMBIOS UUID or serial), and so is every other qemu
guest anyone has left on them. The first Windows install on this host went
online in OOBE, matched that identity against Windows Autopilot, and offered
another organisation's tenant as the only way in -- someone had registered a
default-identity qemu guest there. libvirt randomises the MAC and UUID per
domain, so the Linux driver has never had this; the Windows driver writes no
`-uuid`, `-smbios` or `mac=` either, and is likely exposed in the same way.

One entry in that header is a defect rather than a setting, and it changes what
an install has to be *told* rather than what either driver promises. On the qemu
build the Windows driver runs, a guest with more than one vcpu dies at its own
reboot -- `failed to get xsave state` once per vcpu, then `WHPX: Unexpected VP
exit code 4`, leaving the domain paused with vcpus that cannot be restarted. It
fires at Setup's own reboot, so it looks like an install that got most of the
way and then failed. The fix is upstream and dated after the newest published
Windows build of qemu, so there is no build to move to yet.

That defect once made `domain create` write one vcpu and refuse `-c`. It no
longer does, because the count that dodges it is a count no install can begin
on: **Windows 11 Setup refuses to install on fewer than two cores**, stopping at
"This PC can't run Windows 11" before the disk step, and the core minimum is not
among the checks a `LabConfig` bypass waives -- measured with all five Bypass
values set and read back, the appraiser re-run, still refused, and the same
domain walking past the screen at `-smp 2` with no bypass at all. Setup names it
in `X:\Windows\Panther\setupact.log` as `Procs=1` followed by
`Callback_ValidateHardwareRequirements`. So **`domain create` on the Windows
host writes two vcpus and accepts `-c`** (warning on `-c 1`, which is a fine
machine for an installed guest and a dead end in front of an install). The two
facts pull opposite ways -- one vcpu cannot start an install, more than one may
not survive its reboots -- and the reboot workaround below is what absorbs the
second. The crash costs an install its uptime, not its disk. The count a guest
should actually *run* on is still set with `domain start VM -c N` after OOBE.

A guest-initiated reboot on that host has a second way to die, and clearing the
first one only exposes it: the firmware itself wedges, with OVMF asserting on a
stale MTRR default type (`MemDetect.c(1181)`) because WHPX does not reset the
MTRR MSRs across a guest reset. The domain is left *running* rather than paused,
spinning a core in `CpuDeadLoop` behind a window that never paints, which is how
the two are told apart. A new qemu process clears it; the vcpu count does not
affect it. Neither is contract -- both are one host, one qemu build and one
DEBUG firmware -- but between them they are why an install there is restarted at
each of Setup's own reboots rather than left to run through.

### Where the grammar bends, and why

Six places, each because the host cannot mean what the other one means.

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
- **`domain create -o ID` honours one id there, `winxp`, and ignores the
  rest.** There is no libosinfo, so no other id is consulted; it stays in the
  grammar so a command line written for one driver parses under the other, and
  says so when used. `winxp` -- libosinfo's own id, so it names the same guest
  on both drivers -- builds a legacy PC that 32-bit Windows XP has inbox drivers
  for: SeaBIOS, i440fx, IDE, rtl8139, cirrus, UHCI, the guest agent on an ISA
  serial port, one vcpu. The header of `modules/win/domain.ps1` has the table
  and what was measured. `VIRUTILS_OSINFO` is still ignored on that host: with
  no ISO detection there is nothing for a fallback to fall back from.
- **`domain create -u FILE` is a Windows-only addition, and `-o winxp` only.**
  It writes FILE, a `winnt.sif`, to a 1.44 MB floppy that XP Setup reads as A:.
  Without `-o winxp` it is refused by name: Windows 11 Setup reads
  `autounattend.xml`, which neither driver builds. The bash driver has no `-u`;
  virt-install's own `--unattend` is libosinfo's and is not wired through.
- **`domain create -c N` is refused on a Windows host.** A domain is created
  with one vcpu there and there is nothing to choose: section 7's defect kills a
  guest with more than one at its own reboot, which is what Windows Setup does
  twice. This is refuse-and-say-why rather than accept-and-ignore, because a
  count that was asked for and not honoured is exactly the silent acceptance the
  rule above forbids -- and it is refused *by name*, not as an unknown flag,
  since it is published here and was honoured on that driver until recently. The
  flag is not gone from the driver: `domain start VM -c N` honours it, on both
  hosts, and that is where a finished guest gets its cpus.
- **`domain create -p SPEC` and `-N` are Windows-only additions.** `-p` names a
  port forward, repeatable; without a libvirt network a forward is the only way
  into the guest, so create has to be able to make one. `-N` creates the domain
  without starting it. Neither exists on the Linux driver, and a script using
  them is a script for one host.
- **`snapshot` is not on the Windows driver at all, and is refused by name.**
  It was there, disk-only, and was removed; section 7 carries the measurements
  and the reasoning. This is the fourth possibility alongside honour, refuse and
  accept-and-say-so: *not offer the command*. What makes it honest is the
  refusal -- `virutil snapshot` on a Windows host exits 1 saying it is a
  Linux-host command and why, rather than "unknown module", because the verbs
  are published in section 2 and were on this driver until recently. A name that
  used to work must not come back as a typo.
- **`domain start -G` is accepted, warned about and not honoured**: qemu under
  WHPX has no headless console to detach from, and `-display none` would leave
  the guest with no way in at all. `-s`, `-m` and `-c` used to be listed here
  as refused, on the grounds that they "rewrite a libvirt domain config, and
  there is no domain config there". That was wrong, and they are honoured now.
  There is a domain config there -- the launcher is the domain, which is this
  document's own phrase, and `domain port` has always edited it in place. The
  bash driver's `-c` is `virsh setvcpus --config`: a persistent edit to a
  definition on disk, which is exactly what rewriting `-smp` in the launcher
  is. `-s` was never libvirt's at all -- both drivers end at `qemu-img resize`
  on the same image. Both require the domain shut off, on both hosts, for the
  same reason. This is the rare case of the grammar bending back straight.

On a macOS host the grammar bends in the same places as on Windows, for the
same user-mode-NAT reasons, and in two of its own:

- **`domain addr`** prints the forwards and says the guest address is not
  reachable, as on Windows. **`-o`** is accepted and ignored, as on Windows.
  **`-p` and `-N`** exist, as on Windows, and with no `-p` the default RDP
  forward is 13389 *or the next free port* on both hosts. Measured the hard
  way: a second domain on a port the first one holds is a qemu that dies at
  startup ("Could not set up host forwarding rule"), and before `domain_launch`
  learned to stop it, a swtpm left running for every such attempt. The Windows
  driver wrote a fixed 13389 until the same collision bit there; its `domain
  start` now also refuses a forward a running domain already holds, naming
  that domain and the `domain port` lines that move it.
- **`domain create -c N` is honoured.** The reboot defect that shaped the
  Windows driver's vcpu handling is WHPX's own (`whpx_get_xsave_state`), and
  it does not happen here: measured, a 4-vcpu Windows 11 on Arm guest went
  through Setup's own reboots into OOBE inside one qemu process, with nothing
  in its log. The default is half the host's cores, at most 8, at least the 2
  Windows 11 Setup insists on.
- **`domain start -G` is honoured**, unlike on Windows: it starts qemu with
  `-display none`, and the guest is reached over RDP or the agent. The launcher
  keeps `-display cocoa`; `-G` is an argument for one start, not an edit.
- **`domain shutdown` tries the guest agent first** and falls back to the ACPI
  power button, which is what `virsh shutdown` does on the Linux host -- the
  Windows driver sends ACPI only.
- **`snapshot revert` to a disk-only snapshot of a running domain powers it off
  first**, with `quit` rather than asking the guest, as `virsh snapshot-revert`
  does: what the guest had not written is exactly what a revert discards.

The same rule covers the environment. `VIRUTILS_OSINFO`, `VIRUTILS_NETWORK` and
`VIRUTILS_FIRMWARE` are read by the Windows driver and acted on by none of it,
so `domain create` names each one that has actually been set and says it is
being ignored. `VIRUTILS_FIRMWARE=bios` gets more than that: it asks for a
machine Windows 11 will not install on, so it is called out as unhonourable
rather than merely unused.
