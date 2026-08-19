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
   - [Delivering](#delivering)
   - [Writing the disk image](#writing-the-disk-image)
   - [Reading](#reading)
   - [What used to be here](#what-used-to-be-here)
   - [Snapshots eject loaded media first](#snapshots-eject-loaded-media-first)
   - [A shut-off domain gets a disk-only snapshot](#a-shut-off-domain-gets-a-disk-only-snapshot)
- [Guest prerequisites](#guest-prerequisites)
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
   - [Writing the disk image instead](#writing-the-disk-image-instead)
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
   - [time](#time)
   - [port](#port)
- [virutil usb](#virutil-usb)
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
| `~/.virutils/images/` | domain disks (`domain create`), snapshot overlays and memory files (`snapshot`, `pull`) |
| `~/.virutils/staging/` | sync's incremental staging trees (`@staging` names) |
| `~/.virutils/ports/` | `domain port` forward state and relay logs |
| `~/.virutils/mnt/` | host mount points for guest filesystems (`<VM>`) |

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
`VIRUTILS_MNT_ROOT`), each defaulting under the root. The
legacy `VIRUTIL_IMAGE_DIR` is still honoured for image placement. Existing
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
| `domain` | The domain lifecycle: create one from an install ISO with a KVM-tuned profile, delete one along with its disks, and the everyday operations in between. | `virutil domain {create\|delete\|list\|start\|shutdown\|addr\|time\|port} [VM] [ISO] [OPTIONS]` |
| `snapshot` | External snapshots (disk and memory) for libvirt domains. | `virutil snapshot {create\|list\|revert\|delete} VM [SNAP]` |

### transfer

| Module | Purpose | Usage |
| --- | --- | --- |
| `sync` | Fetch a project's build output from a Windows host and push it into a guest's `C:` drive. | `virutil sync [--disk] VM [-c NAME\|PATH]` |
| `pull` | Copy a file or directory out of a **running** guest. | `virutil pull VM SRC DST` |
| `push` | Copy a file or directory from the host into a guest's `C:` drive. | `virutil push [--disk] VM SRC DST` |

### guest

| Module | Purpose | Usage |
| --- | --- | --- |
| `exec` | Run commands inside a Windows guest through the QEMU guest agent, with no guest networking required. | `virutil exec {ping\|cmd\|ps} VM [FLAGS] [ARGS]` |

### hardware

| Module | Purpose | Usage |
| --- | --- | --- |
| `usb` | USB passthrough end to end from a Windows host under WSL: `usbipd` bind, import over `vhci_hcd`, then attach to the domain. | `virutil usb {list\|show\|attach\|detach\|unbind} [VM] [BUSID]` |

All three write the same C:-shaped tree — see
[How files move](#how-files-move). `sync` and `push` deliver into a **running**
guest over its own NIC, moving only what changed; both take `--disk` to write
the guest's disk image instead, which is the only thing `pull` has ever done.

`virutil` alone, or `virutil help`, prints the module list. `modules/parser`
handles the top-level dispatch plus the helpers every module shares; each
module file declares its own subcommands. Only `sync` is driven by a config
file; the rest take everything on the command line. The remainder of this
document covers `virutil sync`, then `virutil pull`, then `virutil push`, then
`virutil domain`.

## How files move

`sync`, `pull` and `push` differ in *what* they move. There are two ways it
moves, and which one you get depends on the direction.

**Writing — `sync` and `push` — delivers into a running guest.** The host exports
the payload as a read-only SMB share on the one address the guest already reaches
it at, and the guest pulls it with `robocopy`, driven through the QEMU guest
agent. Nothing is mounted on either side, no drive letter or device appears in
the guest, and the guest keeps running throughout. The part that matters on a
second run is `robocopy`: it compares the tree being served against the tree the
guest already has and copies only the difference, so a re-run after rebuilding
one file moves one file and leaves the rest untouched down to their timestamps.

**Reading — `pull` — goes through the disk image**, and always has. There is no
live read: see [Reading](#reading) below.

`sync` and `push` also take **`--disk`**, which writes the disk image instead of
delivering over the network. The host attaches the guest's own qcow2 with
`qemu-nbd`, mounts its largest NTFS partition with `ntfs-3g`, and writes that
directly — and the mount *is* `C:`, so there is no second copy step afterwards.
It costs the guest's uptime and rewrites every mapped file whether it changed or
not, and it buys you a transport that needs **nothing of the guest**: no agent,
no route back to this host, no privileged port, and a guest that is shut off
works as well as one that is up.

| | deliver (`sync`, `push`) | `--disk` (`sync`, `push`) | read (`pull`) |
| --- | --- | --- | --- |
| Guest must be | **running** | running or **shut off** | **running** |
| What is mounted | nothing | the disk image itself, read-write | a frozen snapshot of it, read-only |
| Guest side | `robocopy`, via the agent | nothing | nothing |
| Host needs | `smbd`, and root for port 445 | `qemu-nbd`, `ntfs-3g`, root to mount | the same, read-only |
| Fixed cost per run | an agent round trip | a shutdown and boot, only when it was running | a snapshot and a blockcommit |
| Moves on a re-run | only what changed | everything mapped | — |

### Delivering

The delivery needs four things at once, and none of them is optional: the guest
running, its agent answering, a route from the guest back to this host, and
`smbd` plus root on the host to bind port 445. Port 445 is not negotiable — it is
what SMB means to a Windows client, and no ephemeral-port trick can move it — so
this is the one place virutil binds a privileged port, and it refuses to run if
something already holds it. On WSL that something is usually the Windows host's
own file sharing.

When one of those four is missing, virutil **says which and stops**. It never
quietly falls back to `--disk`, and the reason is that the fallback would be a
larger side effect than the failure: writing the disk image means shutting the
guest down, which is not something to do to somebody who did not ask for it.

```sh
virutil sync win11              # guest keeps running; only changed files cross
virutil push win11 ./f.txt 'C:\'
```

Because the credential for port 445 is primed synchronously, before `smbd` is
backgrounded, **a delivery needs a terminal to ask on.** Run without one — from
`cron`, from CI, from a detached script — and it stops at once with `sudo: a
terminal is required`, rather than hanging. Give `smbd` a `NOPASSWD` rule if you
need this unattended, or use `--disk`, which needs `sudo` too but is equally
blocked without a terminal.

### Writing the disk image

`--disk` shuts a running guest down, and only then touches its disk. The guest
holds the same qcow2 open, and two writers on one image is the one mistake
nothing here can undo — so a guest that is on is first asked to shut down
(`virsh shutdown`, via the guest agent when it answers, ACPI otherwise), waited
for to reach `shut off`, and started again when the run is over, on success and
on failure. A guest that is already off is used as-is. What is refused outright
is paused and `pmsuspended`: that RAM no longer matches the disk being edited,
so it cannot be brought down and back around a write. One thing is never done —
forced off. There is no `virsh destroy` anywhere in this path; cutting power
leaves the NTFS volume dirty, so the disk would be unmountable read-write on the
next run, and an interrupted write can leave the guest unbootable.

So a running guest needs nothing from you beyond the flag:

```sh
virutil sync --disk win11        # running -> shut down -> copy -> started again
virutil push --disk win11 ./f.txt 'C:\'
```

### Reading

`pull` leaves the guest running throughout. A disk-only external snapshot
redirects the guest's writes to an overlay, freezing the base image at a
checkpoint; the base is attached read-only, mounted, copied out, and the overlay
is folded back in with `virsh blockcommit` before the run ends — on success and
on failure. See [virutil pull](#virutil-pull).

There is no live read to choose instead. A read has to see a consistent `C:`, and
the snapshot is what makes that true of a running guest; nothing the guest could
be asked to serve back over its own network would be cheaper than freezing the
image it is already running on.

### What used to be here

Two transports have been removed, and neither is coming back:

- **virtio-fs**, selected with `-t`/`--transport` or `@transport`. Gone, and with
   it the share device, the shared-memfd memory backing it needed, and sync's
   `>pre`/`>post` run rules — those ran through the guest agent against a guest
   that had to stay up, which a disk write cannot promise.
- **HTTP**, selected with `--live`: the host served one payload with `python3`
   and the guest fetched it with `curl.exe`, carrying a directory as a single
   `tar` that was unpacked whole every time. SMB does the same job and compares
   trees, so a re-push moves what changed rather than all of it; there was
   nothing left for HTTP to be better at. `tar.exe` is no longer needed in the
   guest, and `python3` is no longer part of any transfer — `virutil exec` still
   uses it.

A config still carrying `@transport` or a `>` rule is rejected with its line
number rather than quietly ignored, `-t` is no longer accepted on the command
line, and `--live` and `--smb` each stop with a message naming what replaced
them rather than being silently accepted.

A domain created by an older virutil may still have a `virtio-fs` share in its
definition. Nothing here uses it, and libvirt will refuse to start the domain if
the directory it exports has since been removed; strip it once, with the domain
shut off:

```sh
virsh --connect qemu:///system dumpxml VM     # find the <filesystem> element
virt-xml --connect qemu:///system VM --remove-device --filesystem all --define
```

`virutil domain delete` sweeps the leftover share directory either way.

### Snapshots eject loaded media first

`virutil snapshot create` takes one thing off the running guest before it asks
libvirt for anything, and puts it back afterwards. It does not touch the
domain's definition, and it is there because an external snapshot cannot carry
it:

| Removed | Why |
| --- | --- |
| any loaded cdrom or floppy | A **revert** does not reuse the overlay the create made. It builds a fresh one per disk, named `<source>.<epoch>`, **in the source's own directory** — so a loaded ISO means an overlay written next to the ISO. |

That is why an ISO kept under `/mnt/c` breaks a revert. The path is a
9p mount, libvirt cannot label a file it has just created there, and the revert
fails *half-done*: memory restored, disk switched back to the base image, no new
overlay over it, guest left paused. Unpause it and the guest writes straight
into the image the snapshot is defined against.

The create is the only place to prevent it, because a revert reads its disk list
out of the record — a record written with the drives loaded is a revert that
fails every time it is tried. Ejecting is enough: an empty drive has no source,
so there is nothing to snapshot and nothing to label. `--force` is used, since
Windows locks the tray of a disc it has mounted.

The consequence to know about: a revert restores the configuration in the
record, which was written mid-eject, so the guest comes back with empty drives
and libvirt drops them from the definition on its way past. That is no loss —
they are install media, and a domain past Windows Setup has no further use for
them.

### A shut-off domain gets a disk-only snapshot

The eject-and-put-back dance is for a *running* guest, and so is the memory half
of the snapshot: libvirt refuses a `--memspec` for a domain that is not running,
so `virutil snapshot create` on a shut-off domain skips it and takes a
disk-only external snapshot instead. Everything else is the same — the overlay
files, the records, and `revert`/`list`/`delete` all work. The one difference
is on the way back: with no saved memory to restore, a revert boots the guest
fresh from the disk state rather than resuming it mid-run. A domain created
without the media dance (shut off, or paused) has its drives left alone, so the
revert needs nothing ejected to begin with.


## Guest prerequisites

Three pieces of software go **inside** the Windows guest. Two of them come off
the `virtio-win` ISO; the SPICE guest tools are downloaded separately.
`virutil domain create` attaches that ISO as a second cdrom automatically, so on
a fresh install it is already in the guest's drive list; otherwise download it
once:

- `virtio-win.iso` — <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>
- SPICE guest tools — <https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe>

The **QEMU guest agent is required to move files into a guest**: `sync` and
`push` drive the fetch through it, so a guest without `qemu-ga` answering cannot
be delivered to. It is also what `virutil exec`, `virutil domain time`,
`virutil domain port` on a statically addressed guest, and
`virsh shutdown --mode agent` need.

`--disk` and `pull` are the exception — they work on the disk image from the host
and never talk to the guest, so they need none of this beyond the virtio drivers
that let the guest boot at all. That makes `--disk` the way into a guest whose
agent is broken or missing.

| What | Where it comes from | Needed by |
| --- | --- | --- |
| **virtio drivers** (`viostor`, `NetKVM`) | `virtio-win` ISO, or `virtio-win-guest-tools.exe` on it | booting at all — the installer cannot see a virtio disk without `viostor` |
| **QEMU guest agent** (`qemu-ga`) | `virtio-win-guest-tools.exe`, or `guest-agent\qemu-ga-x86_64.msi` on the ISO | `sync` and `push` (not `--disk`), `virutil exec`, `virutil domain time`, and `virsh shutdown --mode agent` |
| **SPICE guest agent** (`spice-vdagent`) | [spice-guest-tools](https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe) | the `spice` display and `spicevmc` channel of every `virutil domain create` domain — clipboard sharing and display auto-resize |

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

Two settings in Windows matter for the transfers that mount the disk image —
`--disk` and `pull` — and for those they are not optional:

- **Fast Startup must be off** (`powercfg /h off`). With it on, Windows leaves
   the NTFS volume dirty on shutdown and `ntfs-3g` refuses to mount it
   read-write — which makes `sync --disk` and `push --disk` fail on a guest that
   is properly shut off. The default delivery never mounts the volume, so it is
   indifferent to this.
- **A single disk** whose system volume is the largest NTFS partition on it.

## virutil sync

### Synopsis

```
virutil sync [--disk] VM [-c NAME|PATH]
virutil sync -h
```

### Description

`virutil sync` copies a build tree into a **running** Windows guest, which pulls
it over its own network and takes only the files that changed — so the run after
a rebuild of one file moves one file, and the guest never goes down. See
[How files move](#how-files-move). It works in two halves:

```
Windows build tree --(fetch)--> staging dir --(map)--> guest NTFS
```

**Fetch** mirrors selected directories out of the build tree into a staging
directory under `~/.virutils/staging/`, applying the exclude patterns. The staging layout is
normally arranged to mirror what will land in the guest, so the map rules stay
trivial.

**Push** (the default) runs the map rules into a delivery tree on the host — the
same rsync, the same excludes and destinations, into a scratch directory instead
of into a mount — exports that tree as a read-only SMB share on the address the
guest reaches this host at, and has the guest `robocopy` it onto `C:`. Only the
files that differ from what the guest already holds cross the wire; the rest keep
their timestamps to the millisecond. Any directories listed for cleanup are
emptied in the guest afterwards, and the share and the tree are torn down however
the run ends. Nothing is mounted and nothing is shut down.

With **`--disk`** this half is replaced by a write to the disk image: the guest is
shut down if it is running (waiting up to `@shutdown_timeout` for it to reach
`shut off`), its image is attached with `qemu-nbd`, the largest NTFS partition on
it is mounted, the staged files are copied to their destinations, the cleanup
directories are emptied, and the mount is torn down. A guest that was running is
started again — on success and on failure; one that was already off stays off.
Every mapped file is written whether it changed or not. See
[Writing the disk image instead](#writing-the-disk-image-instead).

Run it as yourself, **not** under `sudo`. It refuses to start when invoked under
`sudo`, because `$HOME` — and therefore config discovery — resolves to root's
home on any host whose sudoers sets `always_set_home`. Only the commands that
genuinely need root are escalated individually — `smbd` on the default path, and
`modprobe`, `qemu-nbd`, `partx`, `blkid`, `blockdev`, `mkdir`, `mount`, `umount`
under `--disk` — and you are prompted once, before anything is served or
attached. Every `virsh` call runs unprivileged, which requires membership of the
`libvirt` group. The delivery tree is built as you, and under `--disk` the guest
filesystem is mounted with `uid=`/`gid=` set to the invoking user, so both copy
phases and the cleanup pass need no privilege of their own.

Because the prompt comes before `smbd` is backgrounded, a run needs a terminal to
ask on: see [Delivering](#delivering).

### Arguments and options

| Argument | Description |
| --- | --- |
| `VM` | libvirt domain delivered into. It has to be **running**, since the delivery goes over its own network. With `--disk` its disk image is written instead, so a running one is shut down first and started again afterwards. Required. |

| Option | Description |
| --- | --- |
| `--disk` | Write the guest's disk image instead of delivering over its network. Mounts the image on the host, so a running guest is shut down for the copy and started again afterwards, and every mapped file is written whether it changed or not. Needs nothing of the guest — no agent, no route back here, no privileged port — and works on a guest that is shut off. See [Writing the disk image instead](#writing-the-disk-image-instead). |
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
| `~/.virutils/mnt/<VM>` | Default mount point for the guest filesystem, overridable with `@mnt`. |

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
| `-path` | Empty this guest directory after copying. The directory itself is kept. |

Map rules are the only unsigilled form. A line starting with punctuation that is
not one of the sigils above is treated as a mistyped directive, not as a glob,
and is rejected.

#### Settings

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `@repo` | yes | — | Root of the build tree on the host. Fetch sources are relative to it. |
| `@staging` | yes | — | Staging directory *name*. Always placed under `~/.virutils/staging/`, whatever is written here. |
| `@dest` | no | *(empty)* | Install directory in the guest, relative to `C:\`. Every map destination hangs off it, so the install path is spelled once. Empty means the root of `C:`. |
| `@nbd` | no | `/dev/nbd0` | NBD device used to attach the disk image. |
| `@mnt` | no | `~/.virutils/mnt/<VM>` | Host mount point for the guest filesystem. |
| `@shutdown_timeout` | no | `180` | Seconds to wait for a running guest to shut down before aborting the run. The guest is never forced off. |

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

Each path is emptied in the guest after the copy, leaving the directory itself in
place. Paths are relative to the root of `C:` — not to `@dest` — and are matched
**case-insensitively**, so `Users/*` behaves the way it would in Windows. A path
that is not present is reported and skipped.

Two safety rules apply, so a mistyped pattern cannot empty a top-level
directory: the expansion must stay inside the mount point, and it must be at
least two levels deep.

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

### How the delivery works

The second half of the run is a delivery the running guest pulls for itself. The
fetch is host-to-host and knows nothing about it:

```
Windows build tree --(fetch)--> staging --(map)--> delivery tree --(robocopy)--> C:
```

The map rules build their `C:`-shaped tree in a scratch directory under
`~/.virutils/tmp/` instead of in a mount; the host exports that directory as a
read-only, anonymous SMB share on the one address the guest reaches it at; and
the guest is told, through the guest agent, to `robocopy` the whole share onto
`C:\`. Because the delivery tree's layout already *is* the layout the rules asked
for, that is one command and one round trip, whatever the rules said.

Two things follow, and between them they are the reason it exists:

* **The guest stays up.** Nothing is mounted on the host, nothing is shut down,
  no drive letter or device appears in the guest, and its disk image is never
  opened. No Fast Startup rule, no managed-save rule, no teardown to verify.
* **Only what changed crosses.** `robocopy` compares every file against what the
  guest already holds and skips the ones that match, so re-syncing a build in
  which one DLL changed moves one DLL. `--disk` rewrites every mapped file on
  every run, and takes the guest down to do it — which is the wrong trade for the
  thing `sync` is actually for, a build tree resynced over and over.

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

**Cleanup rules run in the guest.** With no mount to unlink through, each
`-pattern` becomes a `Remove-Item` driven by the agent: the pattern is expanded
guest-side (so still case-insensitively, and still after the delivery, exactly as
on the disk path), and every directory it names has its contents removed, never
itself. The two-levels-down rule is enforced twice — once here on the pattern,
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
| `smbd` (Samba) on the host | Refused, pointing at `--disk`. |
| Root on the host to bind TCP 445 | Prompted for once, up front, before `smbd` is backgrounded — where the prompt still has a terminal. Without a terminal the run stops rather than hanging. |
| Nothing else already on TCP 445 | Refused. SMB cannot be served to a Windows client on any other port; under WSL the listener is usually the Windows host's own file sharing. |

Every one of those is a refusal naming `--disk`, never an automatic fallback.
Downgrading on its own would shut a running guest down to do it, which is a
larger thing to do unasked than stopping is.

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

### Writing the disk image instead

`--disk` replaces that whole second half with a write to the guest's own disk
image, mounted on the host. The fetch is untouched, and the map rules run exactly
as they do above — the same rsync, the same excludes, the same destinations — only
into the mount rather than into a delivery tree:

```
Windows build tree --(fetch)--> staging --(map)--> guest NTFS (mounted on the host)
```

```sh
virutil sync --disk win11
```

What changes:

* **The guest goes down.** If it is running it is asked to shut down, waited for,
  written to, and started again afterwards — on success and on failure. One that
  is already off stays off. Paused and `pmsuspended` are refused outright.
* **Everything mapped is rewritten**, whether it changed or not. There is no
  comparison against what the guest already holds, because nothing in the guest
  is running to be asked.
* **Cleanup runs on the host**, unlinking through the mount rather than through
  the agent.
* **Fast Startup and a clean NTFS volume start to matter**, since the volume has
  to be mounted read-write; see [Guest prerequisites](#guest-prerequisites).

Why it is still here: it needs **nothing of the guest**. No agent, no route back
to this host, no privileged port on the host, and no running guest. That makes it
the way into a guest whose agent is broken, whose network is isolated, or which is
simply shut off — and the only way to write one you would rather not start.

### Notes

Everything here concerns `--disk`, the half of the run that writes the disk
image. On the default path none of it is reached: nothing is mounted, nothing is
shut down and the disk image is never opened.

**Windows Fast Startup must be disabled in the guest.** With it on, Windows
leaves the NTFS volume dirty on shutdown and `ntfs-3g` refuses to mount it
read-write.

**A running guest is shut down and started again for you.** virutil asks it to
shut down (`virsh shutdown` — via the guest agent when it answers, ACPI
otherwise), waits up to `@shutdown_timeout` seconds for it to reach `shut off`,
does the copy, and starts it again — on success and on failure. A guest that was
already off stays off. What is refused is paused and `pmsuspended`: that RAM no
longer matches the disk, so it cannot be brought down and back around a write.
Shut those down by hand first.

**`@shutdown_timeout` bounds the wait.** Default 180 seconds. A graceful shutdown
of a healthy Windows guest usually takes seconds, but a modal dialog or "an app
is preventing shutdown" can hold it open indefinitely. If the timeout is hit,
nothing is written, the guest is left running, and the run fails naming the fix.

**Nothing is ever forced off.** There is no `virsh destroy` anywhere in this
path. Cutting power to a live Windows leaves the NTFS volume dirty — the same
state Fast Startup causes above — so the disk would be unmountable read-write
on the next run, and an interrupted write can leave the guest unbootable. If
you decide to force it, do that by hand and expect to boot Windows once to let
it check the volume.

**Install `qemu-guest-agent` in the guest.** `--disk` itself does not need it —
the copy is made from the host with the guest shut off — but the default delivery
does, and even under `--disk` it is what makes the automatic shutdown fast.
`virutil exec` requires it outright, and it is what
lets you shut the guest down with
`virsh --connect qemu:///system shutdown VM --mode agent`, which calls Windows'
own shutdown with applications forced closed rather than an ACPI power-button
event Windows is free to deliberate over. Either way it is a real shutdown, so
Windows closes the NTFS volume and the disk is left clean. Without it, the
automatic shutdown falls back to ACPI, which can run the wait to the full
`@shutdown_timeout`. See [Guest prerequisites](#guest-prerequisites), then
confirm the host can see it:

```
virutil exec ping DOMAIN      # confirms qemu-ga is answering
```

The agent channel is part of every domain `virutil domain create` makes, so
nothing is needed on the host side.

**Case matters in map destinations.** The guest's NTFS is case-insensitive, but
the `ntfs-3g` mount is not. `@dest` and map destinations are used verbatim, so
their case must match what the guest already has, or you will silently create a
second directory differing only in case. Cleanup paths are the exception — they
are matched case-insensitively.

**A domain with a managed-save image is refused.** Resuming from saved RAM would
restore NTFS metadata that no longer matches the disk just written. Clear it
first:

```
virsh managedsave-remove DOMAIN
```

**Paused and suspended domains are refused** for the same reason — as is a
running one. Shut the domain down yourself first.

**Teardown is verified before you are told the disk is free.** After unmounting
and detaching, `virutil sync` re-reads `/proc/mounts` and
`/sys/block/<nbd>/{pid,size}` to confirm — observed state rather than exit codes,
and both readable without privilege, so the check cannot fail merely because
`sudo` could not authenticate. If teardown cannot be verified, the run exits
non-zero telling you **not to start the domain yet**, and prints the recovery
commands. Starting it with the image still attached to NBD would put two
writers on one qcow2.

**A stale attachment aborts the run before anything is touched.** If the NBD
device is already attached, or the mount point already mounted, `virutil sync` exits
rather than risk detaching or unmounting something that is not its own.

**There is no `sudo` keep-alive.** The copy phases run unprivileged, so nothing
refreshes the `sudo` timestamp while they run. On a copy longer than
`timestamp_timeout` (15 minutes by default) you are asked for your password
again at teardown. If nobody answers, teardown fails and the recovery commands
are printed, per the rule above.

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

`pull` is `push` reversed: copy one file or directory out of a **running**
guest's `C:` drive onto the host. It never powers the guest off, and nothing
runs inside the guest — see [How files move](#how-files-move).

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
Windows would see — so `program files/…` and `Program Files/…` both work.

Each match is classified as a file or a directory: a directory is pulled
**recursively**, a file is copied as-is. The glob decides which a call picks up
— `foo/bar` (no wildcard) matches the directory itself, `foo/bar/*` its
contents. A source matching nothing is an error, not a warning.

```
virutil pull win11 'ProgramData/Example/logs/*.log' ~/logs
virutil pull win11 '"Program Files (x86)/Example/Product"' ~/out
virutil pull win11 'Users/me/Desktop/note.txt' ~/
```

Quote the source in the shell: the wildcards are for the guest to match, not
the host.

### How the read is taken

Nothing runs inside the guest at all — no agent, no power-state change. The host
reads a frozen snapshot instead:

```
guest NTFS --(snapshot freezes base)--> base qcow2 --(ro mount)--> host DST
```

A live external snapshot redirects the guest's writes to an overlay qcow2,
which freezes the base image at a checkpoint. The base is then attached with
`qemu-nbd -r`, mounted with `ntfs-3g` **read-only**, rsynced out to the host,
and the overlay is folded back into the base with `virsh blockcommit` before
the run ends — on success or failure — so the guest's disk is left exactly as
it would have been. The guest never stops writing through it.

### Notes

**The guest must be running.** `pull` dies on any other state. There is no
managed-save or paused-state special case: those states are simply not
`running`, and are refused.

**The checkpoint is at the QCOW2 level, not the filesystem level.** The base
image freezes whatever Windows has already flushed to disk. A file whose data
is on disk reads back complete; anything still sitting in the guest's page
cache at snapshot time is absent; the NTFS journal may be mid-transaction. This
is the standard live-backup tradeoff — fine for build output and configs, not
for auditing a live database.

**The overlay is always folded back.** On success *and* on failure, `pull` runs
`blockcommit --active --pivot` to merge the guest's writes back into the base,
then deletes the snapshot and the overlay file. The guest keeps running on the
overlay throughout, so even a failed run loses nothing — but if teardown cannot
be verified (see `sync`'s notes on that rule) or `blockcommit` fails, the
snapshot is left in place deliberately and the exact recovery commands are
printed.

**A single disk is assumed.** The first `disk`-type device in
`virsh domblklist` is the one snapshotted, read, and committed — the same
single-disk assumption `sync` documents.

## virutil push

`push` is `sync`'s second half on demand: copy one file or directory from the
host into a guest's `C:` drive with no config file. It exists for the cases that
do not deserve a config: a config file you edited by hand, a build artifact you
want in the guest right now, a one-off test file.

By default the payload is delivered into the **running** guest over its own
network, which fetches it with `robocopy` — so nothing is mounted, nothing is shut
down, and a re-push of a directory moves only the files that differ from what the
guest already has. `--disk` writes the guest's disk image instead, shutting a
running guest down around the copy and starting it again afterwards, exactly as
`sync --disk` does. See [How files move](#how-files-move).

### Synopsis

```
virutil push [--disk] VM SRC DST
virutil push -h
```

### Arguments

| Argument | Meaning |
| --- | --- |
| `VM` | libvirt domain to copy into. Has to be **running**, unless `--disk` is passed. |
| `SRC` | Host file or directory to copy. Must exist and be readable. |
| `DST` | Guest path, relative to the root of `C:`. |
| `--disk` | Write the guest's disk image instead of delivering over its network. Mounts the image on the host, so a running guest is shut down for the copy and started again afterwards. Needs nothing of the guest — no agent, no route back here, no privileged port — and works on a guest that is shut off. |

`DST` may be spelled with backslashes and an optional `C:`/`C:\` prefix; it is
normalised to a `C:`-relative path. A destination containing `..` is refused,
so a mistyped path can never resolve to a write outside the mount point.

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

The default push copies into a guest that stays running. Nothing is mounted on
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
| `smbd` (Samba) on the host | Refused, pointing at `--disk`. |
| Root on the host to bind TCP 445 | Prompted for once, up front, before `smbd` is backgrounded — where the prompt still has a terminal. Without a terminal the run stops rather than hanging. |
| Nothing else already on TCP 445 | Refused. SMB cannot be served to a Windows client on any other port; under WSL the listener is usually the Windows host's own file sharing. |

Each of those is a refusal naming `--disk`, never an automatic fallback:
downgrading would shut the running guest down, which is a larger thing to do
unasked than stopping is.

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
[How the delivery works](#how-the-delivery-works). `pull` does not — there is no
live read, and never has been.

Two transports that earlier versions carried are gone, and
[What used to be here](#what-used-to-be-here) records both: virtio-fs, with its
share device and `-t`/`@transport` knob, and the HTTP payload `--live` served with
`python3` for the guest to fetch with `curl.exe`. `--live` and `--smb` both stop
with a message naming what replaced them rather than being quietly accepted, and
`tar.exe` is no longer needed in the guest.

### Notes

`push` must be run as yourself, not under `sudo`, exactly as `sync` must.

Under `--disk` it also shares every safety rule `sync` documents for that path,
wholesale: a running guest is shut down and started again around the copy, while
a paused or suspended one is refused rather than shut down; a domain with a
managed-save image is refused; teardown is verified from observed state before
you are told the disk is free; Fast Startup must be off. That machinery lives in
the shared `modules/guest`, and on the default path none of it is reached —
nothing is mounted, nothing is shut down and the disk image is never opened.

There are no excludes either way — `push` copies exactly what you name, which is
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
virutil domain time     VM
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

The disk image is always `$VIRUTIL_IMAGE_DIR/VM.qcow2` (default
`~/.virutils/images/VM.qcow2`). It is not an option: one domain, one disk, in
the one directory every other module already looks in. Move the whole lot with
[`VIRUTIL_IMAGE_DIR`](#environment).

**`--osinfo` is detected, not guessed.** `osinfo-detect` reads the ISO's own
volume descriptors and reports the short-id, so a Windows 11 media identifies
itself as `win11` and a Fedora 40 one as `fedora40`. Detection drives the
whole Windows-specific half of the profile — Hyper-V enlightenments, the TPM,
the virtio-win cdrom — so an ISO that is not recognised falls back to
`$VIRUTIL_OSINFO` (itself defaulting to `win11`), and `-o` overrides both. If
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
   `virutil exec` talks to, what sets the guest clock, and what makes
   `virsh shutdown --mode agent` Windows' own shutdown with apps forced closed
   rather than an ACPI event the guest may sit on. It needs a cold plug, so it
   cannot be added to a running domain later. It costs one virtio-serial port,
   so it is not optional and there is no flag to leave it out.
- **`--network network=default,model=virtio`**, overridable with
   `$VIRUTIL_NETWORK`. On a host where libvirt's default NAT network is not
   available — WSL2 often, where the `nf_nat` modules may be missing — SLIRP
   needs no host-side setup at all: `VIRUTIL_NETWORK=user,model=virtio`. That
   has no inbound path, so for RDP,
   `VIRUTIL_NETWORK='user,model=virtio,portForward.0.proto=tcp,portForward.0.hostPort=13389,portForward.0.guestPort=3389'`.

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
| `VIRUTILS_IMAGE_DIR` | `$VIRUTILS_DIR/images` | The images directory. |
| `VIRUTIL_IMAGE_DIR` | `$VIRUTILS_IMAGE_DIR` | Legacy name, still honoured: where a domain's disk image goes, and where `snapshot` writes overlays. |
| `VIRUTIL_OSINFO` | `win11` | Fallback libosinfo id when the ISO is not recognised. |
| `VIRUTIL_VIRTIO` | `virtio-win*.iso` beside the install ISO | Default for `-v`: driver ISO to attach as a second cdrom, or `none`. |
| `VIRUTIL_NETWORK` | `network=default,model=virtio` | Passed to `virt-install --network`. |
| `VIRUTIL_FIRMWARE` | `uefi` | `bios` selects SeaBIOS instead. Windows 11 will not install without UEFI. |
| `VIRUTIL_TIME_SYNC` | `1` | `0` stops virutil syncing the guest clock on its own after a snapshot revert. See [time](#time). |
| `VIRUTIL_TIME_SYNC_WAIT` | `60` | Seconds to wait for the guest agent after a snapshot revert before giving up on the clock. |

```
VIRUTIL_FIRMWARE=bios VIRUTIL_VIRTIO=none \
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
| Host mount points | `mnt/VM`, and `mnt/VM-usb` and `mnt/VM-xfer` if an older virutil left them |
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

### time

```
virutil domain time VM
```

Set the guest's clock from the host's, through the guest agent, and print both
sides:

```
guest:  2026-08-14 09:12:44 +0700
host:   2026-08-14 22:41:03 +0700
clock: win11 was 48499s behind -> synced to the host
guest:  2026-08-14 22:41:03 +0700 (now)
```

**This mostly happens on its own.** A guest's clock stops whenever the guest
does, and a reverted snapshot restores memory whose clock stopped when the
snapshot was taken — so a guest reverted to a week-old checkpoint wakes up a
week behind and stays there. Windows will not fix it promptly on its own: the
time provider it would use is a Hyper-V device KVM does not present, which
leaves `w32tm`, whose own resync schedule is measured in hours and needs a
reachable time server it may not have.

That skew is not cosmetic. `rsync` skips a file whose destination is not older
than the source, so a guest whose clock ran ahead while it was up leaves
timestamps on `C:` that a later transfer reads as newer than the host's. So
virutil syncs the clock at the point the skew appears:

- after `virutil snapshot revert`, waiting up to `VIRUTIL_TIME_SYNC_WAIT`
   seconds (default 60) for the agent to come back up with the guest.

A guest already within two seconds of the host is left alone and nothing is
printed. Transfers do not sync the clock themselves: they are made from the host
against a shut-off or snapshotted disk, and a guest reads the host's RTC when it
boots. `VIRUTIL_TIME_SYNC=0` turns off the automatic sync;
`virutil domain time` ignores it, since asking by name is not automatic.

Under the hood this is `virsh domtime --now`, not `--sync`: `--sync` re-reads
the emulated RTC, whose offset a Windows guest interprets as local time, so it
can only ever hand back the answer the guest already had.

A guest with no `qemu-ga` cannot be synced at all; the sync says so once and the
transfer or revert carries on. Nothing here touches the *host* clock — under
WSL2 that one drifts across a Windows sleep on its own, and
`sudo hwclock -s` on the WSL side is the fix for that, not virutil.

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

Physical USB devices shared from the Windows host: `usbipd` binds a device on
Windows, imports it into WSL over `vhci_hcd`, and attaches it to the domain as a
USB host controller device; `detach` and `unbind` hand it back.

```
virutil usb list
virutil usb show   VM
virutil usb attach VM BUSID
virutil usb detach VM BUSID|VENDOR:PRODUCT
virutil usb unbind BUSID
```

`BUSID` is the first column of `virutil usb list`. It names a port, so it is
only meaningful while something is plugged into it; `VENDOR:PRODUCT` (lowercase
hex, from the device's hardware id) names a device that is currently unplugged,
which `detach` needs to clear a leftover hostdev. Only `bind` and `unbind` need
Administrator on Windows, and a bind is persistent — expect one UAC prompt per
physical device ever. A `detach` stops short of unbinding: the device stays
usable in Windows.

## Requirements

Host:

- `libvirt` with `qemu:///system`, and membership of the `libvirt` group
- `rsync` and `awk`
- `sudo`, for the privileged commands listed under
   [Description](#description). A terminal to answer it on, too: see
   [Delivering](#delivering)

Host, to deliver into a running guest — what `sync` and `push` do by default:

- `smbd` (Samba), and root to bind TCP 445
- `ss` (`iproute2`), to tell whether 445 is free and whether `smbd` has taken it

Host, for `--disk` and for `virutil pull` — the transports that mount the image:

- `qemu-nbd` and the `nbd` kernel module, loaded with `max_part` ≥ 1 —
   `virutil sync` reloads it if necessary
- `ntfs-3g`
- `util-linux` (`partx`, `blkid`, `blockdev`, `lsblk`, `mount`)

Host, for `virutil domain`:

- `virt-install` and `virt-xml` (`virt-manager`'s CLIs), and `libosinfo` —
   `osinfo-detect` is what reads the install ISO's os id
- `/dev/kvm` — under WSL2 that means nested virtualisation enabled
- OVMF/edk2 firmware, unless `VIRUTIL_FIRMWARE=bios`
- `swtpm`, optional: without it the guest gets no TPM 2.0 device, which a
   **stock** Windows 11 ISO refuses to install without. Debloated images have the
   check removed.
- `acl`, optional: an install ISO under a `0700` home directory is unreachable
   by the qemu user, and `virutil domain create` prints the `setfacl` that fixes
   it

Guest — see [Guest prerequisites](#guest-prerequisites) for where each of
these comes from and how to install it:

- The QEMU guest agent — **required** by `sync` and `push`, which drive the
   fetch through it, and by `virutil exec` and `virutil domain time`. It is also
   what shuts the guest down with `--mode agent` instead of waiting on ACPI.
   `--disk` and `virutil pull` are the exception and need none of it
- The SPICE guest tools, for the `spice` display and `spicevmc` channel every
   `virutil domain create` guest has — without the vdagent there is no
   clipboard sharing and the display does not auto-resize
- For `--disk` and `virutil pull`: Windows with Fast Startup disabled, and a
   single disk whose system volume is the largest NTFS partition on it. The
   default delivery never mounts the volume and is indifferent to both

The `org.qemu.guest_agent.0` channel itself is part of every domain
`virutil domain create` makes; nothing has to be added on the host side.

## See also

`virsh(1)`, `qemu-nbd(8)`, `ntfs-3g(8)`, `rsync(1)`, `usbipd(1)`
