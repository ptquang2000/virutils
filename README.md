# virutil

A small set of shell tools for driving Windows guests under libvirt/KVM from a
Linux host, including a WSL host talking to the Windows machine it runs on.
Everything hangs off a single driver, `virutil`, which dispatches to a set of
sourced modules under `modules/` — each a small function library with no build
step and no dependencies beyond the utilities it calls.

## Contents

- [Installation](#installation)
- [Artifacts and state](#artifacts-and-state)
- [Modules](#modules)
   - [domains](#domains)
   - [transfer](#transfer)
   - [guest](#guest)
   - [hardware](#hardware)
- [How files move](#how-files-move)
   - [Which guest is on the other side](#which-guest-is-on-the-other-side)
   - [Delivering](#delivering)
   - [What used to read through a snapshot](#what-used-to-read-through-a-snapshot)
   - [What used to be here](#what-used-to-be-here)
   - [Snapshots name every drive, and snapshot only the disks](#snapshots-name-every-drive-and-snapshot-only-the-disks)
   - [A shut-off domain gets a disk-only snapshot](#a-shut-off-domain-gets-a-disk-only-snapshot)
- [Guest prerequisites](#guest-prerequisites)
   - [A Windows guest](#a-windows-guest)
   - [A Linux guest](#a-linux-guest)
- [virutil sync](#virutil-sync)
   - [Synopsis](#synopsis)
   - [Description](#description)
   - [Arguments and options](#arguments-and-options)
   - [Files](#files)
   - [Configuration](#configuration)
      - [Settings](#settings)
      - [Fetch rules](#fetch-rules)
      - [Map rules](#map-rules)
      - [Excludes](#excludes)
      - [Cleanup rules](#cleanup-rules)
   - [Example](#example)
   - [How the delivery works](#how-the-delivery-works)
      - [On a Linux guest](#on-a-linux-guest)
   - [Notes](#notes)
- [virutil pull](#virutil-pull)
- [virutil push](#virutil-push)
   - [Delivering the payload](#delivering-the-payload)
- [virutil domain](#virutil-domain)
   - [create](#create)
   - [Environment](#environment)
   - [delete](#delete)
   - [start](#start)
   - [list, shutdown, addr](#list-shutdown-addr)
   - [port](#port)
- [virutil usb](#virutil-usb)
   - [USB passthrough under WSL, with usbipd](#usb-passthrough-under-wsl-with-usbipd)
- [Requirements](#requirements)
- [See also](#see-also)

## Installation

```sh
git clone https://github.com/yourname/virutils.git
cd virutils
./install.sh
```

`install.sh` symlinks `virutil` into `~/.local/bin` and the zsh completion into
`${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions`, then reports on the
[requirements](#requirements) below, per module — nothing there is fatal, since
a host that only ever runs `virutil exec` has no use for `virt-install`.

The links point at the checkout, and `virutil` resolves its module directory
through the symlink rather than around it, so the checkout is the installed
copy: `git pull` is the upgrade path, and nothing needs reinstalling. Re-running
the script is harmless.

| Option | |
| --- | --- |
| `--bin DIR` | where to link `virutil`, also `$BIN` |
| `--completions DIR` | where to link `_virutil`, also `$COMP_DIR` |
| `--no-completions` | skip the zsh completion |
| `--check` | only report on dependencies, install nothing |
| `--uninstall` | remove the links, leave the checkout alone |

For the completion to be picked up, its directory has to be on `fpath` before
`compinit` runs:

```sh
fpath+=( "${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions" )
```

Installed as part of [the dotfiles](https://github.com/yourname/.dotfiles),
none of this is needed: `setup.sh` links `virutils/vir*` into `~/.local/bin`
itself and `.zshrc` puts `virutils/completions` on `fpath` directly.

## Artifacts and state

Everything `virutil` leaves on the host lives under one root, `~/.virutils/`,
so the whole footprint is a single directory you can inspect, back up, or move
in one go. The layout, and what fills each subdirectory:

| Path | Filled by |
| --- | --- |
| `~/.virutils/conf/` | sync configs (`sync.conf`, `NAME.conf`) |
| `~/.virutils/images/` | domain disks (`domain create`), snapshot overlays and memory files (`snapshot`) |
| `~/.virutils/staging/` | sync's incremental staging trees (`@staging` names) |
| `~/.virutils/ports/` | `domain port` forward state and relay logs |
| `~/.virutils/mnt/` | host mount points left by removed commands, swept by `domain delete` (`<VM>`) |

Installation links are the exception and follow the [installation
above](#installation): `virutil` in `~/.local/bin` and `_virutil` in the zsh
`site-functions` directory — symlinks into the checkout, not copies.

### Relocating the root

Set `VIRUTILS_DIR` to move everything at once — configs, images, staging,
port state and mount points:

```sh
export VIRUTILS_DIR=/mnt/big/virutils
```

Each piece can also be moved on its own (`VIRUTILS_CONF_DIR`,
`VIRUTILS_IMAGE_DIR`, `VIRUTILS_STAGING_ROOT`, `VIRUTILS_PORT_DIR`,
`VIRUTILS_MNT_ROOT`), each defaulting under the root. Every one of these is
spelled with the plural `VIRUTILS_` prefix; the singular `VIRUTIL_*` names
are still read, second, and say so once when they are. Existing
configs in `~/.config/virutils/` keep working — see [virutil sync](#virutil-sync).

### A note on who owns the files

Everything here is owned by you, and most of it never leaves the host. The one
exception is anything qemu has to read or write: the domain disks and the
snapshot overlays and memory files are all opened by the
`qemu` process (usually running as `libvirt-qemu`), not just by you.

libvirt relabels the *files* it opens, but never the directories above them, so
a home directory with mode `0700` makes a domain fail to start with a bare
"Permission denied" — and now that images default into `~/.virutils/`, that is
the default configuration, not an edge case. `virutil` checks this up front
(whenever it is about to create an image qemu must reach) and prints the fix:

```
libvirt-qemu cannot traverse to /home/you/.virutils/images:
  /home/you/.virutils
  /home/you
The domain will fail to start with 'permission denied'. Fix it with:
  sudo setfacl -m u:libvirt-qemu:x /home/you/.virutils /home/you
```

When qemu runs as `root` (the WSL2 default) the check is skipped: root needs
nothing. If you moved `VIRUTILS_IMAGE_DIR` to a directory qemu can already
reach — the old `/var/lib/libvirt/images`, or anywhere else world-traversable —
the warning simply never fires.

## Modules

The seven modules fall into four groups, which is also the order
`virutil help` prints them in. The three transfer modules additionally share the
host-side machinery in `modules/xfer` and `modules/guest`, which is
[how the bytes move](#how-files-move).

### domains

| Module | Purpose | Usage |
| --- | --- | --- |
| `domain` | The domain lifecycle: create one from an install ISO with a KVM-tuned profile, delete one along with its disks, and the everyday operations in between. | `virutil domain {create\|delete\|list\|start\|shutdown\|addr\|port} [VM] [ISO] [OPTIONS]` |
| `snapshot` | External snapshots (disk and memory) for libvirt domains. | `virutil snapshot {create\|list\|revert\|delete} VM [SNAP]` |

### transfer

| Module | Purpose | Usage |
| --- | --- | --- |
| `sync` | Fetch a project's build output from a Windows host and push it into a guest's `C:` drive. | `virutil sync VM [-c NAME\|PATH]` |
| `pull` | Copy a file or directory out of a **running** guest. | `virutil pull VM SRC DST` |
| `push` | Copy a file or directory from the host into a guest's `C:` drive. | `virutil push VM SRC DST` |

All three write the same C:-shaped tree — see
[How files move](#how-files-move). `sync` and `push` deliver into a **running**
guest over its own NIC, moving only what changed; `pull` reads back the same
way.

### guest

| Module | Purpose | Usage |
| --- | --- | --- |
| `exec` | Run commands inside a guest through the QEMU guest agent, with no guest networking required. `cmd` and `ps` address a Windows guest, `sh` a Linux one. | `virutil exec {ping\|cmd\|ps\|sh} VM [FLAGS] [ARGS]` |

### hardware

| Module | Purpose | Usage |
| --- | --- | --- |
| `usb` | Pass a physical host USB device through to a guest, hot-plugged: a libvirt `<hostdev>` here, `device_add` over the QEMU monitor on the Windows driver. | `virutil usb {list\|show\|attach\|detach} [VM] [VENDOR:PRODUCT]` |

`virutil` alone, or `virutil help`, prints the module list. `modules/parser`
handles the top-level dispatch plus the helpers every module shares; each
module file declares its own subcommands. Only `sync` is driven by a config
file; the rest take everything on the command line. The remainder of this
document covers `virutil sync`, then `virutil pull`, then `virutil push`, then
`virutil domain`.

## How files move

`sync`, `pull` and `push` differ in *what* they move. There is one way it
moves, and all three share it.

**Over the guest's own network.** The host stands up one throwaway
export on the address the guest already reaches it at, and the guest's own
copier does the copying, driven through the QEMU guest agent. Nothing is
mounted on either side, no drive letter or device appears in the guest, and the
guest keeps running throughout. Writing (`sync`, `push`) exports the payload
read-only and the guest fetches from it; reading (`pull`) exports the
destination directory writable and the guest copies into it. The part that
matters on a second run is the copier: it compares the two trees and copies only
the difference, so a re-run after rebuilding one file moves one file and leaves
the rest untouched down to their timestamps.

Which export, and which copier, follows from the guest's OS — there is no
transport here that both kinds of guest can speak:

| Guest | Export | Copier | Guest-side shell | Host cost |
| --- | --- | --- | --- | --- |
| **Windows** | SMB share, port 445 | `robocopy` | `powershell` | `smbd`, and root to bind 445 |
| **Linux** | `rsync` daemon, ephemeral port | `rsync` | `/bin/sh` | `rsync`; **no root, no privileged port** |

`sync` learns which from [`@guest`](#settings) in its config. `pull` and `push`
have no config to be told by, so they **ask the guest** — see
[Which guest is on the other side](#which-guest-is-on-the-other-side). The Linux
side is the cheaper one, and every way in
which it is cheaper comes from one thing: rsync's port is not fixed. Port 445 is
what SMB *means* to a Windows client and no ephemeral-port trick can move it,
which is what makes the Windows path bind a privileged port, escalate to do it,
need a terminal to prime the credential on, and refuse to run when something
already holds 445 — on WSL, usually the Windows host's own file sharing. None of
that applies to a Linux guest, so that path also runs unattended.

Direction is the share's, not the transport's. `sync` and `push` export the
payload read-only and the guest fetches from it; `pull` exports the destination
directory writable and the guest copies into it. Same `smbd`, same random
one-transfer share name, same single bind address, same `robocopy` on the far
side skipping whatever the other end already holds.

| | over the network (`sync`, `push`, `pull`) |
| --- | --- |
| Guest must be | **running**, with its agent answering |
| Guest OS | Windows or Linux |
| What is mounted | nothing |
| Guest side | `robocopy` or `rsync`, via the agent |
| Host needs | `smbd` + root for 445 (Windows guest), or `rsync` and no root at all (Linux guest) |
| Fixed cost per run | an agent round trip |
| Moves on a re-run | only what changed |

### Which guest is on the other side

`sync` is told, by `@guest` in its config. `push` and `pull` have no config, so
they ask — and the asking is free, because the transport they are about to use
already needs the agent to drive the copy, so there is a round trip to spend
either way.

```sh
$ virsh qemu-agent-command ubuntu '{"execute":"guest-get-osinfo"}'
{"return":{"name":"Ubuntu","id":"ubuntu","pretty-name":"Ubuntu 20.04.6 LTS",...}}
```

Three sources, in order, first answer wins:

| Source | Says | Works when |
| --- | --- | --- |
| `guest-get-osinfo`, via the agent | `mswindows`, or a distribution id | the agent answers **and** is QEMU 5.1 or newer |
| `libosinfo:os id` in the domain XML | `http://microsoft.com/win/11`, `http://ubuntu.com/ubuntu/20.04` | `virt-install` created the domain — so every `virutil domain create` one |
| the historical default, `windows` | — | always; it warns first |

Asked rather than flagged on purpose. A `--linux` flag is one more thing to get
wrong on a command whose failure mode is "the guest was told to run `robocopy`
and does not have it", and the guest already knows the answer. The fallback to
`windows` means a host where nothing answers behaves exactly as it did before
any of this existed.

Anything that is not Windows is driven as Linux — `/bin/sh` and `rsync`, which
is also true of the BSDs even though this vocabulary has no name for them. The
alternative, an allow-list of distribution ids, would refuse to work on a guest
that would have been fine and would need editing every time a new one appeared.

`sync` uses the same probe as a cross-check: if the guest reports something
other than `@guest` says, it warns and carries on with what the config asked
for. It does not silently switch — `@guest` decides which shell the config's run
rules were written for, and the config is the thing a person can fix.

### Delivering

Delivering to a **Windows** guest needs four things at once, and none of them is
optional: the guest running, its agent answering, a route from the guest back to
this host, and `smbd` plus root on the host to bind port 445. Port 445 is not
negotiable — it is what SMB means to a Windows client, and no ephemeral-port
trick can move it — so this is the one place virutil binds a privileged port, and
it refuses to run if something already holds it. On WSL that something is usually
the Windows host's own file sharing.

Delivering to a **Linux** guest needs the first three and nothing else. The
payload is served by an `rsync` daemon on an ephemeral port picked per transfer,
so there is no privileged bind, no `sudo`, no credential to prime, and nothing
for the Windows host's file sharing to collide with. `rsync` has to be installed
in the guest — it is the copier — and the run says so plainly if it is not.

When one of those four is missing, virutil **says which and stops**, naming the
piece that is missing rather than falling back to anything.

```sh
virutil sync win11              # guest keeps running; only changed files cross
virutil push win11 ./f.txt 'C:\'
```

Because the credential for port 445 is primed synchronously, before `smbd` is
backgrounded, **a delivery to a Windows guest needs a terminal to ask on.** Run
without one — from `cron`, from CI, from a detached script — and it stops at once
with `sudo: a terminal is required`, rather than hanging. Give `smbd` a
`NOPASSWD` rule if you need this unattended.

**A delivery to a Linux guest has no such requirement**, and this is the
practical difference between the two paths rather than a footnote: it escalates
nothing, so it is the one transport here that works from `cron` or CI as it
stands.

### What used to read through a snapshot

`pull` used to leave the guest running by taking a disk-only external snapshot,
mounting the frozen base read-only, and folding the overlay back in with
`virsh blockcommit` at the end. It does not any more, and the reason is that the
commit merges the **whole** backing chain unless it is told otherwise — so on a
domain carrying `virutil snapshot` records, every pull flattened post-snapshot
writes into the image those records' disk state was measured against. Their
memory images stayed where they were, and the next `snapshot revert` restored
old RAM onto a newer disk, which Windows answers with a bluescreen.

A transfer has no business rewriting the images underneath a snapshot. So the
read is now the same SMB transport as the write, in the other direction, and it
does not open the disk image at all.

### What used to be here

Three transports have been removed, and none of them is coming back:

- **virtio-fs**, selected with `-t`/`--transport` or `@transport`. Gone, and with
   it the share device and the shared-memfd memory backing it needed. Sync's
   `>pre`/`>post` run rules outlived it: they run through the guest agent
   against a guest that stays up, which is what the SMB delivery does anyway.
- **HTTP**, selected with `--live`: the host served one payload with `python3`
   and the guest fetched it with `curl.exe`, carrying a directory as a single
   `tar` that was unpacked whole every time. SMB does the same job and compares
   trees, so a re-push moves what changed rather than all of it; there was
   nothing left for HTTP to be better at. `tar.exe` is no longer needed in the
   guest, and `python3` is no longer part of any transfer — `virutil exec` still
   uses it.
- **The disk image**, selected with `--disk`: the host attached the guest's own
   qcow2 with `qemu-nbd`, mounted its largest NTFS partition with `ntfs-3g` and
   read or wrote it directly, with a running guest shut down around the copy.
   It needed nothing of the guest, and that was the whole of what it was better
   at — it cost the guest's uptime, moved every mapped file whether it had
   changed or not, worked on Windows guests only, and needed `qemu-nbd`,
   `ntfs-3g` and root to mount on the host. `sync`'s `>pre`/`>post` run rules
   were skipped under it, and its cleanup rules ran through a mount rather than
   in the guest.

A config still carrying `@transport`, `@nbd`, `@mnt` or `@shutdown_timeout` is
rejected with its line number rather than quietly ignored, `-t` is no longer
accepted on the command line, and `--live`, `--smb` and `--disk` each stop with
a message naming what replaced them rather than being silently accepted.

A domain created by an older virutil may still have a `virtio-fs` share in its
definition. Nothing here uses it, and libvirt will refuse to start the domain if
the directory it exports has since been removed; strip it once, with the domain
shut off:

```sh
virsh --connect qemu:///system dumpxml VM     # find the <filesystem> element
virt-xml --connect qemu:///system VM --remove-device --filesystem all --define
```

`virutil domain delete` sweeps the leftover share directory either way.

### Snapshots name every drive, and snapshot only the disks

`virutil snapshot create` passes libvirt a `--diskspec` for *every* block device
the domain has, not just the ones being snapshotted. The disks get
`snapshot=external` and an overlay under the image directory; everything else —
cdroms, floppies, loaded or empty — gets `snapshot=no`.

The explicit `no` is the whole point. A device left out of `--diskspec` is not a
device left alone: libvirt's default for it is an external overlay named
`<source>.<epoch>`, created **in the source's own directory**. For a loaded ISO
that means an overlay written next to the ISO, and an ISO kept under `/mnt/c` is
on a 9p mount where libvirt cannot label a file it has just created. The create
fails there, and where it gets through, the record carries the drive as a
snapshotted disk and the *revert* fails on it instead — half-done: memory
restored, disk switched back to the base image, no new overlay over it, guest
left paused. Unpause it and the guest writes straight into the image the
snapshot is defined against.

Naming the drives is the fix, and it is the same fix whichever state the domain
is in. Ejecting them was not: a shut-off domain has no tray to open, so a create
against one snapshotted the ISOs anyway — and a record written with the drives
empty is a revert that takes the media away from the guest, out of a memory
image that was captured with it present.

### A shut-off domain gets a disk-only snapshot

The memory half of the snapshot is for a *running* guest: libvirt refuses a `--memspec` for a domain that is not running,
so `virutil snapshot create` on a shut-off domain skips it and takes a
disk-only external snapshot instead. Everything else is the same — the overlay
files, the records, and `revert`/`list`/`delete` all work. The one difference
is on the way back: with no saved memory to restore, a revert boots the guest
fresh from the disk state rather than resuming it mid-run.


## Guest prerequisites

### A Windows guest

Three pieces of software go **inside** the Windows guest. Two of them come off
the `virtio-win` ISO; the SPICE guest tools are downloaded separately.
`virutil domain create` attaches that ISO as a second cdrom automatically, so on
a fresh install it is already in the guest's drive list; otherwise download it
once:

- `virtio-win.iso` — <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>
- SPICE guest tools — <https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe>

The **QEMU guest agent is required to move files into a guest**: `sync` and
`push` drive the fetch through it, so a guest without `qemu-ga` answering cannot
be delivered to. It is also what `virutil exec`, `virutil domain port` on a
statically addressed guest, and `virsh shutdown --mode agent` need.

| What | Where it comes from | Needed by |
| --- | --- | --- |
| **virtio drivers** (`viostor`, `NetKVM`) | `virtio-win` ISO, or `virtio-win-guest-tools.exe` on it | booting at all — the installer cannot see a virtio disk without `viostor` |
| **QEMU guest agent** (`qemu-ga`) | `virtio-win-guest-tools.exe`, or `guest-agent\qemu-ga-x86_64.msi` on the ISO | `sync`, `push` and `pull`, `virutil exec`, and `virsh shutdown --mode agent` |
| **SPICE guest agent** (`spice-vdagent`) | [spice-guest-tools](https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe) | the `spice` display and `spicevmc` channel of every `virutil domain create` domain — clipboard sharing and display auto-resize |

### A Linux guest

Two things, and both are usually a package away:

| What | Where it comes from | Needed by |
| --- | --- | --- |
| **QEMU guest agent** (`qemu-ga`) | `apt install qemu-guest-agent`, `dnf install qemu-guest-agent` | `virutil sync`, `virutil exec sh` |
| **rsync** | `apt install rsync`, `dnf install rsync` | `virutil sync`, `push` and `pull` — it is the guest-side copier for all three |

No drivers to install: virtio storage and net are in every distribution kernel,
so a Linux guest boots on them as shipped. Nothing else is needed — the delivery
serves the payload over the guest's own NIC, so the guest needs no `sshd`, no
route beyond the one it already has to this host, and nothing listening.

Check both at once:

```sh
virutil exec ping ubuntu                    # is the agent answering?
virutil exec sh   ubuntu 'rsync --version | head -1'
```

The domain also needs the agent's virtio channel in its XML, which
`virutil domain create` adds and most existing domains already have:

```xml
<channel type='unix'>
  <target type='virtio' name='org.qemu.guest_agent.0'/>
</channel>
```

A channel that reads `state='connected'` in `virsh dumpxml` is the *host* end of
the port; it says nothing about whether anything in the guest is listening
behind it. `virutil exec ping` is the question that actually answers that.

`sync` needs `@guest=linux` in its config to address a Linux guest — see
[Settings](#settings). Without it the run assumes Windows, stands up an SMB
share and asks the guest to run `robocopy`, which is not there. `push` and
`pull` need no such setting: they detect the guest themselves, as above.

The agent has to come back **after a reboot**, not just once. If
`virutil exec ping` worked earlier and does not now, and
`virsh dumpxml <vm> | grep guest_agent` shows `state='disconnected'`, the service
is installed but not enabled:

```sh
sudo systemctl enable --now qemu-guest-agent
```

**During Windows Setup**, when no disk is listed, use *Load driver* → the
`virtio-win` CD → `amd64\<os>` to load `viostor`.

**After the install**, from an elevated prompt in the guest — `E:` being the
`virtio-win` CD:

```
E:\virtio-win-guest-tools.exe /install /quiet
```

That single installer covers the drivers and `qemu-ga`. Then install the SPICE
guest tools (`spice-guest-tools-latest.exe`) from an elevated prompt — without
the `spice-vdagent` there is no clipboard sharing and the display does not
auto-resize.

The guest-agent channel itself is part of every domain `virutil domain create`
makes, so nothing has to be added on the host side. Confirm it from the host:

```
virutil exec ping VM        # the agent answers
```

## virutil sync

### Synopsis

```
virutil sync VM [-c NAME|PATH]
virutil sync -h
```

### Description

`virutil sync` copies a build tree into a **running** guest, which pulls it over
its own network and takes only the files that changed — so the run after a
rebuild of one file moves one file, and the guest never goes down. See
[How files move](#how-files-move). It works in two halves:

```
build tree --(fetch)--> staging dir --(map)--> guest filesystem
```

The guest may be Windows (the default) or Linux, set by
[`@guest`](#settings). It changes only the guest half of the delivery; the fetch,
the staging tree, the excludes and the map rules are host-side and identical for
both.

**Fetch** mirrors selected directories out of the build tree into a staging
directory under `~/.virutils/staging/`, applying the exclude patterns. The staging layout is
normally arranged to mirror what will land in the guest, so the map rules stay
trivial.

**Push** runs the map rules into a delivery tree on the host — the
same rsync, the same excludes and destinations, into a scratch directory —
exports that tree read-only on the address the guest reaches
this host at, and has the guest copy it onto its own root: an SMB share and
`robocopy` onto `C:` for a Windows guest, an `rsync` daemon and `rsync` onto `/`
for a Linux one. Only the
files that differ from what the guest already holds cross the wire; the rest keep
their timestamps to the millisecond. Any `>pre` run rules go to the guest just
before it fetches, any directories listed for cleanup are emptied in the guest
afterwards, `>post` rules run last, and the share and the tree are torn down
however the run ends. Nothing is mounted and nothing is shut down.

Run it as yourself, **not** under `sudo`. It refuses to start when invoked under
`sudo`, because `$HOME` — and therefore config discovery — resolves to root's
home on any host whose sudoers sets `always_set_home`. Only the commands that
genuinely need root is escalated individually — `smbd`, and only for a Windows
guest — and you are prompted once, before anything is served. Every `virsh` call
runs unprivileged, which requires membership of the `libvirt` group. The
delivery tree is built as you, so the copy phase and the cleanup pass need no
privilege of their own.

Because the prompt comes before `smbd` is backgrounded, a run needs a terminal to
ask on: see [Delivering](#delivering).

### Arguments and options

| Argument | Description |
| --- | --- |
| `VM` | libvirt domain delivered into. It has to be **running**, since the delivery goes over its own network. Required. |

| Option | Description |
| --- | --- |
| `-c`, `--config NAME\|PATH` | Config to use. A value containing `/` is a path, taken as given. Anything else names a config, looked up in `~/.virutils/conf/` first and then `~/.config/virutils/`, with `.conf` appended when absent — so `-c win11` reads `~/.virutils/conf/win11.conf` if it exists, else `~/.config/virutils/win11.conf`. Defaults to `sync.conf`, resolved the same way. |
| `-h`, `--help` | Print usage and exit. |

The domain is an argument rather than a config setting, so one config —
a project's build tree and where its pieces land on `C:` — can be pointed at
any guest that runs it.

Path-or-name is decided from the spelling alone, never from what happens to
exist on disk, so the same command means the same config from any directory. One
consequence worth knowing: `-c win11` can never refer to a file in the current
directory — write `-c ./win11.conf` for that.

Apart from `VM`, there are no other arguments. Everything else lives in the
config.

### Files

| Path | Description |
| --- | --- |
| `~/.virutils/conf/sync.conf` | Default config. Also the first place a missing one is looked for. |
| `~/.config/virutils/sync.conf` | Legacy location, searched when the new one has no `sync.conf` — so existing installs keep working untouched. |
| `~/.virutils/conf/NAME.conf` | Additional configs, selected with `-c NAME` (searched before the legacy `~/.config/virutils/NAME.conf`). |
| `~/.virutils/staging/<@staging>` | Staging directory, refreshed from `@repo` on every run. |

A missing config is a fatal error naming the exact path that was looked for.
Nothing is generated for you, and nothing else is touched first.

### Configuration

One directive per line. `#` starts a comment, blank lines are ignored, and
leading and trailing whitespace is stripped. The whole file is parsed before
anything is touched, so a typo fails the run instead of half-completing it — an
unknown setting or an unrecognised directive is reported with its line number.

| Form | Meaning |
| --- | --- |
| `@key=value` | A setting. See [Settings](#settings). |
| `<src\|subdir` | Fetch: copy the contents of `<@repo>/src` into `<staging>/subdir`. |
| `globs\|subdir` | Map: copy `<staging>/globs` into `<@dest>/subdir` in the guest. |
| `!pat pat ...` | `rsync --exclude` patterns, applied to both the fetch and the map. |
| `-path` | Delete this guest path after copying — a directory is emptied and kept, a file is removed. |
| `>pre CMD` | Run `CMD` in the guest's shell before the files reach it — PowerShell, or `/bin/sh` when `@guest=linux`. |
| `>post CMD` | Run `CMD` in the guest's shell after they have. |
| `>pre-ui CMD` | Like `>pre`, but launch `CMD` on the guest's *interactive desktop* via PsExec (see `virutil ui`). Windows guest only. |
| `>post-ui CMD` | Like `>post`, on the interactive desktop — e.g. relaunch a GUI app the sync replaced. |

Map rules are the only unsigilled form. A line starting with punctuation that is
not one of the sigils above is treated as a mistyped directive, not as a glob,
and is rejected.

#### Settings

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `@repo` | yes | — | Root of the build tree on the host. Fetch sources are relative to it. |
| `@staging` | yes | — | Staging directory *name*. Always placed under `~/.virutils/staging/`, whatever is written here. |
| `@guest` | no | `windows` | Which OS the guest runs: `windows` or `linux`. It selects the guest half of the delivery — SMB + `robocopy` + PowerShell, or an `rsync` daemon + `rsync` + `/bin/sh`. |
| `@dest` | no | *(empty)* | Install directory in the guest, relative to the guest's root — `C:\`, or `/` when `@guest=linux`. Every map destination hangs off it, so the install path is spelled once. Empty means that root itself. |

#### Fetch rules

```
<bin/Release|.
<MyApp/www/brand-default/translationsUI|brand-default/translationsUI
```

The part before `|` is a directory relative to `@repo`; the part after is a
subdirectory of the staging tree, where `.` means its root. The *contents* of
the source are copied, not the directory itself.

A fetch source that does not exist is a warning, not an error, and is skipped.
This is deliberate: optional third-party trees can be listed unconditionally and
simply be absent in some checkouts.

#### Map rules

```
*|
qt-deployment-lib/*|
app.exe|bin
```

The part before `|` is a space-separated list of globs, expanded relative to the
staging directory. The part after is a destination relative to `@dest`; empty
means `@dest` itself. A trailing `/*` copies a directory's contents rather than
the directory. Globs matching nothing are warned about and skipped.

#### Excludes

```
!*.pdb *.ipdb *.lib *.ilk *.exp *.obj
!*.tlog *.lastbuildstate *.log *.pch
```

Ordinary `rsync` exclude patterns, applied to both halves of the pipeline, so
build leftovers stay out of the staging tree *and* out of the guest. Repeat the
directive as often as convenient; the lists are concatenated.

#### Cleanup rules

```
-ProgramData/MyApp/logs
-Users/*/AppData/Local/MyApp/logs
```

```
-Windows/System32/drivers/myapp.sys
```

Each path is cleaned in the guest after the copy. What happens depends on what
the pattern resolved to, not on how it is written: a **directory** has its
contents removed and the directory itself is kept, and a **file** is deleted. A
stale driver and a log directory are both "state the guest must not keep", and
spelling them differently would only be a trap.

Paths are relative to the root of `C:` — not to `@dest` — and are matched
**case-insensitively**, so `Users/*` behaves the way it would in Windows. A path
that is not present is reported and skipped, and one the guest has locked costs
that entry a warning, not the rest of the cleanup.

Two safety rules apply, so a mistyped pattern cannot empty a top-level
directory: the expansion must stay inside the guest's root, and it must be at
least two levels deep.

#### Run rules

```
>pre  Stop-Service -Name myapp
>post Start-Service -Name myapp
```

Free-text PowerShell, run in the guest through the guest agent — the same route
`virutil exec ps` takes — in config order, `>pre` before the guest fetches the
delivery and `>post` after the cleanup rules have run. The phase keyword is
required: a command is free text, so a missing one cannot be told from a command
that happens to start with `pre`.

The first failure stops the run. A run rule is there to make the copy land
correctly, so carrying on past one that did not happen would deliver a
half-installed guest and report success.

They need the guest up and answering on the agent, so they run only when it is —
which the delivery already requires. A guest that went away mid-run has its
rules **skipped** with a note saying so, rather than failing the copy that
already landed.

`>pre-ui` and `>post-ui` run at the same two points, but launch on the guest's
**interactive desktop** instead of in the session-0 agent shell:

```
>post Stop-Service -Name myapp
>post-ui "C:\Program Files\MyApp\MyApp.exe" --restored
```

An ordinary `>post` command runs as SYSTEM in session 0, where a window it opens
is invisible to the logged-in user. A `>post-ui` command is handed to PsExec's
`-i` so it lands on the desktop the user is looking at — the usual reason being
to relaunch a GUI app the sync just replaced. It is fire-and-forget: the rule
returns as soon as the process starts, and the process runs as SYSTEM on that
desktop (add `-u`/`-p` to the command if it must be the logged-in user).

The command is a command line, not a bare exe, so quote a path that contains
spaces exactly as you would at a prompt. These rules are Windows-only — a
`@guest=linux` config that carries one is refused — and they need PsExec staged
in the guest first (`virutil ui setup VM`); a config that runs before that fails
with the same "run `virutil ui setup`" message `virutil ui run` gives.

### Example

`~/.virutils/conf/sync.conf`:

```
@repo=/mnt/c/Users/me/work/myproject
@staging=vmsync/myproject
@dest=Program Files (x86)/Example/Product

# fetch: build tree -> staging
<bin/Release|.
<thirdparty/openssl-bin/vc14/x86/Release|.

# excludes: build leftovers that must not reach the guest
!*.pdb *.lib *.exp *.obj *.log

# map: staging -> guest
*|
helper.exe|helpers

# cleanup: start the guest with no stale logs
-ProgramData/Example/logs
```

Then:

```
./virutil sync win11
```

Or, keeping several profiles side by side, and pointing them at any guest:

```
./virutil sync win10 -c win10
./virutil sync win11 -c ~/scratch/experiment.conf
```

#### A Linux guest

The same file with `@guest=linux` added, `@dest` spelled from `/` instead of
`C:\`, and run rules written for `sh` rather than PowerShell. Everything else —
fetch, excludes, map, cleanup — is identical, because it is all host-side:

```
@guest=linux
@repo=/home/me/work/myproject
@staging=myproject-linux

# relative to /, so this is /usr/bin/myproduct
@dest=usr/bin/myproduct

# fetch: build tree -> staging
<build/bin|bin
<build/lib|lib

# excludes: build leftovers and debug symbols
!*.debug *.o *.a
!CMakeFiles CMakeCache.txt

# map: staging -> guest
*|

# the service holds its own binaries open
>pre systemctl stop myproduct || true

# cleanup: start the guest with no stale logs
-var/log/myproduct

>post systemctl start myproduct
```

```
./virutil sync ubuntu -c myproject-linux
```

Note the `|| true` on the `>pre` rule. A run rule that fails ends the run — the
rule exists to make the copy land correctly, so carrying on past one that did
not happen would deliver a half-installed guest and report success — and
`systemctl stop` on a unit that is not loaded is a failure. `>post` is left
strict on purpose: if the service will not start after the delivery, that is
worth hearing about.

### How the delivery works

The second half of the run is a delivery the running guest pulls for itself. The
fetch is host-to-host and knows nothing about it:

```
Windows build tree --(fetch)--> staging --(map)--> delivery tree --(robocopy)--> C:
```

Everything below describes a Windows guest, which is the default. With
`@guest=linux` the shape is the same and the last two arrows change:

```
build tree --(fetch)--> staging --(map)--> delivery tree --(rsync)--> /
```

See [On a Linux guest](#on-a-linux-guest) for what differs.

The map rules build their `C:`-shaped tree in a scratch directory under
`~/.virutils/tmp/`; the host exports that directory as a
read-only, anonymous SMB share on the one address the guest reaches it at; and
the guest is told, through the guest agent, to `robocopy` the whole share onto
`C:\`. Because the delivery tree's layout already *is* the layout the rules asked
for, that is one command and one round trip, whatever the rules said.

Two things follow, and between them they are the reason it exists:

* **The guest stays up.** Nothing is mounted on the host, nothing is shut down,
  no drive letter or device appears in the guest, and its disk image is never
  opened.
* **Only what changed crosses.** `robocopy` compares every file against what the
  guest already holds and skips the ones that match, so re-syncing a build in
  which one DLL changed moves one DLL — which is what `sync` is actually for, a
  build tree resynced over and over.

```
$ virutil sync win11
config: /home/me/.virutils/conf/sync.conf
  2 fetch, 2 map, 1 exclude, 1 cleanup
  staging: /home/me/.virutils/staging/vmsync/myproject
  domain: win11
  delivery: SMB into the running guest
fetch: /mnt/c/Users/me/work/myproject
   bin/Release -> .
   thirdparty/openssl-bin/vc14/x86/Release -> .
-> C:\Program Files (x86)\Example\Product (14 item(s))
-> C:\Program Files (x86)\Example\Product\helpers (1 item(s))
deliver: 15 file(s), 21.7 MiB -> win11 C:\
win11: 15 files offered, the ones that differed copied in 1.2s
   emptied C:\ProgramData\Example\logs (3 entries)
copy complete -> win11
```

The count and size on the `deliver` line are the whole tree — what was
*offered* — because that is the number printed before the transfer, where its job
is to say how long to wait. How much of it actually moved is the line after, and
it is deliberately coarse: `robocopy` keeps its per-file counts only in a summary
that Windows localises, so a non-English guest would have it parsed wrong rather
than not parsed at all. The duration is the guest's own stopwatch around the
`robocopy`, not the host's wall clock, which would fold in the agent round trip
and `powershell.exe` starting up.

**Excludes need no translation.** They are rsync's, applied while the delivery
tree is built, so what the guest is offered is already filtered and `robocopy`
needs no `/XF` or `/XD`.

**Cleanup rules run in the guest.** Each `-pattern` becomes a `Remove-Item`
driven by the agent: the pattern is expanded guest-side (so case-insensitively,
and after the delivery), every directory it names has its contents removed but never
itself, and every file it names is deleted. The two-levels-down rule is enforced twice — once here on the pattern,
once in the guest on what the pattern actually resolved to, since a wildcard can
only be judged after it expands. A file the guest has locked costs that file a
warning, not the rest of the cleanup.

**Deletions are never inferred.** The delivery is `robocopy /E`, not `/MIR`.
`/MIR` would delete everything under the destination that the source does not
have, and the destination here is the root of `C:`. What may be deleted is what a
cleanup rule names, and nothing else.

**Map destinations may not contain `..`.** They never usefully could, and here one
would put files outside the share entirely, so a config with one is refused by
name.

What it needs, and what it does when it cannot have it:

| Requirement | If missing |
| --- | --- |
| Guest running | Refused, naming the state and pointing at `domain start`. |
| QEMU guest agent answering | Refused; there is nothing to drive the fetch. |
| A route from the guest back to this host | Refused; a guest on an isolated network cannot be delivered to. |
| `smbd` (Samba) on the host — *Windows guest only* | Refused, naming the package to install. |
| Root on the host to bind TCP 445 — *Windows guest only* | Prompted for once, up front, before `smbd` is backgrounded — where the prompt still has a terminal. Without a terminal the run stops rather than hanging. |
| Nothing else already on TCP 445 — *Windows guest only* | Refused. SMB cannot be served to a Windows client on any other port; under WSL the listener is usually the Windows host's own file sharing. |
| `rsync` on the host and in the guest — *Linux guest only* | Refused, naming which side is missing it. |

Every one of those is a refusal that names what is missing, never a silent
fallback to some other route.

The share is as narrow as it can be made: a random name, read-only, guest-only,
bound to the one address that reaches the guest rather than the wildcard, holding
nothing but this run's delivery tree, and retired along with that tree however
the run ends. `robocopy` against a UNC path is a redirector read, so the guest
mounts nothing and keeps no share of its own — `net use` in the guest stays empty.

The cost, said plainly: the delivery tree is a real copy of the mapped files, made
on the host on every run. It is local and it is deleted at the end, but a large
map does pay for it in host I/O — and the run refuses up front if the staging
tree would not fit in `~/.virutils/tmp/`, rather than filling the filesystem
halfway through.

#### On a Linux guest

With `@guest=linux` everything host-side is unchanged — same fetch, same
staging tree, same excludes, same map rules building the same tree in
`~/.virutils/tmp/`. What changes is the pair at the far end. The host serves that
tree from an **`rsync` daemon** on an ephemeral port bound to the one address
that reaches the guest, under a random one-transfer module name with
`list = no`; and the guest is told, through the same guest agent, to
`rsync -rlptD` the whole module onto `/`.

```
$ virutil sync ubuntu -c myproject-linux
config: /home/me/.config/virutils/myproject-linux.conf
  4 fetch, 1 map, 10 exclude, 2 cleanup, 3 run
  staging: /home/me/.virutils/staging/myproject-linux
  domain: ubuntu (linux)
  delivery: rsync into the running guest
fetch: /home/me/work/myproject
   build/bin -> bin
   build/lib -> lib
   build/plugins -> plugins
   build/qml -> qml
-> /usr/bin/myproduct (4 item(s))
deliver: 1114 file(s), 227.0 MiB -> ubuntu /
run (pre): systemctl stop myproduct || true
ubuntu: 1114 files offered, 2 copied in 158ms
   emptied /var/log/myproduct (3 entries)
run (post): systemctl start myproduct
copy complete -> ubuntu
```

What is better on this path, and why:

* **No root, and no privileged port.** rsync's port is not fixed, so the daemon
  binds an unprivileged one picked per transfer. Nothing is escalated, no
  credential is primed, and there is no terminal requirement — so this is the
  one delivery here that runs unattended, from `cron` or CI, as it stands. It
  also cannot collide with the Windows host's file sharing on WSL, which is what
  holds 445 on the other path.
* **The count is exact.** `1114 files offered, 2 copied` is rsync's own
  itemised output, counted guest-side. The Windows path can only say whether
  *anything* moved, because `robocopy` keeps its per-file counts in a summary
  Windows localises; `--out-format` is not localised, so here the number is
  trustworthy in a guest of any language.
* **A real delta.** rsync compares contents, not just size and timestamp, so a
  file the guest has corrupted or truncated is re-sent — where a timestamp
  comparison would call it current and skip it.

What is the same, deliberately:

* **Deletions are never inferred.** No `--delete`, for the same reason the
  Windows path gets `robocopy /E` and not `/MIR`: the destination is the guest's
  root. What may be deleted is what a cleanup rule names, and nothing else.
* **Cleanup rules run in the guest**, with the same semantics and the same
  two-levels-down rule enforced twice — once host-side on the pattern, once in
  the guest on what it resolved to. The pattern is expanded by the guest's own
  shell but travels as *data*, not as shell source, so any character may appear
  in one — a path with a space or a `;` is a path.
* **Excludes need no translation.** They are rsync's, applied while the delivery
  tree is built, so what the guest is offered is already filtered.

Two details worth knowing:

* **The destination root's own mode is never changed.** rsync `-p` applies the
  *source* tree root's mode to the destination root, and on the delivery path
  that source root is a scratch directory on the host — so a delivery could
  chmod the guest's `/`, which locks every non-root user out of every path on
  the system and takes the desktop down with it. The guest puts `/`'s mode back
  after the transfer, succeeded or not, and the delivery tree is created 0755
  rather than `mktemp`'s 0700 so there is nothing hostile to apply in the first
  place. Modes *inside* the payload are preserved as normal. `push` does the
  same for whatever directory it is pushing into.
* **Files land `root:root`.** The guest copies as root — `qemu-ga` is a service
  — and the fetch runs `rsync -rlptD` rather than `-a`, so ownership is not
  carried across from the daemon and the modes the staging fetch set are. That
  is what a package would leave behind. Symlinks are recreated as symlinks, so a
  versioned `libfoo.so -> libfoo.so.1.2.3` chain arrives intact.
* **Run rules are `/bin/sh`**, not PowerShell, and are run with `set -e` — which
  matches `$ErrorActionPreference = "Stop"` on the other side. A rule that may
  legitimately fail needs its own `|| true`; see the
  [example](#a-linux-guest).

### Notes

**The staging directory is always under `~/.virutils/staging/`.** Whatever
`@staging` says is treated as a name relative to that root, including an
absolute path — so a mistyped `@staging` can only ever name a directory virutil
owns.

It lives there rather than in `/tmp` because the fetch is an *incremental*
rsync: a staging tree that survives a reboot means the next run copies only what
changed out of the Windows build tree, instead of all of it again. It also keeps
a multi-gigabyte build output off a tmpfs. Existing configs need no change —
`@staging=foo` simply moves from the old `~/.cache/virutil/foo` to
`~/.virutils/staging/foo`, and the first run after this refetches into the new
location.

## virutil pull

`pull` is `push` reversed, transport included: copy one file or directory out of
a guest's system drive onto the host. The guest copies it out itself over its
own network and keeps running — see [How files move](#how-files-move).

Works on a Windows or a Linux guest, and
[detects which](#which-guest-is-on-the-other-side). Two things differ on Linux,
both because the guest's own shell does the expanding:

* **`SRC` matches case-sensitively.** On Windows, `pull` leans on Windows
  matching case-insensitively itself. A Linux guest has no case-insensitive
  matching to borrow,
  and inventing one would be a worse surprise than the plain shell behaviour.
  `virutil pull ubuntu 'BUILD/logs' ./out` finds nothing if the directory is
  `build`.
* **Any character may appear in `SRC`.** The pattern travels as data, not as
  shell source — with `IFS` empty, `set -- $pat` does no field splitting and the
  glob still expands one field per match — so a path with a space or a `;` in it
  is a path.

### Synopsis

```
virutil pull VM SRC DST
virutil pull -h
```

### Arguments

| Argument | Meaning |
| --- | --- |
| `VM` | libvirt domain to read from. Must be **running**. |
| `SRC` | Guest path, relative to the root of `C:`. Wildcards allowed. |
| `DST` | Host directory to copy into. Created if it does not exist. |

`SRC` may be spelled with backslashes and an optional `C:`/`C:\` prefix, and is
normalised to a `C:`-relative path; one containing `..` is refused. It is
matched **case-insensitively** — the guest's NTFS is, and the path is what
Windows would see — so `program files/…` and `Program Files/…` both work:
Windows does that matching itself.

Each match is classified as a file or a directory: a directory is pulled
**recursively** into a subdirectory of `DST` named after it, a file is copied
in as-is. The glob decides which a call picks up — `foo/bar` (no wildcard)
matches the directory itself, `foo/bar/*` its contents. A source matching
nothing is an error, not a warning.

```
virutil pull win11 'ProgramData/Example/logs/*.log' ~/logs
virutil pull win11 '"Program Files (x86)/Example/Product"' ~/out
virutil pull win11 'Users/me/Desktop/note.txt' ~/
```

Quote the source in the shell: the wildcards are for the guest to match, not
the host.

### How the read is taken

The transport is `push`'s, pointed the other way. The host stands up one
throwaway SMB share on the address the guest reaches it at — random 24-character
share name, bound to that single address, anonymous, and **writable** — and the
guest's own `robocopy` copies into it:

```
guest C: --(robocopy, via the agent)--> \\host\<share> --> host DST
```

Nothing is mounted on the host, no device appears in the guest, no power state
changes, and the disk image is never opened. `robocopy` compares against what
`DST` already holds and moves only what differs, so a second pull of a build
where one file changed moves one file. Writable is the only difference from the
push direction, and it is why the bind address matters as much as it does: the
share is offered to the one address that reaches the guest, never the wildcard.

### Notes

**The guest must be running.** The copy is driven from inside the guest, so
there has to be a guest to drive.

**The destination must be writable by you.** `smbd` serves the share under the
invoking user, and the guest writes into it as that user, so `DST` and the files
that land in it are yours. This is checked before the server starts.

**Nothing about the disk image is rearranged.** No snapshot, no overlay, no
`blockcommit`. `pull` used to take a disk-only snapshot and
commit it back at the end, and that commit — which merges the whole backing
chain unless told otherwise — flattened post-snapshot writes into the image that
the domain's `virutil snapshot` records were defined against, leaving a later
`snapshot revert` restoring old RAM onto a newer disk. That is a bluescreen, and
the fix was to stop a transfer touching the images underneath a snapshot at all.

## virutil push

`push` is `sync`'s second half on demand: copy one file or directory from the
host into a guest's system drive with no config file. It exists for the cases
that do not deserve a config: a config file you edited by hand, a build artifact
you want in the guest right now, a one-off test file.

The payload is delivered into the **running** guest over its own network, which
fetches it itself — `robocopy` on Windows, `rsync` on Linux — so nothing is
mounted, nothing is shut down, and a re-push of a directory moves only the files
that differ from what the guest already has. See
[How files move](#how-files-move).

Works on a Windows or a Linux guest, and
[detects which](#which-guest-is-on-the-other-side); `DST` is spelled in that
guest's own flavour (`C:\dir\` or `/dir/`). One thing is better on Linux:
**pushing a single file is incremental there and is not on Windows.** `robocopy`
cannot rename onto a new name, so a Windows file push falls back to `Copy-Item`
and re-sends the whole file every time; `rsync` renames and skips-what-matches in
the same call.

### Synopsis

```
virutil push VM SRC DST
virutil push -h
```

### Arguments

| Argument | Meaning |
| --- | --- |
| `VM` | libvirt domain to copy into. Has to be **running**. |
| `SRC` | Host file or directory to copy. Must exist and be readable. |
| `DST` | Guest path, relative to the root of `C:`. |

`DST` may be spelled with backslashes and an optional `C:`/`C:\` prefix; it is
normalised to a `C:`-relative path. A destination containing `..` is refused,
so a mistyped path can never resolve to a write outside the guest's root.

### File or directory?

Both `SRC` and `DST` can be files or directories. The shapes follow rsync's own
rules, so a trailing slash means exactly what it means for rsync:

| Command | Result |
| --- | --- |
| `virutil push vm file.txt C:\name.txt` | Copy `file.txt` as that exact file (overwriting `name.txt` if it exists). |
| `virutil push vm file.txt C:\dir\` | Copy `file.txt` into `C:\dir\`, creating it if needed. |
| `virutil push vm dir C:\where\` | Copy the directory `dir` itself, recursively, under `C:\where\`. |
| `virutil push vm dir C:\where` | Same as the previous row: a trailing slash on the destination makes no difference for a directory source. |
| `virutil push vm dir\ C:\where\` | Copy the **contents** of `dir` into `C:\where\`, not `dir` itself. |
| `virutil push vm file.txt C:` | Copy `file.txt` to the root of `C:`. |

A file source whose destination (no trailing slash) already exists as a
directory on the guest is copied *inside* it, exactly as `rsync` and `cp`
behave. A **directory** source always lands inside its destination, which is
created if needed, so `dir` arrives as `C:\where\dir`; only the source's
trailing slash chooses between the directory itself and its contents. `DST`
ending in `/` or `\` always means a directory, even one that does not exist yet.

### Delivering the payload

A push copies into a guest that stays running. Nothing is mounted on
the host, nothing is written to the disk image, and no device appears in the
guest — the bytes cross the guest's own NIC:

```
$ virutil push win11 ./installer.exe 'C:\Users\dev\Desktop\'
push: ./installer.exe -> C:\Users\dev\Desktop\
win11: done (47.7 MiB) in 1.5s (454.1 MiB/s on the wire)

$ virutil push win11 ./build/ 'C:\src\build\'
push: ./build/ -> C:\src\build\
win11: 3 files present (some copied) in 1.5s
```

The first line is printed before the transfer starts, because its job is to say
what is going where. The second is what actually landed. The duration is the
guest's own stopwatch around the copy rather than this host's wall clock: a run
costs about a second and a half of agent round trip and `powershell.exe` starting
up whatever the payload is, so a rate computed from the wall clock would describe
that overhead rather than the transfer — and none is quoted at all for a payload
too small to have spent measurable time on the wire.

The host exports the payload as a read-only, anonymous SMB share on the one
address the guest reaches it at — a directory in place, a single file through a
one-entry scratch directory, since `robocopy` and `Copy-Item` both want a
directory to point at over a UNC path — and the guest is told, through the QEMU
guest agent, to `robocopy` it. The trailing-slash rules above are unchanged.

`robocopy` is the point. It compares each file against what the guest already
holds and copies only the difference, so a second push of a tree in which one file
changed moves one file and leaves the rest alone down to their timestamps. A
directory push reports how many files were *present* rather than how many crossed,
and deliberately so: `robocopy` keeps its per-file counts only in a summary that
Windows localises, so a non-English guest would have it parsed wrong rather than
not parsed at all.

The agent's own channel would carry these bytes too, and does not, for one
reason: a `guest-exec` payload is base64 inside JSON inside a single `argv`
entry, which Linux caps at 128 KB — about 98 KB of file per call, at roughly a
call per second. The NIC does the same work about three orders of magnitude
faster. Measured on `virbr0` against a Windows 11 guest: **50 MB in 1.5 s** end
to end, most of which is the fixed cost above, against ~100 KB/s through the
agent, which is all transfer.

What it needs, and what it does when it cannot have it:

| Requirement | If missing |
| --- | --- |
| Guest running | Refused, naming the state and pointing at `domain start`. |
| QEMU guest agent answering | Refused; there is nothing to drive the fetch. |
| A route from the guest back to this host | Refused; a guest on an isolated network cannot be delivered to. |
| `smbd` (Samba) on the host | Refused, naming the package to install. |
| Root on the host to bind TCP 445 | Prompted for once, up front, before `smbd` is backgrounded — where the prompt still has a terminal. Without a terminal the run stops rather than hanging. |
| Nothing else already on TCP 445 | Refused. SMB cannot be served to a Windows client on any other port; under WSL the listener is usually the Windows host's own file sharing. |

Each of those is a refusal that names what is missing, never a silent fallback
to some other route.

A failure is named rather than guessed at. The guest exits with a code the host
can read — `robocopy`'s own where the copy failed, virutil's where the destination
directory did — so "could not reach this host, check the guest firewall" and
"reached it fine but could not write, the path is locked" are different messages
rather than the same one. Nothing in the guest script uses `throw`, because a
terminating error in PowerShell buries the useful line under eight of
`CategoryInfo` and `FullyQualifiedErrorId`.

The share is as narrow as it can be made: a random name, read-only, guest-only,
bound to the one address that reaches the guest rather than the wildcard — this
host is usually on a real network as well as the guest's — holding nothing but
this payload, and retired however the run ends. `robocopy` against a UNC path is a
redirector read, so the guest mounts nothing and keeps no share of its own; `net
use` in the guest stays empty.

`sync` delivers the same way, for the same reason; see
[How the delivery works](#how-the-delivery-works). `pull` is the same share
pointed the other way — see [virutil pull](#virutil-pull).

Three transports that earlier versions carried are gone, and
[What used to be here](#what-used-to-be-here) records all of them: virtio-fs,
with its share device and `-t`/`@transport` knob; the HTTP payload `--live`
served with `python3` for the guest to fetch with `curl.exe`; and the disk
image `--disk` mounted on the host with `qemu-nbd` and `ntfs-3g`. `--live`,
`--smb` and `--disk` all stop with a message naming what replaced them rather
than being quietly accepted, and `tar.exe` is no longer needed in the guest.

### Notes

`push` must be run as yourself, not under `sudo`, exactly as `sync` must.

There are no excludes — `push` copies exactly what you name, which is
the point of having it at all.

## virutil domain

`domain` bookends everything else here: it makes the guest the other modules
operate on, removes it again along with the disks nobody else cleans up, and
covers the everyday operations in between.

```
virutil domain create VM ISO [-s GiB] [-m MiB] [-c N] [-o ID] [-v ISO|none]
virutil domain delete VM
virutil domain list
virutil domain start    VM [-s GiB] [-m MiB] [-c N] [-G]
virutil domain shutdown VM
virutil domain addr     VM
```

### create

A wrapper around `virt-install` with a KVM-tuned profile in place of libvirt's
defaults. The defaults it does pick — half the host's RAM, half its CPUs capped
at 8, a 64 GiB disk, UEFI — are aimed at a Windows guest on a WSL2 host, which
is the case this repo exists for. Everything is overridable.

The flags are what you vary per domain. Everything else is a property of the
*host* rather than of one guest, so it is set once in the
[environment](#environment) instead of retyped on every `create`.

| Option | Default | Description |
| --- | --- | --- |
| `-s`, `--size GiB` | `64` | Disk size. |
| `-m`, `--memory MiB` | half the host's | Guest RAM, rounded down to 512 MiB, floor 2048. |
| `-c`, `--vcpus N` | half the host's, max 8 | Virtual CPUs. |
| `-o`, `--osinfo ID` | **detected from the ISO** | libosinfo id; see `osinfo-query os`. |
| `-v`, `--virtio ISO` | `virtio-win*.iso` beside the install ISO | Driver ISO to attach as a second cdrom. `none` attaches none. |

The disk image is always `$VIRUTILS_IMAGE_DIR/VM.qcow2` (default
`~/.virutils/images/VM.qcow2`). It is not an option: one domain, one disk, in
the one directory every other module already looks in. Move the whole lot with
[`VIRUTILS_IMAGE_DIR`](#environment).

**`--osinfo` is detected, not guessed.** `osinfo-detect` reads the ISO's own
volume descriptors and reports the short-id, so a Windows 11 media identifies
itself as `win11` and a Fedora 40 one as `fedora40`. Detection drives the
whole Windows-specific half of the profile — Hyper-V enlightenments, the TPM,
the virtio-win cdrom — so an ISO that is not recognised falls back to
`$VIRUTILS_OSINFO` (itself defaulting to `win11`), and `-o` overrides both. If
`osinfo-detect` is not installed, the fallback is used directly.

What the profile actually sets, and why:

- **`--cpu host-passthrough,cache.mode=passthrough`**, with the vcpus presented
   as one socket of *n* cores × 2 threads. The guest sees the real CPU and the
   real cache topology; a flat *n*-socket guest is both a Windows licensing
   problem and a worse scheduling hint.
- **The Hyper-V enlightenments** (`synic`, `stimer`, `tlbflush`, `ipi`,
   `frequencies`, `reenlightenment`, …). The single largest win for a Windows
   guest: without them the guest's timer interrupts round-trip through the
   hypervisor and an idle desktop burns real host CPU. `evmcs` and `avic` come
   from the libosinfo profile and are switched back **off** — `avic` is AMD-only
   and `evmcs` needs nested VMX exposed to the guest, so on the wrong host they
   are just a domain that refuses to start.
- **virtio-blk with `cache=none`, `io=io_uring`, and a dedicated iothread.**
   `cache=none` keeps the host page cache out of the write path, where it would
   otherwise hold a second copy of what Windows is already caching — on WSL2 that
   copy competes for the memory the guest was given. `discard=unmap` and
   `detect_zeroes=unmap` let a TRIM in the guest shrink the qcow2 again.
- **The qcow2 is created by hand**, not by libvirt's storage driver, so it can
   have `cluster_size=1M` (L2 metadata small enough to stay cached, and no
   read-modify-write on a sub-cluster write), `preallocation=metadata`, and
   `lazy_refcounts=on`. The last of those trades a `qemu-img check -r all` after
   an unclean shutdown for cheaper writes.
- **No balloon, no HPET, `rtc_tickpolicy=catchup`.** Two emulated devices a
   Windows guest does not need, and a clock policy that replays missed ticks
   rather than dropping them.
- **The qemu-guest-agent channel** (`org.qemu.guest_agent.0`). `virt-manager`
   does not add it and nothing inside the guest can, yet it is what
   `virutil exec` talks to, and what makes
   `virsh shutdown --mode agent` Windows' own shutdown with apps forced closed
   rather than an ACPI event the guest may sit on. It needs a cold plug, so it
   cannot be added to a running domain later. It costs one virtio-serial port,
   so it is not optional and there is no flag to leave it out.
- **`--network network=default,model=virtio`**, overridable with
   `$VIRUTILS_NETWORK`. On a host where libvirt's default NAT network is not
   available — WSL2 often, where the `nf_nat` modules may be missing — SLIRP
   needs no host-side setup at all: `VIRUTILS_NETWORK=user,model=virtio`. That
   has no inbound path, so for RDP,
   `VIRUTILS_NETWORK='user,model=virtio,portForward.0.proto=tcp,portForward.0.hostPort=13389,portForward.0.guestPort=3389'`.

```
virutil domain create win11 ~/Work/iso/Win11_24H2_tiny.iso
virutil domain create dev ~/iso/f40.iso -s 40 -m 4096 -v none
virutil domain create win11 ~/iso/win11.iso -n | less
```

The disk is created first and **removed again if `virt-install` fails**, so a
failed attempt does not leave an image blocking the next one under the same
name.

### Environment

The settings below are properties of the host, not of one guest, so they are
read from the environment rather than passed per run. Export them in your shell
profile once, or prefix a single `create` with them.

| Variable | Default | Description |
| --- | --- | --- |
| `VIRUTILS_DIR` | `~/.virutils` | Root of everything virutil leaves on the host. Moves configs, images, staging, port state and mount points at once. See [Artifacts and state](#artifacts-and-state). |
| `VIRUTILS_IMAGE_DIR` | `$VIRUTILS_DIR/images` | Where a domain's disk image goes, and where `snapshot` writes overlays. |
| `VIRUTILS_OSINFO` | `win11` | Fallback libosinfo id when the ISO is not recognised. |
| `VIRUTILS_VIRTIO` | `virtio-win*.iso` beside the install ISO | Default for `-v`: driver ISO to attach as a second cdrom, or `none`. |
| `VIRUTILS_NETWORK` | `network=default,model=virtio` | Passed to `virt-install --network`. |
| `VIRUTILS_FIRMWARE` | `uefi` | `bios` selects SeaBIOS instead. Windows 11 will not install without UEFI. |

The same names spelled with the singular `VIRUTIL_` prefix are still read,
second, and print one deprecation line when they are. They used to disagree:
`VIRUTIL_IMAGE_DIR` was preferred over `VIRUTILS_IMAGE_DIR` in `modules/domain`
and nowhere else, so one config could point two things at two directories.

```
VIRUTILS_FIRMWARE=bios VIRUTILS_VIRTIO=none \
    virutil domain create dev ~/iso/alpine.iso -s 20 -m 2048
```

`virutil domain -h` prints the same table with the values currently in effect.

### delete

```
virutil domain delete VM
```

Stops the domain if it is running, undefines it with `--nvram` and
`--snapshots-metadata`, and removes everything virutil ever wrote for it. There
are no options: **it does not ask, and there is no way to keep the disks.** The
name is the whole confirmation, so a typo that happens to name a real domain
destroys it.

Beyond the disks, a delete also takes the artifacts the other modules leave
under `~/.virutils/`, each found by the same name the module that wrote it uses:

| Artifact | Path |
| --- | --- |
| Snapshot overlays and memory files | `images/VM.SNAP.*.qcow2`, `images/VM.SNAP.mem` |
| Host mount points | `mnt/VM`, `mnt/VM-usb` and `mnt/VM-xfer`, if an older virutil left them |
| Leftovers of removed commands | `images/VM-usb.qcow2`, `images/VM-xfer.qcow2`, `share/virutil-VM/` |
| Open port forwards | the `socat` relay, plus `ports/tcp-PORT` and its `.log` |

A still-mounted mount point is unmounted lazily first, and only ever `rmdir`'d —
never recursed into — so a umount that fails leaves the guest's files alone and
reports the directory instead.

`sync`'s staging trees are the one exception: they are named by `@staging` in a
config rather than after a domain, are shared between domains by design, and so
are never touched by a delete.

This exists because `virsh undefine --remove-all-storage` only removes volumes
libvirt knows about through a **storage pool**, and a host with no pools defined
— the normal case here — silently keeps the disks. So the disks are resolved
from the domain XML instead, and:

- **Backing chains are followed.** An overlay left by `virutil snapshot create`
   names its base; deleting only the top of the chain would orphan the base in
   the images directory (`~/.virutils/images/` by default). Every file in the
   chain is listed and removed.
- **Images another domain uses are kept.** Sharing one base image between
   domains is a normal way to run a golden image, and deleting it out from under
   the other domain is unrecoverable, so every candidate is checked against every
   other domain's disks and backing chains first. Anything shared is reported and
   left alone.
- **The list is printed as it goes.** Nothing here is undoable and nothing is
   confirmed, so the output is the only record of what was unlinked.
- **An unreadable image counts as a file to delete, not as no file.** If the
   backing chain cannot be read, the disk itself is still removed and the
   backing files it may have had are called out — the alternative is a delete
   that quietly turns into a keep.

Privilege is escalated only where the path calls for it: a root-owned image
directory costs a password, an image directory of your own costs none, and
undefining a domain hands its images back to their original owner before the
removal runs.

### start

```
virutil domain start VM [-s GiB] [-m MiB] [-c N] [-G]
```

Bare, this is `virsh start` plus the console window. With any of `-s`, `-m` or
`-c` it first rewrites what the domain gets, then starts it — the three things
worth changing about a guest you already have, without editing XML by hand.

| Option | Effect |
| --- | --- |
| `-s`, `--size GiB` | `qemu-img resize` on the top of the disk's backing chain. |
| `-m`, `--memory MiB` | `virt-xml --edit --memory`, both `memory` and `currentMemory`. |
| `-c`, `--vcpus N` | `virt-xml --edit --vcpus`, count **and** topology together. |
| `-G`, `--no-gui` | Start the domain and open no console. |

They take the same values, and the same short flags, as the matching `create`
options.

```
virutil domain shutdown win11
virutil domain start win11 -m 16384 -c 8
```

Four rules follow from what these actually do:

- **The console opens by default.** `virt-manager --connect qemu:///system
   --show-domain-console` — the `--connect` is not optional, virt-manager
   refuses `--show-*` without it — started under `setsid` with its output
   discarded, so the window survives the shell and the prompt comes straight
   back. Without virt-manager it falls back to `virt-viewer --wait`, and with
   neither installed, or with no `DISPLAY`/`WAYLAND_DISPLAY` to draw on, it says
   so and leaves the domain running. A domain that is already running is not an
   error here: the console still opens. `-G` skips all of it.
- **The domain must be shut off** for `-s`, `-m` and `-c`. All three are persistent edits to the domain
   config and the disk image, and none of them is a live change; `start` says
   so and stops rather than doing half of it.
- **The disk only grows.** `qemu-img resize` is run without `--shrink`, so a
   size below the current one is refused by `qemu-img` itself. Growing the image
   also does not grow the filesystem inside it — Windows still has to extend the
   partition (`diskmgmt.msc`, or `diskpart` → `extend`), which `start` reminds
   you of.
- **vcpus and topology are set in one edit.** libvirt rejects a definition whose
   topology does not multiply out to the vcpu count, so the sockets/cores/threads
   split is recomputed alongside — one socket, paired into threads when the count
   is even, exactly as `create` does it.

### list, shutdown, addr

```
virutil domain list
virutil domain shutdown VM
virutil domain addr     VM
```

Thin wrappers over `virsh list --all`, `virsh shutdown` and
`virsh domifaddr --full`. They add nothing but a shorter name and a consistent
connection URI (`qemu:///system`, so they match what every other module talks
to), and they live here so the whole lifecycle is one module rather than a
separate junk drawer. `shutdown` is the graceful ACPI request — for the
guest-agent path that `sync` and `push` use, see `modules/guest`.

Note that `addr` is `virsh domifaddr`; the shorter name is deliberate, since the
`dom` prefix is redundant under a module already called `domain`.

### port

```
virutil domain port VM [SPEC] [-c PORT]
```

Forward a TCP port into a running guest, so that the Windows host reaches the
service at `localhost:HOSTPORT`. `SPEC` is a bare `PORT` for the same number on
both sides, or `HOSTPORT:GUESTPORT` when they differ:

```sh
virutil domain port win11 8080         # host 8080 -> guest 8080
virutil domain port win11 8080:80      # host 8080 -> guest 80
virutil domain port win11               # what is currently forwarded
virutil domain port win11 -c 8080       # close that one
```

The guest address comes from `virsh domifaddr`, trying the DHCP lease, then the
guest agent, then the host's ARP cache — so a statically configured guest needs
[`qemu-guest-agent`](#guest-prerequisites) running for this to find it.

The forward is a detached `socat` relay. It survives the shell that started it
and lives until it is closed or WSL shuts down; the pid is printed, and the
listing shows it again later. Nothing needs root as long as the host port is
≥ 1024. Opening a forward that already exists is a no-op, and reopening one
whose guest address has since changed repoints it.

State lives in `~/.virutils/ports`, one file per forward. A file
whose relay has died is dropped the next time the list is read, so a reboot
cannot leave the two out of step.

**Why a relay and not a firewall rule.** Two hops separate a guest service from
a browser on Windows: guest → WSL, then WSL → Windows. This command is the first
hop; WSL's own localhost forwarding is the second, and comes for free — no
firewall rule, no `.wslconfig` change. But that second hop only publishes ports
that have a *real listening socket* in the WSL namespace, and an nftables `DNAT`
rule has none. That is the whole reason a userspace process is involved, and the
reason the relay always binds `0.0.0.0` rather than offering a choice.

If the forward connects but the guest never answers, check that the service in
the guest listens on `0.0.0.0` rather than `127.0.0.1`, and that the guest's
own firewall allows the port — no host-side plumbing works around either.

## virutil usb

Pass a physical USB device from the host through to a guest. Both drivers have
it, spelled the same way; what differs is what carries it — a libvirt
`<hostdev>` on a Linux host, `device_add usb-host` over the QEMU monitor on a
Windows one.

```
virutil usb list
virutil usb show   VM
virutil usb attach VM VENDOR:PRODUCT
virutil usb detach VM VENDOR:PRODUCT
```

`VENDOR:PRODUCT` is lowercase hex and is the first column of `virutil usb
list`, which reads the host's own device list — sysfs on Linux, PnP on Windows:

```
$ virutil usb list
0951:1666  Kingston DataTraveler 3.0
8087:0033  Intel(R) Wireless Bluetooth(R)

$ virutil usb attach win11 0951:1666
libvirt: attaching 0951:1666 to win11 (live)
Device attached successfully
```

It names the **device**, not the port it is plugged into, so it survives moving
the device between sockets. Both libvirt and qemu accept a bus/port address as
well; neither driver offers one, for exactly that reason.

An attach is two things at once, as a port forward is: the running guest, so
the device arrives now, and the persistent record, so it is still there after
the next boot — the domain XML on Linux, the `.cmd` launcher on Windows.
`detach` undoes both, and on a shut-off domain `attach` writes the persistent
half alone and says so. `show` prints both views, because a device in the
persistent config but not in the running guest is the one that surprises you at
the next boot:

```
$ virutil usb show win11
=== live ===
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x0951'/>
        <product id='0x1666'/>
      </source>
    </hostdev>
=== persistent ===
    ...
```

**Getting the device away from the host is the host's business, and the two
differ.** On Linux, `managed='yes'` is in the XML, so libvirt detaches the
device from its host driver itself and gives it back on detach — nothing to do.
On Windows, qemu reaches USB through libusb, which *cannot* open a device that a
Windows class driver already owns: the `device_add` succeeds and the guest sees
nothing. Install [UsbDk](https://github.com/daynix/UsbDk) to let it capture one
anyway, or bind WinUSB to that device with [Zadig](https://zadig.akeo.ie/);
`install.ps1` reports whether UsbDk is present.

One more asymmetry, in the XML rather than in the command: the persisted
`<hostdev>` carries `startupPolicy='optional'`, without which libvirt refuses to
start a domain whose passed-through device is unplugged. qemu waits for the
device instead, so the Windows driver has nothing equivalent to set.

The guest side needs no preparation on either driver: a libvirt domain gets a
USB controller by default, and every domain `virutil domain create` makes on
Windows already carries `-device qemu-xhci`.

### USB passthrough under WSL, with usbipd

`virutil usb` cannot do this half, and neither driver tries. When libvirt runs
inside WSL and the device is plugged into Windows, the device is on the far side
of the kernel boundary — `virutil usb list` in WSL is empty until something
brings it across, and that something is a `usbipd` round trip. virutil used to
carry a module that automated it, but it only ever worked on that one host shape
and it was three moving parts wide; what it did is short enough to run yourself.

The two compose: once usbipd has imported the device, it is an ordinary device
in the WSL kernel's sysfs, `virutil usb list` shows it, and `virutil usb attach`
takes it from there. Only the import below is done by hand.

[usbipd-win](https://github.com/dorssel/usbipd-win) shares the device from
Windows; the `vhci_hcd` module in the WSL kernel receives it; `virutil usb`
hands it to the domain.

**Share the device (Windows, Administrator — once per physical device).**
`bind` is persistent, so this is one UAC prompt ever:

```powershell
usbipd list                   # BUSID is the first column
usbipd bind -b 3-3
```

**Import it into WSL** (no Administrator; `ARCHLINUX` is your distro name from
`wsl -l`):

```powershell
usbipd attach --wsl ARCHLINUX -b 3-3
```

Confirm it arrived before going further. The import is what libvirt will look
up, and a device that never landed surfaces later as a libvirt error blaming the
VM layer instead:

```sh
virutil usb list              # the device is here now
```

**Attach it to the domain** — from here it is ordinary
[`virutil usb`](#virutil-usb), documented above:

```sh
virutil usb attach VM 0951:1666
```

**Hand it back.** Detach from the domain first, then from WSL. The device stays
bound — still usable in Windows, and ready for a prompt-free reattach:

```sh
virutil usb detach VM 0951:1666
```

```powershell
usbipd detach -b 3-3
usbipd unbind -b 3-3          # Administrator; stops sharing altogether
```

**What to check when it does not work.**

- `usbipd attach` reporting *"Device busy"* or *"used by Windows"* is usually
  usbipd's own leftover export from an import that died half way. Run
  `usbipd detach -b BUSID` and attach again.
- If it is genuinely Windows holding the device — a plain `bind` leaves the
  Windows driver in place, and for mass storage an open Explorer window is
  enough — only `usbipd bind --force -b BUSID` settles it, by swapping in the
  stub driver for good. Administrator, so leave it for last.
- `usbipd state` shows whether a device is bound, forced, and which client
  address holds it. A recorded client address is not proof the import landed —
  `lsusb` in WSL is.
- A busid names a *port*, so it changes when you move the device between
  sockets. Vendor:product names the device.

## Requirements

Host:

- `libvirt` with `qemu:///system`, and membership of the `libvirt` group
- `rsync` and `awk`
- `sudo`, for the privileged commands listed under
   [Description](#description). A terminal to answer it on, too: see
   [Delivering](#delivering)

Host, to deliver into a running **Windows** guest — what `sync` and `push` do:

- `smbd` (Samba), and root to bind TCP 445
- `ss` (`iproute2`), to tell whether 445 is free and whether `smbd` has taken it

Host, to deliver into or read from a running **Linux** guest (`sync` with
`@guest=linux`, and `push`/`pull` on a guest detected as Linux):

- `rsync` — already required above; it serves the payload as well as staging it
- `ss` (`iproute2`), to find a free port and tell whether the daemon has bound it
- **no root, and no privileged port**

Host, for `virutil domain`:

- `virt-install` and `virt-xml` (`virt-manager`'s CLIs), and `libosinfo` —
   `osinfo-detect` is what reads the install ISO's os id
- `/dev/kvm` — under WSL2 that means nested virtualisation enabled
- OVMF/edk2 firmware, unless `VIRUTILS_FIRMWARE=bios`
- `swtpm`, optional: without it the guest gets no TPM 2.0 device, which a
   **stock** Windows 11 ISO refuses to install without. Debloated images have the
   check removed.
- `acl`, optional: an install ISO under a `0700` home directory is unreachable
   by the qemu user, and `virutil domain create` prints the `setfacl` that fixes
   it

Guest — see [Guest prerequisites](#guest-prerequisites) for where each of
these comes from and how to install it:

- The QEMU guest agent — **required** by `sync`, `push` and `pull`, which drive
   the copy through it, and by `virutil exec`. On a Linux guest that is the
   `qemu-guest-agent` package. It is also
   what shuts the guest down with `--mode agent` instead of waiting on ACPI
- The SPICE guest tools, for the `spice` display and `spicevmc` channel every
   `virutil domain create` guest has — without the vdagent there is no
   clipboard sharing and the display does not auto-resize
- `rsync`, on a Linux guest — it is the guest-side copier for `sync`, `push`
   and `pull`

The `org.qemu.guest_agent.0` channel itself is part of every domain
`virutil domain create` makes; nothing has to be added on the host side.

## See also

`virsh(1)`, `rsync(1)`, `rsyncd.conf(5)`, `smbd(8)`, `usbipd(1)`
