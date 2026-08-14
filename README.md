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
      - [Run rules](#run-rules)
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
   - [time](#time)
   - [port](#port)
- [virutil usb](#virutil-usb)
   - [usb media](#usb-media)
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

## Artifacts and state

Everything `virutil` leaves on the host lives under one root, `~/.virutils/`,
so the whole footprint is a single directory you can inspect, back up, or move
in one go. The layout, and what fills each subdirectory:

| Path | Filled by |
| --- | --- |
| `~/.virutils/conf/` | sync configs (`sync.conf`, `NAME.conf`) |
| `~/.virutils/images/` | domain disks (`domain create`), snapshot overlays and memory files (`snapshot`, `pull`), and the `usb media` drive image (`VM-usb.qcow2`) |
| `~/.virutils/staging/` | sync's incremental staging trees (`@staging` names) |
| `~/.virutils/share/` | the virtiofs share directory (`virutil-<VM>`), created with the domain and exported to it |
| `~/.virutils/ports/` | `domain port` forward state and relay logs |
| `~/.virutils/mnt/` | host mount points for guest filesystems (`<VM>`, `<VM>-usb`) |

Installation links are the exception and follow the [installation
above](#installation): `virutil` in `~/.local/bin` and `_virutil` in the zsh
`site-functions` directory — symlinks into the checkout, not copies.

### Relocating the root

Set `VIRUTILS_DIR` to move everything at once — configs, images, staging,
shares, port state and mount points:

```sh
export VIRUTILS_DIR=/mnt/big/virutils
```

Each piece can also be moved on its own (`VIRUTILS_CONF_DIR`,
`VIRUTILS_IMAGE_DIR`, `VIRUTILS_STAGING_ROOT`, `VIRUTILS_SHARE_ROOT`,
`VIRUTILS_PORT_DIR`, `VIRUTILS_MNT_ROOT`), each defaulting under the root. The
legacy `VIRUTIL_IMAGE_DIR` is still honoured for image placement. Existing
configs in `~/.config/virutils/` keep working — see [virutil sync](#virutil-sync).

### A note on who owns the files

Everything here is owned by you, and most of it never leaves the host. The one
exception is anything qemu has to read or write: the domain disks, the snapshot
overlays and memory files, and the usb drive image are all opened by the
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
`virutil help` prints them in. The three transfer modules additionally share a
[transport](#transports) layer, which decides *how* the bytes move.

### domains

| Module | Purpose | Usage |
| --- | --- | --- |
| `domain` | The domain lifecycle: create one from an install ISO with a KVM-tuned profile, delete one along with its disks, and the everyday operations in between. | `virutil domain {create\|delete\|list\|start\|shutdown\|addr\|time\|port} [VM] [ISO] [OPTIONS]` |
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
| `usb` | USB passthrough end to end from a Windows host under WSL: `usbipd` bind, import over `vhci_hcd`, then attach to the domain. `usb media` is the virtual counterpart: a qcow2 handed to the guest as a removable drive. | `virutil usb {list\|show\|attach\|detach\|unbind} [VM] [BUSID]`; `virutil usb media VM [-s GiB] [SRC...]` |

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
and the two differ in what they need from the guest rather than in what they
achieve. `-t`/`--transport` picks one; **`virtiofs` is the default**.

There is no fallback. A transport that cannot work is an error naming the fix,
never a silent downgrade — turning "copy a file" into "reboot Windows" behind
your back is not a fallback. So `virtiofs` being the default makes its
[guest prerequisites](#guest-prerequisites) a prerequisite of the tool.

| | `disk` | `virtiofs` |
| --- | --- | --- |
| Guest must be | already shut off to write, running to read | running |
| Who writes `C:` | the host, through `ntfs-3g` | the guest, `robocopy` |
| Host side | `qemu-nbd` on the guest's own qcow2 | `virtiofsd` |
| Guest side | nothing | the agent, WinFsp, viofs |
| Domain change | none | shared-memfd RAM and a share device, both **cold** to add |
| Fixed cost per run | you shut the guest down and boot it again | none |

**`disk`** is the original, and the one that needs nothing at all from
inside the guest — which is what makes it the one to ask for when there is no
agent, no drivers, or the guest will not boot. For a write it needs the guest
**already shut off**: it mounts the guest's NTFS over `qemu-nbd` and copies.
It never shuts the guest down for you and never starts it again afterwards —
a guest that is not shut off is an error, not a reboot. For a read it leaves
the guest running and reads a frozen snapshot instead.

**`virtiofs`** exports a host directory the running guest sees live, so nothing
is copied twice. It is the default. It needs WinFsp and the viofs driver in the
guest, `virtiofsd` on the host, and guest RAM on a shared memfd — which
`virutil domain create` sets up by default, but which an older domain can only
gain through a full stop and start.

The share device itself is part of a domain from `virutil domain create`
onwards: it comes up with the guest, holds one drive letter for the life of the
domain, and is unaffected by a snapshot revert. A domain defined without one
still works — the device is hotplugged for the run and unplugged after it — but
then the guest re-enumerates it every time and takes whichever drive letter
happens to be free, and a run killed before its cleanup leaves the device
behind. That is the difference between the two: a transfer that means the same
thing twice, and one that mostly does.

A domain that predates this — or one created with `VIRUTIL_SHARED_MEMORY=0` —
keeps working on the hotplug path. To give it the persistent share instead, with
the domain shut off:

```sh
mkdir -p ~/.virutils/share/virutil-VM

# The memory backing goes first: libvirt refuses a virtio-fs device outright
# on a domain without it ("'virtiofs' requires shared memory").
virt-xml --connect qemu:///system VM --edit --define \
  --memorybacking access.mode=shared,source.type=memfd

virt-xml --connect qemu:///system VM --add-device --define --filesystem \
  type=mount,accessmode=passthrough,driver.type=virtiofs,driver.queue=1024,\
binary.path=/usr/lib/virtiofsd,source.dir=$HOME/.virutils/share/virutil-VM,\
target.dir=virutil-xfer
```

Both take effect at the next full start, not at a reboot from inside the guest.
`virutil` finds the share by its target tag, `virutil-xfer`, and takes the
source directory from the domain's own XML, so the directory above only has to
match what you put in the device.

### Everything a transport needs, at create time

A domain from `virutil domain create` carries what the default transport needs
in its definition: the guest-agent channel, the shared-memfd memory backing —
neither of which can be added to a running domain, the channel needing a cold
plug and `memoryBacking` a full stop and start — and the virtio-fs share
device, pointed at `~/.virutils/share/virutil-VM`, which is created with the
domain. That last one *could* be hotplugged, and is when a domain lacks it; it
is defined here so the guest sees the same share, at the same drive letter,
from boot and across a snapshot revert.

The `usb media` drive stays hotplug-only, since a permanently attached one would
be a second writer on an image the host has to mount. Neither device needs
domain preparation — `q35` comes with fourteen `pcie-root-port`s and a Windows
guest uses six.

What remains outside the XML entirely is guest-side software: `qemu-ga` (the
virtio-win MSI), and WinFsp plus the viofs driver for `virtiofs`.


## Guest prerequisites

Four pieces of software go **inside** the Windows guest. Three of them come off
the `virtio-win` ISO; WinFsp and the SPICE guest tools are downloaded
separately. `virutil domain create` attaches that ISO as a second cdrom
automatically, so on a fresh install it is already in the guest's drive list;
otherwise download it once:

- `virtio-win.iso` — <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>
- WinFsp — <https://winfsp.dev>
- SPICE guest tools — <https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe>

| What | Where it comes from | Needed by |
| --- | --- | --- |
| **virtio drivers** (`viostor`, `NetKVM`) | `virtio-win` ISO, or `virtio-win-guest-tools.exe` on it | booting at all — the installer cannot see a virtio disk without `viostor` |
| **QEMU guest agent** (`qemu-ga`) | `virtio-win-guest-tools.exe`, or `guest-agent\qemu-ga-x86_64.msi` on the ISO | `virutil exec` and the `virtiofs` transport |
| **SPICE guest agent** (`spice-vdagent`) | [spice-guest-tools](https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe) | the `spice` display and `spicevmc` channel of every `virutil domain create` domain — clipboard sharing and display auto-resize |
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

That single installer covers the drivers and `qemu-ga`. Then install the SPICE
guest tools (`spice-guest-tools-latest.exe`) from an elevated prompt — without
the `spice-vdagent` there is no clipboard sharing and the display does not
auto-resize. Then, for `virtiofs`:

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
virutil sync VM [-c NAME|PATH] [-t disk|virtiofs]
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
directory under `~/.virutils/staging/`, applying the exclude patterns. The staging layout is
normally arranged to mirror what will land in the guest, so the map rules stay
trivial.

**Push** attaches the disk image of the (already shut off) guest with
`qemu-nbd`, picks the largest NTFS partition on it, mounts that, copies the
staged files to their destinations, empties any directories listed for cleanup,
then unmounts and detaches. Starting the guest again is left to you.

Run it as yourself, **not** under `sudo`. It refuses to start when invoked under
`sudo`, because `$HOME` — and therefore config discovery — resolves to root's
home on any host whose sudoers sets `always_set_home`. Only the commands that
genuinely need root are escalated individually (`modprobe`, `qemu-nbd`, `partx`,
`blkid`, `blockdev`, `mkdir`, `mount`, `umount`), and you are prompted once
before anything is attached. Every `virsh` call runs unprivileged, which
requires membership of the `libvirt` group. The guest filesystem is mounted with
`uid=`/`gid=` set to the invoking user, so both copy phases and the cleanup pass
need no privilege of their own.

### Arguments and options

| Argument | Description |
| --- | --- |
| `VM` | libvirt domain whose disk is written. Required. |

| Option | Description |
| --- | --- |
| `-c`, `--config NAME\|PATH` | Config to use. A value containing `/` is a path, taken as given. Anything else names a config, looked up in `~/.virutils/conf/` first and then `~/.config/virutils/`, with `.conf` appended when absent — so `-c win11` reads `~/.virutils/conf/win11.conf` if it exists, else `~/.config/virutils/win11.conf`. Defaults to `sync.conf`, resolved the same way. |
| `-t`, `--transport T` | How to move the files: `virtiofs` (default) or `disk`. See [Transports](#transports). Overrides `@transport` in the config. |
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
| `>pre CMD` / `>post CMD` | Run `CMD` inside the guest, before or after the files land. |

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
| `@transport` | no | `virtiofs` | Default transport for this config. `-t` on the command line wins. |

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

#### Run rules

```
>pre  Stop-Service -Name ExampleSvc -Force
>post Start-Service -Name ExampleSvc
>post & 'C:\Program Files (x86)\Example\Product\setup.exe' /S
```

Each line is a PowerShell command run **inside the guest**, through the same
guest-agent path as [`virutil exec ps`](#virutil-exec) — as `SYSTEM`, with the
guest's output printed here. The phase keyword comes first and is required:

| Phase | When it runs |
| --- | --- |
| `pre` | After the fetch and the staging copy, immediately before the files reach the guest's `C:`. This is where a service is stopped or a running binary is killed, so the delivery does not hit a locked file. |
| `post` | After the delivery *and* after the cleanup rules — so an installer or a service start sees the final state. |

Rules run in the order they appear in the config, and the first one that exits
non-zero aborts the run: a rule exists to make the copy land correctly, so
carrying on past one that did not happen would report success on a
half-installed guest.

The phase is spelled out rather than defaulted because a command is free text —
`>Stop-Service ...` could not be told apart from a missing keyword. `#` still
starts a comment on these lines, so a command cannot contain one.

Run rules need the guest **running**, with the guest agent answering, so they
work only under the `virtiofs` transport. A config with run rules under
`-t disk` is rejected before the fetch starts, since that transport writes to
the image of a guest that is shut off.

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

# run: free the locked binary first, put the service back afterwards
>pre  Stop-Service -Name ExampleSvc -Force
>post Start-Service -Name ExampleSvc
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

**Under `-t disk` the guest must already be shut off**, and stopping and
starting it is yours to do. A guest in any other state — running, paused,
pmsuspended — is a hard error before the fetch starts, not something the run
resolves by shutting Windows down. Writing to the qcow2 of a guest that has it
open would put two writers on one image, and shutting a guest down is not a
decision this tool can make for you: it may be mid-install, mid-update or
holding unsaved work. So the sequence is spelled out:

```
virutil domain shutdown win11     # wait for it to reach 'shut off'
virutil sync win11 -t disk
virutil domain start win11
```

The run leaves the guest shut off when it finishes, on success and on failure.

**Nothing is ever forced off.** There is no `virsh destroy` anywhere in this
path. Cutting power to a live Windows leaves the NTFS volume dirty — the same
state Fast Startup causes above — so the disk would be unmountable read-write
on the next run, and an interrupted write can leave the guest unbootable. If
you decide to force it, do that by hand and expect to boot Windows once to let
it check the volume.

**Install `qemu-guest-agent` in the guest.** Nothing in the `disk` transport
needs it now that the shutdown is yours, but `virutil exec` and the `virtiofs`
transport both require it outright — and it is what lets you shut the guest
down with `virsh --connect qemu:///system shutdown VM --mode agent`, which
calls Windows' own shutdown with applications forced closed rather than an
ACPI power-button event Windows is free to deliberate over. Either way it is a
real shutdown, so Windows closes the NTFS volume and the disk is left clean.
See [Guest prerequisites](#guest-prerequisites), then confirm the host can see
it:

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
guest's `C:` drive onto the host, over any of the three
[transports](#transports). It never powers the guest off.

### Synopsis

```
virutil pull VM SRC DST [-t disk|virtiofs]
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

Under `virtiofs` (the default) the guest does the reading: the path is
resolved *in Windows* and `robocopy`'d into the share, which the host then
reads. That is file-level consistency, and it needs
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
offline path: with the guest **already shut off**, attach its qcow2 with
`qemu-nbd`, mount the NTFS, copy, and leave it shut off for you to start again.
A guest that is not shut off is an error — `push` will not shut it down.

### Synopsis

```
virutil push VM SRC DST [-t disk|virtiofs]
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
`modules/guest`. Under `virtiofs` none of it applies — the guest is never
stopped, and nothing but the share directory is touched on the host. There are no
excludes — `push` copies exactly what you name, which is the point of having it
at all.

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
- **Guest RAM backed by a shared memfd**
   (`<memoryBacking><access mode='shared'/><source type='memfd'/>`), because a
   vhost-user device — **virtio-fs** above all — cannot attach to a guest whose
   memory the host cannot map, and `memoryBacking` is a *cold* setting: adding
   it to an existing domain costs a full shutdown and start. Carrying it is free
   (the memfd is sized, not preallocated, so an idle guest uses no more host
   memory than before). `VIRUTIL_SHARED_MEMORY=0` opts out, and takes the share
   below with it.
- **The qemu-guest-agent channel** (`org.qemu.guest_agent.0`). `virt-manager`
   does not add it and nothing inside the guest can, yet the `virtiofs`
   transport needs it — it is what runs the copy in Windows — and it is also
   what makes `virsh shutdown --mode agent` Windows' own shutdown with apps
   forced closed, rather than an ACPI event the guest may sit on. It costs one
   virtio-serial port, so it is not optional and there is no flag to leave it
   out.
- **The virtio-fs share device**, tagged `virutil-xfer` and pointed at
   `$VIRUTILS_DIR/share/virutil-VM`, which is created with the domain. This is
   what makes a file transfer repeatable: the device is enumerated once at boot,
   keeps one drive letter for the life of the domain, and survives a snapshot
   revert, where a per-run hotplug would be re-enumerated each time, take
   whichever letter was free, and be left plugged in by any run that died before
   its cleanup. The cost is one PCIe port, an idle `virtiofsd` per running
   domain, and a directory that is empty except during a transfer — virutil
   clears it at both ends of every run, so nothing it carried stays readable in
   the guest afterwards. Skipped, with a warning, when
   `virtiofsd` is not installed on the host; a domain without it falls back to
   hotplugging per run.
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
| `VIRUTILS_DIR` | `~/.virutils` | Root of everything virutil leaves on the host. Moves configs, images, staging, shares, port state and mount points at once. See [Artifacts and state](#artifacts-and-state). |
| `VIRUTILS_IMAGE_DIR` | `$VIRUTILS_DIR/images` | The images directory. |
| `VIRUTIL_IMAGE_DIR` | `$VIRUTILS_IMAGE_DIR` | Legacy name, still honoured: where a domain's disk image goes, and where `snapshot` writes overlays. |
| `VIRUTIL_OSINFO` | `win11` | Fallback libosinfo id when the ISO is not recognised. |
| `VIRUTIL_VIRTIO` | `virtio-win*.iso` beside the install ISO | Default for `-v`: driver ISO to attach as a second cdrom, or `none`. |
| `VIRUTIL_NETWORK` | `network=default,model=virtio` | Passed to `virt-install --network`. |
| `VIRUTIL_FIRMWARE` | `uefi` | `bios` selects SeaBIOS instead. Windows 11 will not install without UEFI. |
| `VIRUTIL_SHARED_MEMORY` | `1` | `0` leaves guest RAM on private anonymous memory, which makes virtio-fs impossible without a later cold restart, and drops the share device from the domain along with it. |
| `VIRUTIL_TIME_SYNC` | `1` | `0` stops virutil syncing the guest clock on its own — after a snapshot revert, and before a transfer. See [time](#time). |
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
| `usb media` drive image | `images/VM-usb.qcow2` |
| `virtiofs` share directory | `share/virutil-VM/` |
| Host mount points | `mnt/VM`, `mnt/VM-usb` |
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

That skew is not cosmetic here, because timestamps are what every transfer
compares. `rsync` and `robocopy` both skip a file whose destination is not older
than the source, so a guest running *ahead* of the host turns `sync` and `push`
into silent no-ops, and one running *behind* does the same to `pull`. So virutil
syncs the clock at the two points the skew appears:

- after `virutil snapshot revert`, waiting up to `VIRUTIL_TIME_SYNC_WAIT`
   seconds (default 60) for the agent to come back up with the guest;
- before every `sync`, `pull` and `push` over the `virtiofs` transport, where the agent is already known to be answering, so it costs one
   round trip and never waits.

A guest already within two seconds of the host is left alone and nothing is
printed. The `disk` transport is not included: it writes the guest's filesystem
from the host with the guest shut down, and a guest reads the host's RTC when it
boots. `VIRUTIL_TIME_SYNC=0` turns off all of the automatic ones;
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

Two families under one command. The passthrough half manages physical devices
shared from Windows: `usbipd` binds a device on Windows, imports it into WSL
over `vhci_hcd`, and attaches it to the domain as a USB host controller device;
`detach` and `unbind` hand it back.

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

### usb media

`usb media` is the virtual counterpart: no physical device, just a sparse qcow2
the host fills over qemu-nbd and hands to the guest as a `usb-storage` device,
which Windows lists under **removable media**.

```
virutil usb media VM [-s GiB] [-f TYPE] [SRC...]
virutil usb media VM --mount
virutil usb media VM --eject
virutil usb media VM --detach
```

| Argument | Meaning |
| --- | --- |
| `SRC...` | Host files and directories to copy into the drive before it is attached; each keeps its basename at the drive's root. |
| `-s`, `--size` | Drive size in GiB, honored only when the image is first created (default 4). Ignored once it exists. |
| `-f`, `--fs` | Filesystem when the image is first created: `exfat`, `ntfs`, `fat32`, or `guest` (let Windows format it). Defaults to exfat when the host can, else ntfs, else guest. Ignored once it exists. |

Run with no options: the drive is created once per VM and kept, filled from
`SRC` (empty if none), and attached to the **running** VM as removable media.
Idempotent: if the drive is already attached, nothing happens. `--mount` is the
host half for hand-filling — it works with the domain shut off, mounts the
image at `~/.virutils/mnt/VM-usb`, and prints the command that hands it over
afterwards. `--eject` flushes and detaches the drive in the guest, keeping the
image; `--detach` unmounts and releases it on the host, refusing while the
guest still has it.

The host and the guest take strict turns with the drive: it is never mounted
on the host while it is attached in the guest, and the handover refuses if
either probe still holds the image. The image lives at
`~/.virutils/images/VM-usb.qcow2`, 4 GiB and sparse, created and formatted on
first use and kept afterwards. Delete it to rebuild it.

Formatting is one GPT partition spanning the disk, exFAT when the host can
(an in-kernel driver on both sides, where NTFS on the host is FUSE), NTFS otherwise,
and Windows itself when neither exists — the last attaches the blank drive
once and runs `Initialize-Disk`/`Format-Volume` inside the guest, which always
formats NTFS. `-f`/`--fs` overrides the policy with one of `exfat`, `ntfs`,
`fat32` or `guest`, and the choice sticks to the image once made. The guest
must be running with the [QEMU guest agent](#guest-prerequisites) answering
for both the in-guest fallback and `--eject`, since the agent is what flushes
the drive before it is detached.

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
- `disk` — nothing further

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
- The QEMU guest agent, for `virutil exec` and for the `virtiofs` transport,
   which runs the guest-side copy through it. Still worth having for `disk`,
   where it is what lets you shut the guest down with `--mode agent` instead of
   waiting on ACPI
- The SPICE guest tools, for the `spice` display and `spicevmc` channel every
   `virutil domain create` guest has — without the vdagent there is no
   clipboard sharing and the display does not auto-resize
- For the `disk` transport only: Windows with Fast Startup disabled, and a
   single disk whose system volume is the largest NTFS partition on it

The `org.qemu.guest_agent.0` channel itself is part of every domain
`virutil domain create` makes; nothing has to be added on the host side.

## See also

`virsh(1)`, `qemu-nbd(8)`, `ntfs-3g(8)`, `rsync(1)`, `usbipd(1)`
