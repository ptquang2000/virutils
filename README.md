# virutil

A small set of shell tools for driving Windows guests under libvirt/KVM from a
Linux host, including a WSL host talking to the Windows machine it runs on.
Everything hangs off a single driver, `virutil`, which dispatches to a set of
sourced modules under `modules/` — each a small function library with no build
step and no dependencies beyond the utilities it calls.

## Contents

- [Installation](#installation)
- [Modules](#modules)
   - [domains](#domains)
   - [transfer](#transfer)
   - [guest](#guest)
   - [hardware](#hardware)
- [Transports](#transports)
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
   - [Notes](#notes)
- [virutil pull](#virutil-pull)
- [virutil push](#virutil-push)
- [virutil domain](#virutil-domain)
   - [create](#create)
   - [Environment](#environment)
   - [delete](#delete)
   - [start](#start)
   - [list, shutdown, addr](#list-shutdown-addr)
- [Requirements](#requirements)
- [See also](#see-also)

## Installation

```sh
git clone https://github.com/ptquang2000/virutils.git
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

Installed as part of [the dotfiles](https://github.com/ptquang2000/.dotfiles),
none of this is needed: `setup.sh` links `virutils/vir*` into `~/.local/bin`
itself and `.zshrc` puts `virutils/completions` on `fpath` directly.

## Modules

The seven modules fall into four groups, which is also the order
`virutil help` prints them in. The three transfer modules additionally share a
[transport](#transports) layer, which decides *how* the bytes move.

### domains

| Module | Purpose | Usage |
| --- | --- | --- |
| `domain` | The domain lifecycle: create one from an install ISO with a KVM-tuned profile, delete one along with its disks, and the everyday operations in between. | `virutil domain {create\|delete\|list\|start\|shutdown\|addr} [VM] [ISO] [OPTIONS]` |
| `snapshot` | External snapshots (disk and memory) for libvirt domains. | `virutil snapshot {create\|list\|revert\|delete} VM [SNAP]` |

### transfer

| Module | Purpose | Usage |
| --- | --- | --- |
| `sync` | Fetch a project's build output from a Windows host and push it into a guest's `C:` drive. | `virutil sync VM [-c NAME\|PATH] [-t T]` |
| `pull` | Copy a file or directory out of a **running** guest. | `virutil pull VM SRC DST [-t T]` |
| `push` | Copy a file or directory from the host into a guest's `C:` drive. | `virutil push VM SRC DST [-t T]` |

### guest

| Module | Purpose | Usage |
| --- | --- | --- |
| `exec` | Run commands inside a Windows guest through the QEMU guest agent, with no guest networking required. | `virutil exec {ping\|cmd\|ps} VM [FLAGS] [ARGS]` |

### hardware

| Module | Purpose | Usage |
| --- | --- | --- |
| `usb` | USB passthrough end to end from a Windows host under WSL: `usbipd` bind, import over `vhci_hcd`, then attach to the domain. | `virutil usb {list\|show\|attach\|detach\|unbind} [VM] [BUSID]` |

All three take `-t`/`--transport`, and all three write the same C:-shaped tree
whichever one is chosen — see [Transports](#transports).

`virutil` alone, or `virutil help`, prints the module list. `modules/parser`
handles the top-level dispatch plus the helpers every module shares; each
module file declares its own subcommands. Only `sync` is driven by a config
file; the rest take everything on the command line. The remainder of this
document covers `virutil sync`, then `virutil pull`, then `virutil push`, then
`virutil domain`.

## Transports

`sync`, `pull` and `push` describe *what* to move. A transport decides *how*,
and the three differ in what they need from the guest rather than in what they
achieve. `-t`/`--transport` picks one; **`virtiofs` is the default**.

There is no fallback. A transport that cannot work is an error naming the fix,
never a silent downgrade — turning "copy a file" into "reboot Windows" behind
your back is not a fallback. So `virtiofs` being the default makes its
[guest prerequisites](#guest-prerequisites) a prerequisite of the tool.

| | `disk` | `volume` | `virtiofs` |
| --- | --- | --- | --- |
| Guest must be | shut down to write, running to read | running | running |
| Who writes `C:` | the host, through `ntfs-3g` | the guest, `robocopy` | the guest, `robocopy` |
| Host side | `qemu-nbd` on the guest's own qcow2 | `qemu-nbd` on a scratch qcow2 | `virtiofsd` |
| Guest side | nothing | the agent (`viostor` is already there) | the agent, WinFsp, viofs |
| Domain change | none | a disk that comes and goes | shared-memfd RAM, a **cold** restart to add |
| Copies of the data | 1 | 2 | 1 |
| Fixed cost per run | a full shutdown and boot | seconds | none |

**`disk`** is the original, and the only one that needs nothing at all from
inside the guest — which is what makes it the one to ask for when there is no
agent, no drivers, or the guest will not boot. For a write it shuts the guest down,
mounts its NTFS over `qemu-nbd`, copies, and restores the power state it found.
For a read it leaves the guest running and reads a frozen snapshot instead.

**`volume`** keeps the guest running and installs nothing. A scratch qcow2 is
filled by the host over `qemu-nbd`, released, hotplugged into the guest, and
`robocopy`'d onto `C:` from inside. The host and the guest take strict turns:
two writers on one image is the one unrecoverable mistake available here, so
every handover is verified from `/proc/mounts` and the domain's own device list
rather than from exit codes. A write hands the volume over **read-only**, so
the guest cannot dirty the filesystem the host has to mount next.

**`virtiofs`** exports a host directory the running guest sees live, so nothing
is copied twice. It is the default. It needs WinFsp and the viofs driver in the
guest, `virtiofsd` on the host, and guest RAM on a shared memfd — which
`virutil domain create` sets up by default, but which an older domain can only
gain through a full stop and start. The share is left attached between runs.

### Everything a transport needs, at create time

A domain from `virutil domain create` needs no further XML: the guest-agent
channel, the shared-memfd memory backing **and** the virtio-fs share device are
all in the profile, so the default transport has nothing to attach at all. The
share directory (`~/.cache/virutil-VM`) is created at the same time, and the
domain will not start without it — set `VIRUTIL_VIRTIOFS=none` to leave the
device out.

One thing cannot be pre-declared, by design: the `volume` transport's staging
disk. It exists to be attached and detached, and a permanently attached one
would be a second writer on an image the host has to mount. It is hotplugged per
run and needs no domain preparation — `q35` comes with fourteen `pcie-root-port`s
and a Windows guest uses six.

What remains outside the XML entirely is guest-side software: `qemu-ga` (the
virtio-win MSI), and WinFsp plus the viofs driver for `virtiofs`.

### The staging volume

`volume` keeps one scratch image per domain at
`/var/lib/libvirt/images/VM-xfer.qcow2`, 16 GiB and sparse, created and
formatted on first use and kept afterwards. It is formatted exFAT when the host
has `mkfs.exfat` — an in-kernel driver on both sides, where NTFS on the host is
FUSE — NTFS when it has `mkfs.ntfs`, and by **Windows itself** when it has
neither: the blank image is handed to the guest once, `Initialize-Disk` and
`Format-Volume` run inside it, and it comes back ready. Delete the image to
rebuild it.

The volume is found from inside the guest by its label, `VIRUTILXFER`, and its
drive letter is asked for on every run rather than assumed, because Windows
assigns the highest free one and that moves.


## Guest prerequisites

Three pieces of software go **inside** the Windows guest. All of them come off
the `virtio-win` ISO, except WinFsp. `virutil domain create` attaches that ISO
as a second cdrom automatically, so on a fresh install it is already in the
guest's drive list; otherwise download it once:

- `virtio-win.iso` — <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>
- WinFsp — <https://winfsp.dev>

| What | Where it comes from | Needed by |
| --- | --- | --- |
| **virtio drivers** (`viostor`, `NetKVM`) | `virtio-win` ISO, or `virtio-win-guest-tools.exe` on it | booting at all — the installer cannot see a virtio disk without `viostor` |
| **QEMU guest agent** (`qemu-ga`) | `virtio-win-guest-tools.exe`, or `guest-agent\qemu-ga-x86_64.msi` on the ISO | `virutil exec`, and the `volume` and `virtiofs` transports |
| **WinFsp** | <https://winfsp.dev> — install this **first** | `virtiofs` |
| **viofs driver + `VirtioFsSvc`** | `viofs\<os>\amd64\` on the `virtio-win` ISO | `virtiofs` |

The order matters for the last two: the viofs driver is a WinFsp file-system
driver and will not install usefully without WinFsp already there.

**During Windows Setup**, when no disk is listed, use *Load driver* → the
`virtio-win` CD → `amd64\<os>` to load `viostor`.

**After the install**, from an elevated prompt in the guest — `E:` being the
`virtio-win` CD:

```
E:\virtio-win-guest-tools.exe /install /quiet
```

That single installer covers the drivers and `qemu-ga`. Then, for `virtiofs`:

1. Install WinFsp (`winfsp-<version>.msi`), keeping the default components.
2. Install the viofs driver: right-click `E:\viofs\<os>\amd64\viofs.inf` →
   *Install*, or run `pnputil /add-driver E:\viofs\<os>\amd64\viofs.inf /install`.
3. Confirm the service exists — `virutil` starts it itself, but it has to be
   there to start:

```
sc query VirtioFsSvc
```

The guest-agent channel itself is part of every domain `virutil domain create`
makes, so nothing has to be added on the host side. Confirm the whole path from
the host:

```
virutil exec ping VM        # the agent answers
virutil push VM ./f.txt C:\   # the default transport works end to end
```

`virutil` reports exactly which of these is missing when a transport cannot
start, so there is no need to check them pre-emptively.

Two settings in Windows also matter, both for the `disk` transport only:

- **Fast Startup must be off** (`powercfg /h off`). With it on, Windows leaves
   the NTFS volume dirty on shutdown and `ntfs-3g` refuses to mount it
   read-write.
- **A single disk** whose system volume is the largest NTFS partition on it.

## virutil sync

### Synopsis

```
virutil sync VM [-c NAME|PATH] [-t disk|volume|virtiofs]
virutil sync -h
```

### Description

`virutil sync` copies a build tree into a **powered-off** Windows guest by
mounting its disk on the host, so nothing has to run inside the guest — no
network, no shares, no guest agent. It works in two halves:

```
Windows build tree --(fetch)--> staging dir --(map)--> guest NTFS
```

**Fetch** mirrors selected directories out of the build tree into a staging
directory under `~/.cache/virutil/`, applying the exclude patterns. The staging layout is
normally arranged to mirror what will land in the guest, so the map rules stay
trivial.

**Push** shuts the guest down if it is running, attaches its disk image with
`qemu-nbd`, picks the largest NTFS partition on it, mounts that, copies the
staged files to their destinations, empties any directories listed for cleanup,
then unmounts, detaches, and restores the guest's original power state.

Run it as yourself, **not** under `sudo`. It refuses to start when invoked under
`sudo`, because `$HOME` — and therefore config discovery — resolves to root's
home on any host whose sudoers sets `always_set_home`. Only the commands that
genuinely need root are escalated individually (`modprobe`, `qemu-nbd`, `partx`,
`blkid`, `blockdev`, `mkdir`, `mount`, `umount`), and you are prompted once
before the guest is shut down. Every `virsh` call runs unprivileged, which
requires membership of the `libvirt` group. The guest filesystem is mounted with
`uid=`/`gid=` set to the invoking user, so both copy phases and the cleanup pass
need no privilege of their own.

### Arguments and options

| Argument | Description |
| --- | --- |
| `VM` | libvirt domain whose disk is written. Required. |

| Option | Description |
| --- | --- |
| `-c`, `--config NAME\|PATH` | Config to use. A value containing `/` is a path, taken as given. Anything else names a config in `~/.config/virutils/`, with `.conf` appended when absent — so `-c win11` reads `~/.config/virutils/win11.conf`. Defaults to `~/.config/virutils/sync.conf`. |
| `-t`, `--transport T` | How to move the files: `virtiofs` (default), `volume` or `disk`. See [Transports](#transports). Overrides `@transport` in the config. |
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
| `~/.config/virutils/sync.conf` | Default config. This is the only location searched; there is no fallback beside the script. |
| `~/.config/virutils/NAME.conf` | Additional configs, selected with `-c NAME`. |
| `~/.cache/virutil/<@staging>` | Staging directory, refreshed from `@repo` on every run. |
| `/mnt/<VM>` | Default mount point for the guest filesystem, overridable with `@mnt`. |

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
| `@staging` | yes | — | Staging directory *name*. Always placed under `~/.cache/virutil/` (`$XDG_CACHE_HOME/virutil/`), whatever is written here. |
| `@dest` | no | *(empty)* | Install directory in the guest, relative to `C:\`. Every map destination hangs off it, so the install path is spelled once. Empty means the root of `C:`. |
| `@nbd` | no | `/dev/nbd0` | NBD device used to attach the disk image. |
| `@mnt` | no | `/mnt/<VM>` | Host mount point for the guest filesystem. |
| `@transport` | no | `virtiofs` | Default transport for this config. `-t` on the command line wins. |
| `@shutdown_timeout` | no | `180` | Seconds to wait for the guest to shut down before aborting the run. The guest is never forced off. |

#### Fetch rules

```
<bin/Release|.
<GearsApp/www/brand-default/translationsUI|brand-default/translationsUI
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
wabpoes.exe|ondemands/bs
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
-ProgramData/OPSWAT/Gears/logs
-Users/*/AppData/Local/OPSWAT/Gears/logs
```

Each path is emptied in the guest after the copy, leaving the directory itself in
place. Paths are relative to the root of `C:` — not to `@dest` — and are matched
**case-insensitively**, so `Users/*` behaves the way it would in Windows. A path
that is not present is reported and skipped.

Two safety rules apply, so a mistyped pattern cannot empty a top-level
directory: the expansion must stay inside the mount point, and it must be at
least two levels deep.

### Example

`~/.config/virutils/sync.conf`:

```
@repo=/mnt/c/Users/me/work/myproject
@staging=vmsync/myproject
@dest=Program Files (x86)/Example/Product
@shutdown_timeout=180

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

### Notes

**Windows Fast Startup must be disabled in the guest.** With it on, Windows
leaves the NTFS volume dirty on shutdown and `ntfs-3g` refuses to mount it
read-write.

**Install `qemu-guest-agent` in the guest.** The shutdown uses it when it
answers, and ACPI only as a fallback. ACPI is a power-button event Windows is
free to deliberate over — a modal dialog or "an app is preventing shutdown" and
the wait runs to `@shutdown_timeout`. The agent calls Windows' own shutdown with
applications forced closed, which usually takes seconds, and it is still a real
shutdown: Windows closes the NTFS volume, so the disk is left clean. See
[Guest prerequisites](#guest-prerequisites), then confirm the host can see it:

```
virutil exec ping DOMAIN      # confirms qemu-ga is answering
```

The agent channel is part of every domain `virutil domain create` makes, so
nothing is needed on the host side.

**The guest is never forced off.** If it has not shut down within
`@shutdown_timeout`, the run aborts with the guest left running rather than
falling back to `virsh destroy`. Cutting power to a live Windows leaves the NTFS
volume dirty — the same state Fast Startup causes above — so the disk would be
unmountable read-write on the next run, and an interrupted write can leave the
guest unbootable. If you decide to force it, do that by hand and expect to boot
Windows once to let it check the volume.

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

**Paused and suspended domains are refused** for the same reason. Shut the
domain down or destroy it first.

**The guest is restarted only once the disk is provably free.** After unmounting
and detaching, `virutil sync` re-reads `/proc/mounts` and
`/sys/block/<nbd>/{pid,size}` to confirm — observed state rather than exit codes,
and both readable without privilege, so the check cannot fail merely because
`sudo` could not authenticate. If teardown cannot be verified, the domain is left
**shut off on purpose** and the recovery commands are printed. Starting it with
the image still attached to NBD would put two writers on one qcow2.

**A stale attachment aborts the run before anything is touched.** If the NBD
device is already attached, or the mount point already mounted, `virutil sync` exits
rather than risk detaching or unmounting something that is not its own.

**There is no `sudo` keep-alive.** The copy phases run unprivileged, so nothing
refreshes the `sudo` timestamp while they run. On a copy longer than
`timestamp_timeout` (15 minutes by default) you are asked for your password
again at teardown. If nobody answers, teardown fails and the guest is left off,
per the rule above.

**The staging directory is always under `~/.cache/virutil/`.** Whatever
`@staging` says is treated as a name relative to that root, including an
absolute path — so a mistyped `@staging` can only ever name a directory virutil
owns.

It lives there rather than in `/tmp` because the fetch is an *incremental*
rsync: a staging tree that survives a reboot means the next run copies only what
changed out of the Windows build tree, instead of all of it again. It also keeps
a multi-gigabyte build output off a tmpfs. Existing configs need no change —
`@staging=foo` simply moves from `/tmp/foo` to `~/.cache/virutil/foo`, and the
first run after this refetches into the new location.

## virutil pull

`pull` is `push` reversed: copy one file or directory out of a **running**
guest's `C:` drive onto the host, over any of the three
[transports](#transports). It never powers the guest off.

### Synopsis

```
virutil pull VM SRC DST [-t disk|volume|virtiofs]
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

### Transports

Under `volume` and `virtiofs` (the default) the guest does the reading: the
path is resolved *in Windows* and `robocopy`'d into the staging volume or the
share, which the host then reads. That is file-level consistency, and it needs
the agent.

Under `--transport disk` nothing runs inside the guest at all — no agent, no
power-state change — and the host reads a frozen snapshot instead:

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

**The guest must be running**, under every transport. `pull` dies on any other
state. There is no managed-save or paused-state special case: those states are
simply not `running`, and are refused.

**The notes below apply to `--transport disk` only.** The live transports take
no snapshot, so none of it is relevant to them.

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
host into a guest's `C:` drive with no config file, over any of the three
[transports](#transports). It exists for the cases that do not deserve a config:
a config file you edited by hand, a build artifact you want in the guest right
now, a one-off test file.

The guest keeps running under the default transport. `--transport disk` is the
offline path: shut the guest down, attach its qcow2 with `qemu-nbd`, mount the
NTFS, copy, and restore the power state you started with.

### Synopsis

```
virutil push VM SRC DST [-t disk|volume|virtiofs]
virutil push -h
```

### Arguments

| Argument | Meaning |
| --- | --- |
| `VM` | libvirt domain whose disk is written. |
| `SRC` | Host file or directory to copy. Must exist and be readable. |
| `DST` | Guest path, relative to the root of `C:`. |

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

### Notes

`push` shares every safety rule `sync` documents, wholesale, and the rules that
matter depend on the transport. Under `disk`: it must be run as yourself, not
under `sudo`; a running guest is shut down through the guest agent (ACPI as a
fallback, never a forced power-off) and restarted only once the disk is provably
free; a domain with a managed-save image, and paused or suspended domains, are
refused; Fast Startup must be off. That machinery lives in the shared
`modules/guest`. Under `volume` and `virtiofs` none of it applies — the guest is
never stopped — and the rule that replaces it is the handover check in
`modules/volume`: the staging image is never mounted here and attached there at
the same time. There are no
excludes — `push` copies exactly what you name, which is the point of having it
at all.

## virutil domain

`domain` bookends everything else here: it makes the guest the other modules
operate on, removes it again along with the disks nobody else cleans up, and
covers the everyday operations in between.

```
virutil domain create VM ISO [-s GiB] [-m MiB] [-c N] [-d PATH] [-o ID]
                             [-v ISO|none] [-n]
virutil domain delete VM [-y] [-k]
virutil domain list
virutil domain start    VM [-s GiB] [-m MiB] [-c N]
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
| `-d`, `--disk PATH` | `/var/lib/libvirt/images/VM.qcow2` | Disk image path. |
| `-o`, `--osinfo ID` | **detected from the ISO** | libosinfo id; see `osinfo-query os`. |
| `-v`, `--virtio ISO` | `virtio-win*.iso` beside the install ISO | Driver ISO to attach as a second cdrom. `none` attaches none. |
| `-n`, `--dry-run` | — | Print the domain XML and define nothing. |

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
- **Guest RAM backed by a shared memfd**
   (`<memoryBacking><access mode='shared'/><source type='memfd'/>`). Nothing in
   the default profile uses it, but a vhost-user device — **virtio-fs** above all
   — cannot attach to a guest whose memory the host cannot map, and
   `memoryBacking` is a *cold* setting: adding it to an existing domain costs a
   full shutdown and start. Carrying it is free (the memfd is sized, not
   preallocated, so an idle guest uses no more host memory than before), so every
   new domain gets it and stays one hotplug away from a live host↔guest share
   instead of one power cycle away. `VIRUTIL_SHARED_MEMORY=0` opts out.
- **The qemu-guest-agent channel** (`org.qemu.guest_agent.0`). `virt-manager`
   does not add it and nothing inside the guest can, yet the `volume` and
   `virtiofs` transports need it — it is what runs the copy in Windows — and the
   `disk` transport wants it, since with the agent a shutdown is Windows' own
   with apps forced closed rather than an ACPI event it may sit on until
   `@shutdown_timeout`. It costs one virtio-serial port, so it is not optional
   and there is no flag to leave it out.
- **The virtio-fs share device**, pointing at `~/.cache/virutil-VM`, which the
   default transport then needs no attach for. The directory is created here,
   and the domain will not start without it —
   `VIRUTIL_VIRTIOFS=none` leaves the device out, and `VIRUTIL_VIRTIOFS=DIR`
   puts the share somewhere else. If `virtiofsd` is not installed the device is
   skipped with a warning rather than failing the create.
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
| `VIRUTIL_IMAGE_DIR` | `/var/lib/libvirt/images` | Where a disk image goes when `-d` is not given. Also where `snapshot` writes overlays. |
| `VIRUTIL_OSINFO` | `win11` | Fallback libosinfo id when the ISO is not recognised. |
| `VIRUTIL_VIRTIO` | `virtio-win*.iso` beside the install ISO | Default for `-v`: driver ISO to attach as a second cdrom, or `none`. |
| `VIRUTIL_NETWORK` | `network=default,model=virtio` | Passed to `virt-install --network`. |
| `VIRUTIL_FIRMWARE` | `uefi` | `bios` selects SeaBIOS instead. Windows 11 will not install without UEFI. |
| `VIRUTIL_SHARED_MEMORY` | `1` | `0` leaves guest RAM on private anonymous memory, which makes virtio-fs impossible without a later cold restart. |
| `VIRUTIL_VIRTIOFS` | `~/.cache/virutil-VM` | Host side of the virtio-fs share. `none` leaves the device out of the domain. |

```
VIRUTIL_FIRMWARE=bios VIRUTIL_VIRTIO=none \
    virutil domain create dev ~/iso/alpine.iso -s 20 -m 2048
```

`virutil domain -h` prints the same table with the values currently in effect.

### delete

```
virutil domain delete VM [-y] [-k]
```

Stops the domain if it is running, undefines it with `--nvram` and
`--snapshots-metadata`, and deletes its disks. `-y`/`--yes` skips the
confirmation; without it you are asked to type the domain name back.
`-k`/`--keep-disk` undefines and leaves every image in place.

This exists because `virsh undefine --remove-all-storage` only removes volumes
libvirt knows about through a **storage pool**, and a host with no pools defined
— the normal case here — silently keeps the disks. So the disks are resolved
from the domain XML instead, and:

- **Backing chains are followed.** An overlay left by `virutil snapshot create`
   names its base; deleting only the top of the chain would orphan the base in
   `/var/lib/libvirt/images`. Every file in the chain is listed and removed.
- **Images another domain uses are kept.** Sharing one base image between
   domains is a normal way to run a golden image, and deleting it out from under
   the other domain is unrecoverable, so every candidate is checked against every
   other domain's disks and backing chains first. Anything shared is reported and
   left alone.
- **The list is printed before anything is destroyed**, because unlinking a
   qcow2 is the one step here that nothing undoes.
- **An unreadable image counts as a file to delete, not as no file.** If the
   backing chain cannot be read, the disk itself is still removed and the
   backing files it may have had are called out — the alternative is a delete
   that quietly turns into a keep.

Privilege is escalated only where the path calls for it: the default image
directory is root-owned, but a `--disk` in a directory of your own costs no
password, and undefining a domain hands its images back to their original owner
before the removal runs.

### start

```
virutil domain start VM [-s GiB] [-m MiB] [-c N]
```

Bare, this is `virsh start`. With any of `-s`, `-m` or `-c` it first rewrites
what the domain gets, then starts it — the three things worth changing about a
guest you already have, without editing XML by hand.

| Option | Effect |
| --- | --- |
| `-s`, `--size GiB` | `qemu-img resize` on the top of the disk's backing chain. |
| `-m`, `--memory MiB` | `virt-xml --edit --memory`, both `memory` and `currentMemory`. |
| `-c`, `--vcpus N` | `virt-xml --edit --vcpus`, count **and** topology together. |

They take the same values, and the same short flags, as the matching `create`
options.

```
virutil domain shutdown win11
virutil domain start win11 -m 16384 -c 8
```

Three rules follow from what these actually do:

- **The domain must be shut off.** All three are persistent edits to the domain
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

## Requirements

Host:

- `libvirt` with `qemu:///system`, and membership of the `libvirt` group
- `qemu-nbd` and the `nbd` kernel module, loaded with `max_part` ≥ 1 —
   `virutil sync` reloads it if necessary
- `ntfs-3g`
- `rsync`, `awk`, and `util-linux` (`partx`, `blkid`, `blockdev`, `lsblk`,
   `mount`)
- `sudo`, for the privileged commands listed under
   [Description](#description)

Host, per [transport](#transports):

- `virtiofs` (**the default**) — `virtiofsd`, found at `/usr/lib/virtiofsd`,
   `/usr/libexec/virtiofsd` or on `PATH`
- `volume` — `sfdisk`, `qemu-img` and `jq`, plus `mkfs.exfat` (or `mkfs.ntfs`)
   if you would rather the host formatted the staging image than the guest
- `disk` — everything above; nothing further

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

- WinFsp and the virtio-win viofs driver, for `virtiofs` (the default) — and
   therefore for `sync`, `pull` and `push` as they are normally used
- The QEMU guest agent, for `virutil exec` and for the `volume` and `virtiofs`
   transports, which run the guest-side copy through it. Strongly recommended
   for `disk` too, where without it the shutdown falls back to ACPI and Windows
   may sit on it until `@shutdown_timeout` expires
- For the `disk` transport only: Windows with Fast Startup disabled, and a
   single disk whose system volume is the largest NTFS partition on it

The `org.qemu.guest_agent.0` channel itself is part of every domain
`virutil domain create` makes; nothing has to be added on the host side.

## See also

`virsh(1)`, `qemu-nbd(8)`, `ntfs-3g(8)`, `rsync(1)`, `usbipd(1)`
