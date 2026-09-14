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

virutil snapshot create VM [SNAP]        # Linux host only; default snap-<timestamp>
virutil snapshot list   VM               # Linux host only
virutil snapshot revert VM SNAP          # Linux host only
virutil snapshot delete VM SNAP          # Linux host only

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
script using them is a script for one host. `snapshot` is marked the same way
for the same reason, the other way round: it was on both drivers and was taken
out of the Windows one (section 7). Everything else above is both drivers'.
Section 9 says what each flag *does* where the two cannot agree.

Invariants that are contract, not implementation:

- `push`/`pull`/`sync` require the domain **running**; delivery goes over the
  guest's own network and touches neither the disk image nor guest uptime.
- `SRC`/`DST` guest paths are relative to the guest root -- `C:\` on Windows,
  `/` on Linux. Backslashes and a `C:\` prefix are tolerated; `..` is refused.
  A trailing slash means a directory, as with rsync.
- `pull` wildcards match with the *guest's* own matching: case-insensitive on
  Windows, case-sensitive on Linux.
- **On a Windows host, `push` and `pull` reach a Windows guest only**, and say
  so by name when asked for any other kind. That is a gap in the port rather
  than in the grammar -- the Linux-guest side is payload selection against
  payloads that already exist -- and section 7 says what is still unmeasured
  about it. The same host also prompts once per transfer for Administrator and
  mints a throwaway local account, because the share comes from its own SMB
  server; the grammar, the guest-side behaviour and the exit codes are
  unchanged by that.
- `domain delete` never prompts and removes disks, backing chain, snapshot
  overlays and memory files, mount points and port forwards; files another
  domain uses are kept.
- `snapshot delete` takes SNAP's descendants with it and commits no disk data.
- **`snapshot` is a Linux-host command.** There a running domain snapshots
  memory too and a shut-off one is disk-only. It is not on the Windows driver
  at all: WHPX installs a migration blocker, so `savevm` refuses before it
  reaches any disk (measured -- section 7 quotes it), and a snapshot that can
  only ever be a disk is not worth the name. `virutil snapshot` on a Windows
  host is refused by name with that reason, never silently.
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

The overlays and memory files in the `images` row are the Linux host's alone:
`snapshot` is a Linux-host command (section 7), so a Windows host's `images`
holds disks, nvram, launchers and logs and nothing any snapshot left behind.

Root is `~/.virutils` on Linux and `%USERPROFILE%\.virutils` on Windows. The
staging tree must survive a reboot -- this is why it is not an XDG/`%TEMP%`
directory.

Every driver knows the whole layout and relocates it from the same variables,
but a driver only creates the directories it actually writes to. The Windows
driver writes to `images` and to `tmp`: `conf` and `staging` belong to `sync`,
which is not ported there yet, `mnt` is for host mount points it never makes,
and `ports` holds the relay state and logs of a mechanism it does not have --
under user-mode NAT a forward is a `hostfwd` on the qemu command line, so it
lives in the launcher with every other qemu argument and needs no state of its
own. `cache` follows `ui`. **An empty directory is not a promise**: what section
3 fixes is where a thing goes when there is one, not that every driver puts
something in each.

`tmp` stopped being an empty promise on the Windows host when `push` and `pull`
landed there. Each transfer gets `<root>/tmp/<token>/`, holding its staging
tree, the status file the elevated helper answers through, and that helper
itself; all three go at teardown. It is deliberately not the system temp
directory: under elevation `%TEMP%` resolves to an 8.3 short path that an
ordinary recursive remove refuses to delete through.

**A transfer's staging tree is under `tmp`, not under `staging`**, and the
distinction is what each row means rather than an inconsistency. `staging` holds
`sync`'s *incremental* trees, which outlive a run and are what make the next one
cheap; a transfer's staged copy exists for one transfer and is deleted with the
share and the account it was published for. Putting it under `staging` would put
something disposable in the one directory whose contents are meant to survive.
So `staging` stays `sync`'s and is still empty on a Windows host.

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
| 98 | the elevation prompt was declined (Windows host, push/pull) |
| 99 | the host could not publish the share (Windows host, push/pull) |

Otherwise the guest's own exit code passes through (`exec`).

90 through 95 are the guest's, and are the same on both hosts. 98 and 99 are
the Windows host's alone: a transfer there publishes a share on the host's own
SMB server, which needs Administrator, and neither failure has any counterpart
on a Linux host. They are two codes rather than one because declining the
prompt is an answer rather than a fault -- a script wrapping `virutil push` has
to be able to tell "I clicked No" from "SMB is broken". 99 covers the rest of
the host setup (the share, the account, the filesystem ACL) with the specifics
in the diagnosis text.

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
payloads/mount.ps1      Windows guest  authenticate to a credentialled share
payloads/unmount.ps1    Windows guest  let go of it again
```

Nine of them rather than the five this section first guessed at, because push
needs two shapes on each side: robocopy cannot rename onto a new name, so a
single file goes through Copy-Item, and the rsync side is split to match rather
than to differ. The last two came later and are a different kind of thing.

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
a filter on its parent. Keep it in one place. `tests/payloads.sh` and
`tests/payloads.ps1` render all eleven under both drivers and diff the result
against one golden file, which is what makes "byte-identical" a fact rather than
an intention.

## 7. Scope

Not every module ports. What the Windows driver ships today is:

`domain`, `exec`, `push`, `pull` and `usb`. `sync` is the remaining intended
surface; `ui` is bash-only, and `snapshot` is bash-only now as well. All of them
are below. A module that works beats two half-ported.

**Where it actually is:** `domain` and `exec` are ported, and the guest agent
channel they both stand on is in place. `usb` is on both drivers. `snapshot` was
ported and has been taken back out -- the question this section used to leave
open was measured, the answer was no, and the answer took the command with it,
below. `push` and `pull` are ported, against a **Windows guest**: the question
they were blocked on was measured and decided, and what was decided is recorded
below. `sync` is not ported, and neither is a Linux guest from a Windows host;
both are later passes on the transport that now exists rather than new
questions. `ui` is bash-only.

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
exactly the command line `modules/domain.ps1` writes:

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
`modules/parser.ps1` is where that reason lives, and it is the right home for
`sync` and `ui` too. `push` and `pull` were on that list and have left it: they
are in `$MODULES` now.

The bash driver is untouched. Its `snapshot` is external overlays plus a memspec
through libvirt, it captures memory for a running domain, and none of this
reaches it.

**What the removal deleted,** for a reader comparing the two trees:
`modules/snapshot.ps1` -- qcow2 internal snapshots, `qemu-img snapshot -c/-l/-a/-d`,
one image, no overlay or memory files of its own -- and `tests/snapshot.ps1`.
The bash module's in-use analysis (the sweep, the backing-chain walk, the
refusal to unlink a file the guest still reads) never had a counterpart here,
because an internal snapshot is a region of a disk image rather than a file.
That asymmetry is now moot rather than vacuously satisfied.

`ui` (PsExec) ports: it is Windows-*guest*-only, but host-portable -- it
delivers over the same transport as `push`, which means smbd on a Linux host
and `New-SmbShare` on a Windows one.

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
changes. That deletes the whole samba and rsyncd half of `modules/xfer`.

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
auth question does not decide whether `push` needs elevation. It does.

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
transfer.** `modules/xfer.ps1` is what that became, and these are the parts of
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
  One prompt per transfer. The helper keys its teardown on waiting for the
  *parent's* process to exit, which is the nearest thing this host has to the
  `trap ... EXIT` the bash transport relies on: teardown fires on Ctrl-C, on an
  exception, and on the run being killed while the agent hangs.
- The two halves cannot use a pipe, and the reason is measured rather than
  assumed: `Start-Process -Verb RunAs -RedirectStandardOutput` is a parameter-set
  error, because the verb requires ShellExecute and ShellExecute forbids
  redirection. The parent passes the token, the account and the password down as
  arguments and the helper answers upward through a status file.
- **Every transfer stages**, into `<root>/tmp/<token>/`, and the staged copy is
  what the share points at. This diverges from the bash driver, which serves a
  directory source in place, and the divergence is deliberate: serving in place
  would mean editing the filesystem ACL of the developer's real tree and -- since
  a share here cannot be bound to an interface -- offering that tree on every
  network the host is attached to. `pull` seeds its staging tree from the
  destination first, so the guest still sees what the host already holds and
  still sends only what differs.
- **Nothing is created and nothing is prompted for until the transfer is known
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

`tests/conformance.sh` runs the part of that which needs no guest, against both
drivers:

| | |
|---|---|
| `tests/conformance.sh` | the runner. Every `--help` exits 0, every usage error exits 1, in both drivers; drives the two below. |
| `tests/payloads.sh`, `tests/payloads.ps1` | render all eleven payloads under each driver and diff both against `tests/golden/payloads.txt`. This is what makes section 6's "byte-identical" checkable. |
| `tests/domain.ps1` | the launcher round trip: monitor port, agent channel and port forwards written, read back, edited and read again. |
| `tests/xfer.ps1` | `push` and `pull` on a Windows host with both seams substituted -- the guest agent and the share publisher -- so the guest path rules, credential generation, the free-space refusal, the sweep's liveness decision, the rendered payload and the teardown all run with no VM and no Administrator. |
| `tests/transfer.ps1` | the guest tier: the transfer minimum below, plus the property that a completed transfer and a killed one both leave no account, no share and no staged tree. |

The PowerShell half skips itself, loudly, on a host with no `pwsh`, and
`tests/transfer.ps1` skips itself the same way when no guest is up. When a guest
*is* up it is the only interactive test in the suite: a transfer on a Windows
host prompts for Administrator once, and suppressing that would mean installing
a service.

**Still missing, and named so it is not mistaken for covered:** `exec`
propagating a guest exit code against a real guest, and `domain create` leaving
exactly the files section 3 names. The `push`/`pull` round trip and the second
`push` moving nothing were on this list and are now in `tests/transfer.ps1`.

## 9. Host-specific behaviour that is *not* contract

Documented so nobody "fixes" one driver to match the other. The header of
`modules/domain.ps1` records how each was bisected on the Windows host, and is
the place to read before changing one: `-cpu Skylake-Client` rather
than host-passthrough, `threads=1` rather than an SMT topology,
`cache=writeback` rather than `cache=none,io=io_uring`, `-vga std` rather than
virtio. No kvm (WHPX instead, so no hyperv enlightenments), no swtpm, no
libvirt network.

One entry in that header is a defect rather than a setting, and it changes what
an install has to be *told* rather than what either driver promises. On the qemu
build the Windows driver runs, a guest with more than one vcpu dies at its own
reboot -- `failed to get xsave state` once per vcpu, then `WHPX: Unexpected VP
exit code 4`, leaving the domain paused with vcpus that cannot be restarted. It
fires at Setup's own reboot, so it looks like an install that got most of the
way and then failed. The fix is upstream and dated after the newest published
Windows build of qemu, so until there is a build to move to, `domain create`'s
usage says to install with `-c 1`. It costs an install its uptime, not its disk.

A guest-initiated reboot on that host has a second way to die, and clearing the
first one only exposes it: the firmware itself wedges, with OVMF asserting on a
stale MTRR default type (`MemDetect.c(1181)`) because WHPX does not reset the
MTRR MSRs across a guest reset. The domain is left *running* rather than paused,
spinning a core in `CpuDeadLoop` behind a window that never paints, which is how
the two are told apart. A new qemu process clears it; the vcpu count does not
affect it. Neither is contract -- both are one host, one qemu build and one
DEBUG firmware -- but between them they are why an install there is done at
`-c 1` and restarted at each of Setup's own reboots.

### Where the grammar bends, and why

Five places, each because the host cannot mean what the other one means.

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

The same rule covers the environment. `VIRUTILS_OSINFO`, `VIRUTILS_NETWORK` and
`VIRUTILS_FIRMWARE` are read by the Windows driver and acted on by none of it,
so `domain create` names each one that has actually been set and says it is
being ignored. `VIRUTILS_FIRMWARE=bios` gets more than that: it asks for a
machine Windows 11 will not install on, so it is called out as unhonourable
rather than merely unused.
