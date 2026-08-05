# virctl

A small set of shell tools for driving Windows guests under libvirt/KVM from a
Linux host, including a WSL host talking to the Windows machine it runs on. Each
tool is a single self-contained bash script with no build step and no
dependencies beyond the utilities it calls.

## Contents

- [Tools](#tools)
- [virsync](#virsync)
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
- [Requirements](#requirements)
- [See also](#see-also)

## Tools

| Tool | Purpose | Usage |
| --- | --- | --- |
| `virsync` | Fetch a project's build output from a Windows host and push it into a guest's `C:` drive offline, by attaching the qcow2 with `qemu-nbd`. | `virsync [-c NAME\|PATH]` |
| `virexec` | Run commands inside a Windows guest through the QEMU guest agent, with no guest networking required. | `virexec {setup\|ping\|info\|run\|ps\|push\|pull\|raw} VM_NAME [FLAGS] [ARGS]` |
| `virusb` | USB passthrough end to end from a Windows host under WSL: `usbipd` bind, import over `vhci_hcd`, then attach to the domain. | `virusb {list\|show\|attach\|detach\|unbind} [VM] [VENDOR:PRODUCT]` |
| `virsnapshot` | External snapshots (disk and memory) for libvirt domains. | `virsnapshot {create\|list\|revert\|delete} VM_NAME [SNAP_NAME]` |
| `virmisc` | Everyday domain operations: list, start, graceful shutdown, interface addresses. | `virmisc {list\|start\|shutdown\|domifaddr} [VM_NAME]` |

Only `virsync` is driven by a config file; the rest take everything on the
command line. The remainder of this document covers `virsync`.

## virsync

### Synopsis

```
virsync [-c NAME|PATH]
virsync -h
```

### Description

`virsync` copies a build tree into a **powered-off** Windows guest by mounting
its disk on the host, so nothing has to run inside the guest — no network, no
shares, no guest agent. It works in two halves:

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
| `-c`, `--config NAME\|PATH` | Config to use. A value containing `/` is a path, taken as given. Anything else names a config in `~/.config/virutils/`, with `.conf` appended when absent — so `-c win11` reads `~/.config/virutils/win11.conf`. Defaults to `~/.config/virutils/virsync.conf`. |
| `-h`, `--help` | Print usage and exit. |

Path-or-name is decided from the spelling alone, never from what happens to
exist on disk, so the same command means the same config from any directory. One
consequence worth knowing: `-c win11` can never refer to a file in the current
directory — write `-c ./win11.conf` for that.

There are no other arguments. Everything else lives in the config.

### Files

| Path | Description |
| --- | --- |
| `~/.config/virutils/virsync.conf` | Default config. This is the only location searched; there is no fallback beside the script. |
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
| `@shutdown_timeout` | no | `180` | Seconds to wait for a graceful guest shutdown before destroying the domain. |

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

`~/.config/virutils/virsync.conf`:

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
./virsync
```

Or, keeping several profiles side by side:

```
./virsync -c win10
./virsync -c ~/scratch/experiment.conf
```

### Notes

**Windows Fast Startup must be disabled in the guest.** With it on, Windows
leaves the NTFS volume dirty on shutdown and `ntfs-3g` refuses to mount it
read-write.

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
and detaching, `virsync` re-reads `/proc/mounts` and
`/sys/block/<nbd>/{pid,size}` to confirm — observed state rather than exit codes,
and both readable without privilege, so the check cannot fail merely because
`sudo` could not authenticate. If teardown cannot be verified, the domain is left
**shut off on purpose** and the recovery commands are printed. Starting it with
the image still attached to NBD would put two writers on one qcow2.

**A stale attachment aborts the run before anything is touched.** If the NBD
device is already attached, or the mount point already mounted, `virsync` exits
rather than risk detaching or unmounting something that is not its own.

**There is no `sudo` keep-alive.** The copy phases run unprivileged, so nothing
refreshes the `sudo` timestamp while they run. On a copy longer than
`timestamp_timeout` (15 minutes by default) you are asked for your password
again at teardown. If nobody answers, teardown fails and the guest is left off,
per the rule above.

**The staging directory is always under `/tmp`.** Whatever `@staging` says is
treated as a name relative to `/tmp`, including an absolute path.

## Requirements

Host:

- `libvirt` with `qemu:///system`, and membership of the `libvirt` group
- `qemu-nbd` and the `nbd` kernel module, loaded with `max_part` ≥ 1 —
   `virsync` reloads it if necessary
- `ntfs-3g`
- `rsync`, `awk`, and `util-linux` (`partx`, `blkid`, `blockdev`, `lsblk`,
   `mount`)
- `sudo`, for the privileged commands listed under
   [Description](#description)

Guest, for `virsync`:

- Windows, with Fast Startup disabled
- A single disk exposed as `sda`, whose system volume is the largest NTFS
   partition on it

Guest, for `virexec`:

- The QEMU guest agent (`qemu-ga`, from the virtio-win guest-agent MSI) and the
   `org.qemu.guest_agent.0` channel, which `virexec setup` adds

## See also

`virsh(1)`, `qemu-nbd(8)`, `ntfs-3g(8)`, `rsync(1)`, `usbipd(1)`
