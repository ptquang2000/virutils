# virutil

A small set of shell tools for driving Windows guests under libvirt/KVM from a
Linux host, including a WSL host talking to the Windows machine it runs on.
Everything hangs off a single driver, `virutil`, which dispatches to a set of
sourced modules under `modules/` — each a small function library with no build
step and no dependencies beyond the utilities it calls.

## Contents

- [Modules](#modules)
- [virutil sync](#virutil-sync)
   - [Synopsis](#synopsis)
   - [Description](#description)
   - [Options](#options)
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
- [Requirements](#requirements)
- [See also](#see-also)

## Modules

| Module | Purpose | Usage |
| --- | --- | --- |
| `sync` | Fetch a project's build output from a Windows host and push it into a guest's `C:` drive offline, by attaching the qcow2 with `qemu-nbd`. | `virutil sync [-c NAME\|PATH]` |
| `pull` | Copy files out of a **running** guest by taking a disk-only live snapshot and reading the frozen base image read-only. | `virutil pull [-c NAME\|PATH]` |
| `push` | Copy a file or directory from the host into a guest's `C:` drive **on demand**, offline, with no config file. | `virutil push VM SRC DST` |
| `exec` | Run commands inside a Windows guest through the QEMU guest agent, with no guest networking required. | `virutil exec {setup\|ping\|info\|cmd\|ps} VM_NAME [FLAGS] [ARGS]` |
| `usb` | USB passthrough end to end from a Windows host under WSL: `usbipd` bind, import over `vhci_hcd`, then attach to the domain. | `virutil usb {list\|show\|attach\|detach\|unbind} [VM] [BUSID]` |
| `snapshot` | External snapshots (disk and memory) for libvirt domains. | `virutil snapshot {create\|list\|revert\|delete} VM_NAME [SNAP_NAME]` |
| `domain` | Create a domain from an install ISO with a KVM-tuned profile, or delete one along with its disks. | `virutil domain {create\|delete} VM [ISO] [OPTIONS]` |
| `misc` | Everyday domain operations: list, start, graceful shutdown, interface addresses. | `virutil misc {list\|start\|shutdown\|domifaddr} [VM_NAME]` |

`virutil` alone, or `virutil help`, prints the module list. `modules/parser`
handles the top-level dispatch plus the helpers every module shares; each
module file declares its own subcommands. Only `sync` and `pull` are driven by a
config file; the rest take everything on the command line. The remainder of
this document covers `virutil sync`, then `virutil pull`, then `virutil push`.

## virutil sync

### Synopsis

```
virutil sync [-c NAME|PATH]
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
directory under `/tmp`, applying the exclude patterns. The staging layout is
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

### Options

| Option | Description |
| --- | --- |
| `-c`, `--config NAME\|PATH` | Config to use. A value containing `/` is a path, taken as given. Anything else names a config in `~/.config/virutils/`, with `.conf` appended when absent — so `-c win11` reads `~/.config/virutils/win11.conf`. Defaults to `~/.config/virutils/sync.conf`. |
| `-h`, `--help` | Print usage and exit. |

Path-or-name is decided from the spelling alone, never from what happens to
exist on disk, so the same command means the same config from any directory. One
consequence worth knowing: `-c win11` can never refer to a file in the current
directory — write `-c ./win11.conf` for that.

There are no other arguments. Everything else lives in the config.

### Files

| Path | Description |
| --- | --- |
| `~/.config/virutils/sync.conf` | Default config. This is the only location searched; there is no fallback beside the script. |
| `~/.config/virutils/NAME.conf` | Additional configs, selected with `-c NAME`. |
| `/tmp/<@staging>` | Staging directory, rebuilt from `@repo` on every run. |
| `/mnt/<@domain>` | Default mount point for the guest filesystem, overridable with `@mnt`. |

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
| `@staging` | yes | — | Staging directory *name*. Always placed under `/tmp`, whatever is written here. |
| `@domain` | yes | — | libvirt domain whose disk is written. |
| `@dest` | no | *(empty)* | Install directory in the guest, relative to `C:\`. Every map destination hangs off it, so the install path is spelled once. Empty means the root of `C:`. |
| `@nbd` | no | `/dev/nbd0` | NBD device used to attach the disk image. |
| `@mnt` | no | `/mnt/<@domain>` | Host mount point for the guest filesystem. |
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
@domain=win11
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
./virutil sync
```

Or, keeping several profiles side by side:

```
./virutil sync -c win10
./virutil sync -c ~/scratch/experiment.conf
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
shutdown: Windows closes the NTFS volume, so the disk is left clean. Grab the
`virtio-win` guest tools ISO, install the QEMU guest agent from it, and confirm
the host can see it:

```
virutil exec setup DOMAIN     # once per domain: adds the agent channel
virutil exec ping DOMAIN      # confirms qemu-ga is answering
```

This is the same agent `virutil exec` uses, so a domain already set up for `exec`
needs nothing further.

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

**The staging directory is always under `/tmp`.** Whatever `@staging` says is
treated as a name relative to `/tmp`, including an absolute path.

## virutil pull

`pull` is `sync` in reverse: it copies files out of a guest's `C:` drive onto
the host, and unlike `sync` it never powers the guest off. The guest stays
running throughout — nothing runs in it, no guest agent, no guest-side
software, no shutdown.

```
guest NTFS --(snapshot freezes base)--> base qcow2 --(ro mount)--> host @dest
```

A live external snapshot redirects the guest's writes to an overlay qcow2,
which freezes the base image at a checkpoint. The base is then attached with
`qemu-nbd -r`, mounted with `ntfs-3g` **read-only**, rsynced out to the host,
and the overlay is folded back into the base with `virsh blockcommit` before
the run ends — on success or failure — so the guest's disk is left exactly as
it would have been. The only window where the disk is unusual is the run
itself, and the guest never stops writing through it.

### Synopsis

```
virutil pull [-c NAME|PATH]
virutil pull -h
```

### Options

Identical to `virutil sync`'s: `-c, --config NAME|PATH` selects a config in
`~/.config/virutils/` (`.conf` appended when absent), defaulting to
`~/.config/virutils/pull.conf`; `-h` prints usage. Run it as yourself, **not**
under `sudo` — the same rules, refinements and rationale as `sync`.

### Configuration

Same format and parser as `sync`'s config: one directive per line, `#`
comments, settings via `@key=value`, excludes via `!pat ...`, and map rules as
the only unsigilled form. There are no fetch or cleanup rules — pull has
nothing to stage and deletes nothing in the guest.

| Form | Meaning |
| --- | --- |
| `@key=value` | A setting. See below. |
| `globs\|subdir` | Map: copy the guest paths matching `globs` into `<@dest>/subdir` on the host. |
| `!pat pat ...` | `rsync --exclude` patterns, applied to the copy. |

#### Settings

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `@domain` | yes | — | libvirt domain whose disk is read. Must be **running**. |
| `@dest` | yes | — | Host directory the files land in. Must exist and be an absolute path. |
| `@nbd` | no | `/dev/nbd0` | NBD device used to attach the disk image. |
| `@mnt` | no | `/mnt/<@domain>` | Host mount point for the guest filesystem. |

#### Map rules

```
Program Files (x86)/Example/Product/*|
Users/me/AppData/Local/Example/logs/*.log|logs
*|
```

The part before `|` is a space-separated list of globs, relative to the root
of `C:` and matched **case-insensitively** — the source is what Windows would
see, so `program files` and `Program Files` both work. Each match is
classified as a file or a directory: a directory is pulled **recursively**
(its whole tree), a file is copied as-is. The glob decides which a rule picks
up — `foo/bar` (no wildcard) matches the directory itself, `foo/bar/*` its
contents. A leading `*` matches across directories. The part after `|` is a
destination relative to `@dest`; empty means `@dest` itself. Globs matching
nothing are warned about and skipped.

A glob that contains spaces must be wrapped in double quotes, wildcard and all,
so it is one glob rather than several words:

```
"Program Files (x86)/Example/Product/*"|bin
"Program Files (x86)/Example/Product/sub"|sub
```

#### Excludes

```
!*.log *.tmp ~*
```

Ordinary `rsync` exclude patterns, exactly as in `sync`.

### Example

`~/.config/virutils/pull.conf`:

```
@domain=win11
@dest=/mnt/c/Users/me/work/fromguest

# configs and logs out of the running guest
"Program Files (x86)/Example/Product/config/*.json"|config
ProgramData/Example/logs/*.log|logs

!*.tmp ~*
```

Then:

```
./virutil pull
```

### Notes

**The checkpoint is at the QCOW2 level, not the filesystem level.** The base
image freezes whatever Windows has already flushed to disk. A file whose data
is on disk reads back complete; anything still sitting in the guest's page
cache at snapshot time is absent; the NTFS journal may be mid-transaction and
`ntfs-3g` mounts the volume read-only. This is the standard live-backup
tradeoff — fine for build output and configs, not for auditing a live
database.

**The guest must be running.** `pull` dies on any other state. There is no
managed-save or paused-state special case: those states are simply not
`running`, and are refused. For an offline copy, run `sync` in reverse.

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
host into a guest's `C:` drive with no config file, using the same offline
machinery — shut the guest down if it is running, attach its qcow2 with
`qemu-nbd`, mount the NTFS, copy, and restore the power state you started with.
It exists for the cases that do not deserve a config: a config file you edited
by hand, a build artifact you want in the guest right now, a one-off test file.

### Synopsis

```
virutil push VM SRC DST
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

`push` shares every safety rule `sync` documents, wholesale: it must be run as
yourself, not under `sudo`; a running guest is shut down through the guest agent
(ACPI as a fallback, never a forced power-off) and restarted only once the disk
is provably free; a domain with a managed-save image, and paused or suspended
domains, are refused; Fast Startup must be off. All of that machinery lives in
the shared `modules/guest` used by both `sync` and `push`. There are no
excludes — `push` copies exactly what you name, which is the point of having it
at all.

## virutil domain

`domain` bookends everything else here: it makes the guest the other modules
operate on, and removes it again along with the disks nobody else cleans up.

```
virutil domain create VM ISO [OPTIONS]
virutil domain delete VM [-y]
```

### create

A wrapper around `virt-install` with a KVM-tuned profile in place of libvirt's
defaults. The defaults it does pick — half the host's RAM, half its CPUs capped
at 8, a 64 GiB disk, UEFI, `win11` — are aimed at a Windows guest on a WSL2
host, which is the case this repo exists for. Everything is overridable.

| Option | Default | Description |
| --- | --- | --- |
| `--size GiB` | `64` | Disk size. |
| `--memory MiB` | half the host's | Guest RAM, rounded down to 512 MiB, floor 2048. |
| `--vcpus N` | half the host's, max 8 | Virtual CPUs. |
| `--disk PATH` | `/var/lib/libvirt/images/VM.qcow2` | Disk image path. |
| `--osinfo ID` | `win11` | libosinfo id; see `osinfo-query os`. |
| `--virtio ISO` | `virtio-win*.iso` beside the install ISO | Driver ISO to attach as a second cdrom. |
| `--no-virtio` | — | Attach no driver ISO. |
| `--network SPEC` | `user,model=virtio` | Passed to `virt-install --network`. |
| `--bios` | — | SeaBIOS instead of UEFI. |
| `--dry-run` | — | Print the domain XML and define nothing. |

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
- **`--network user,model=virtio`.** SLIRP needs no host-side setup, which
   matters on WSL2 where the default NAT network usually is not there and the
   `nf_nat` modules may not be either. It has no inbound path; for RDP, add
   `--network 'user,model=virtio,portForward.0.proto=tcp,portForward.0.hostPort=13389,portForward.0.guestPort=3389'`.

```
virutil domain create win11 ~/Work/iso/Win11_24H2_tiny.iso
virutil domain create dev --osinfo fedora40 --size 40 --memory 4096 ~/iso/f40.iso
virutil domain create win11 ~/iso/win11.iso --dry-run | less
```

The disk is created first and **removed again if `virt-install` fails**, so a
failed attempt does not leave an image blocking the next one under the same
name.

### delete

```
virutil domain delete VM [-y] [--keep-disk]
```

Stops the domain if it is running, undefines it with `--nvram` and
`--snapshots-metadata`, and deletes its disks. `-y` skips the confirmation;
without it you are asked to type the domain name back. `--keep-disk` undefines
and leaves every image in place.

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

Host, for `virutil domain`:

- `virt-install` (`virt-manager`'s CLI) and `libosinfo`
- `/dev/kvm` — under WSL2 that means nested virtualisation enabled
- OVMF/edk2 firmware, unless `--bios` is passed
- `swtpm`, optional: without it the guest gets no TPM 2.0 device, which a
   **stock** Windows 11 ISO refuses to install without. Debloated images have the
   check removed.
- `acl`, optional: an install ISO under a `0700` home directory is unreachable
   by the qemu user, and `virutil domain create` prints the `setfacl` that fixes
   it

Guest, for `virutil sync`:

- Windows, with Fast Startup disabled
- The QEMU guest agent, strongly recommended: without it the shutdown falls back
   to ACPI, which Windows may sit on until `@shutdown_timeout` expires
- A single disk exposed as `sda`, whose system volume is the largest NTFS
   partition on it

Guest, for `virutil exec`:

- The QEMU guest agent (`qemu-ga`, from the virtio-win guest-agent MSI) and the
   `org.qemu.guest_agent.0` channel, which `virutil exec setup` adds

## See also

`virsh(1)`, `qemu-nbd(8)`, `ntfs-3g(8)`, `rsync(1)`, `usbipd(1)`
