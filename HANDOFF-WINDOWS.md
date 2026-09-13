# Handoff: virutil.ps1, a second driver for a Windows host

Date: 2026-09-13. Host: Windows 11 Enterprise 26100, 22 logical CPUs, 32 GiB,
no libvirt, QEMU under WHPX, pwsh 7.6.5. Read `HANDOFF.md` first -- it is the
record of what was bisected on this box, and none of it should be re-derived.

## The decision (unchanged)

virutil ships as **two programs, not one program with a platform layer**:

| | |
|---|---|
| `virutil` | bash, Linux host, libvirt/KVM. |
| `virutil.ps1` | PowerShell, Windows host, raw QEMU under WHPX. |

They share no source. Three rules make that survivable, and they are the job:

1. **Share the contract, not the code.** `docs/contract.md`: command grammar,
   state layout, exit codes, invariants. A change there is a change to both
   drivers or it is a bug.
2. **Share the guest payloads as data.** The scripts sent *into* a guest are
   keyed on the guest's OS, never the host's, so they are byte-identical under
   both drivers.
3. **Port only what earns it.** Four modules that work beat ten half-ported.

## What changed this session

Rules 1 and 2 are no longer aspirations. The ordered list in the previous
handoff -- agent channel, driver shape, `domain` -- is done, and the two open
decisions it named are settled.

### Rule 2: `payloads/` is extracted

Nine files, not the five the contract first guessed at -- push needs two shapes
on each side, because robocopy cannot rename onto a new name. Both drivers read
them through a renderer (`modules/payload`, `modules/payload.ps1`) that fills
`@NAME@` as a quoted literal in the payload's own language and `@@NAME@@` raw.

This was done **before** writing the second driver, which is what stops the
payloads being transcribed by hand and drifting. The proof that it worked:
`tests/golden/payloads.txt` was captured from the *old* bash code before any of
it moved, and both renderers now reproduce it byte for byte.

Two things came out of doing it rather than planning it:

- **`${var//pat/$repl}` in bash 5.2 treats an unquoted `&` in the replacement as
  the matched text.** Splicing `probe.sh` in unquoted turned its own `2>&1` into
  `2>@@PROBE@@1` -- a payload that would have reached a guest looking like a
  redirection to a file named `1`. Every replacement in `modules/payload` is
  double-quoted, and it is load-bearing.
- **Push and pull use different exit codes for the same failure** (93 vs 95 for
  robocopy, per contract section 5), so the placeholders are `@@RC_PUSH_ROBO@@`
  and `@@RC_PULL_ROBO@@`. A single `@@RC_ROBO@@` silently gave `pull` push's
  code; the golden diff caught it.

### Rule 1: the env var spelling is settled

**`VIRUTILS_`, plural, everywhere.** The singular `VIRUTIL_*` is still read,
second, with one deprecation line. Both drivers do this. The old state -- plural
in `modules/paths`, singular preferred in `modules/domain`, singular in the
PowerShell draft -- meant one config pointed the two drivers at two directories.

### Step 0: the guest agent channel

Every domain `create` makes now carries it:

```
-chardev pipe,id=qga0,path=virutil-<VM>-qga
-device  virtio-serial
-device  virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
```

A Windows named pipe rather than a unix socket; qemu prefixes the path with
`\\.\pipe\` itself, so the pipe name is derived from the domain name and there
is no per-VM record to keep in step. `modules/guest.ps1` speaks the
newline-delimited JSON protocol to it directly -- which is *simpler* than the
bash driver's `virsh qemu-agent-command`, because there is no libvirt in the
way. Two things in there are not optional:

- **`guest-sync-delimited` before every exchange.** The channel outlives the
  host process that last used it, so an unread reply from an interrupted run is
  still in the buffer and the next command would read it as its own. The
  delimiter is a **raw 0xFF byte** -- putting U+00FF in a UTF-8 string gives
  0xC3 0xBF and the sync silently never happens.
- **`ReadAsync` with a wait, not `Read`.** `NamedPipeClientStream` honours no
  `ReadTimeout`, so a synchronous read for a byte that is never coming blocks
  forever and no deadline checked around it is ever reached.

**What of this has actually been checked, and what has not.** Launching a real
qemu on this host with exactly the three arguments above creates
`\\.\pipe\virutil-<VM>-qga`, and `Open-GuestAgent` connects to it, waits out its
timeout for a sync nobody answers, and returns `$null` in ~1.6s rather than
hanging. So the chardev syntax, the pipe name and the timeout path are measured.
**The protocol is not.** Nothing has ever read a reply from a real qemu-ga --
the sync handshake, the `guest-exec` round trip and the base64 stream decoding
are all written against the documented protocol and nothing more.

#### The chardev does not go back to listening, and it changed the design

Probing that pipe found something worth more than the probe. **qemu's chardev
accepts a client once and then refuses.** Measured against a real qemu carrying
exactly the arguments `domain create` writes:

| chardev | connections accepted |
|---|---|
| `pipe,id=qga0,path=...` | 1, then refused |
| `socket,...,server=on,wait=off` | 2, then refused |

Neither recovers with time (retried at 2s intervals). The first draft of
`modules/guest.ps1` opened a connection per agent command, so `exec` -- which
polls `guest-exec-status` in a loop -- would have worked for exactly one round
trip and then failed for the life of the VM, in a way that reads as "the agent
stopped answering". It now opens one channel lazily, holds it for the run, and
closes it once in `virutil.ps1`'s `finally`.

**This probe has a confound and the numbers above may be wrong.** It was taken
with no guest, so nothing ever opened the guest side of the virtserialport, and
qemu's chardev may simply not run its ordinary disconnect handling in that
state. What is *not* in doubt is that one held channel is the right shape
regardless -- which is why the design changed without waiting for a guest.

**What this leaves open, and it is the first thing to measure once a guest
exists:** whether a *second* `virutil` run can reach a VM the first one already
talked to. If the chardev really is one-shot with a guest attached, then `exec`
works once per boot, and the answer is a `socket` chardev with QEMU's own
reconnect handling rather than a pipe. Two `virutil exec ping` runs back to back
settle it; do that before building anything on top.

### Steps 1 and 2: the driver shape, and `domain`

`virutil.ps1` dot-sources `modules/*.ps1` and dispatches to `<Name>-Main`,
mirroring the bash driver's `modules/*` and `<name>_main`. `modules/` holds
both trees; this one's files have no extension, the Windows driver's are `.ps1`,
and each loader skips the other's.

`domain` is complete: `create`, `delete`, `list`, `start`, `shutdown`, `addr`,
`port`. `exec` is complete. `virutil-qemu.ps1` is gone -- it is
`virutil.ps1 domain create`.

**The launcher is the domain, and that is now load-bearing rather than a
description.** There is no sidecar state file: the monitor port and every port
forward are *read back out of the `.cmd`*, and `domain port` edits it in place
and applies the change live over the monitor at the same time. One file per
domain, and nothing that can disagree with the machine it describes.

Consequences worth knowing:

- The monitor port is **allocated per domain** at create time, not fixed at
  55555. Two VMs at once used to mean the second one's monitor silently failed
  to bind and every monitor command went to the first.
- `Get-DomainMonitorPort`'s regex must tolerate the quote: the launcher quotes
  any value holding a comma, and `-monitor` always does.
- `Test-DomainRunning` asks the monitor, not the process table. A qemu whose
  monitor does not answer is not a domain this driver can drive.

## Where the grammar bends

Recorded in contract section 9 so nobody "fixes" it:

- **`domain addr` has no answer here.** It prints the forwards and says the
  guest address is not reachable. Exit 0 -- the question has an answer.
- **`create -o ID`** is accepted and ignored: no libosinfo on this host.
- **`create -p SPEC` and `-N`** are Windows-only additions. Without a libvirt
  network a forward is the only way in, so create has to be able to make one.
- **`start -s/-m/-c` is refused, not ignored.** Those rewrite a libvirt domain
  config and there is none here.

## Tests

`tests/conformance.sh` -- both drivers, 37 checks, all passing. It runs the part
of contract section 8 that needs no guest:

| | |
|---|---|
| both drivers | every `--help` exits 0, every usage error exits 1. The module list is read out of each driver, so a module added there is tested here without an edit. |
| `tests/payloads.{sh,ps1}` | all nine payloads rendered under each driver and diffed against one golden file. |
| `tests/domain.ps1` | the launcher round trip: monitor port, agent channel and forwards written, read back, edited, read again. |
| `tests/exec.ps1` | the guest's exit code becomes virutil's -- including for a signalled process, where qemu-ga sends no `exitcode` at all. |

It also found a pre-existing bug in the bash driver: `virutil exec -h` exited 1
where the contract says 0. Fixed.

The golden file is the load-bearing one. It was captured from the *old* bash
code before any payload moved into `payloads/`, so both renderers reproducing it
is evidence the extraction changed nothing -- not merely that the two agree with
each other today.

## What to build next, in order

### 1. The transfer layer -- and settle its one open question first

`sync`, `push` and `pull` are blocked on a design decision, not on effort, and
it is a security decision rather than a plumbing one. **Do not start coding
until it is answered.**

The plan is still right: collapse both guest OSes onto SMB, because Windows *is*
an SMB server natively and a Linux guest can `mount -t cifs` and rsync against
the mount. The guest-side robocopy/rsync split survives untouched; only what the
guest mounts changes. That deletes the entire samba and rsyncd half of
`modules/xfer`.

**What has no answer yet is authentication.** The bash driver's smbd runs
`map to guest = Bad User` with `guest ok = yes`, so the guest fetches with no
credential at all. Windows' own SMB server has no equivalent that is on by
default -- the `Guest` account is disabled, and since Windows 10 1709 the SMB
*client* refuses insecure guest logons too, so a Windows guest would decline the
share even if the host offered it. The three ways out all cost something
(a throwaway local account per transfer; the user's own password in a payload;
turning off a protection the host has for unrelated reasons) and they are
written out in contract section 7.

**Measure it before designing around it.** The client-side refusal above is
stated from documented Windows defaults, not from a test on this host -- and
there is no installed guest here to test it on yet (see `HANDOFF.md`). Finish
the Windows install, then try a `New-SmbShare` from the host and a `net use`
from the guest, and let what actually happens decide.

The one thing that must not change: **the guest fetches, the host never
pushes.** Under user-mode NAT the host cannot open a connection to the guest at
all, but the guest can always reach the host at `10.0.2.2`. The architecture
happens to be exactly what slirp allows. Do not "improve" it into a
host-initiated push -- a `hostfwd` would make it technically possible and it is
still the wrong shape.

### 2. `exec` against a real guest

`modules/exec.ps1` is written and its shape is tested, but **nothing in it has
ever talked to a guest agent** -- there is no installed guest on this host. The
named-pipe channel in particular is the piece most likely to be wrong in a way
no offline test can see. Do this first after the install finishes; everything
downstream stands on it.

### 3. `ui`, and `snapshot` only if step 1 changes the answer

`ui` (PsExec) ports -- it is Windows-*guest*-only but host-portable, and
delivers over the same transport as `push`, so it waits on step 1.

**`snapshot` was the third open decision, and it now has an answer: four
modules.** Not on effort. Half of it ports almost for free -- the overlay chain
is policy and `qemu-img` is the platform. The other half does not: the contract
says a running domain snapshots memory too, and memory is libvirt doing a
managed save. On raw QEMU that is `migrate "exec:..."` or `savevm` over the
monitor against a WHPX guest, with `revert` having to put the domain back. That
is a new mechanism, not a port.

Shipping only the disk half would be worse than shipping nothing: `snapshot
create` on a running domain would quietly mean something different on the two
hosts, and a snapshot that did not capture memory is found out at `revert`.
Contract section 7 records the criterion for revisiting it.

## What does not port

**`usb` is WSL-only and belongs to neither driver.** It needs both hosts at
once: `usbipd.exe` on the Windows side, `vhci_hcd` in the WSL kernel to receive
the import, `virsh attach-device` to hand it to the domain. It stays in the bash
tree, gated on WSL, and is out of the shared grammar.

If this driver ever wants USB it is a **different and simpler mechanism**: QEMU
and the device are on the same machine, so it is
`-device usb-host,vendorid=...,productid=...` with no bind/attach round trip at
all. `unbind` has no meaning there and should not be implemented for symmetry.

## Traps

Each of these cost a bisect once already.

- **The four WHPX findings in `HANDOFF.md` are not preferences.**
  `-cpu Skylake-Client` (not host/max), `threads=1` (not an SMT topology),
  `cache=writeback` (not `cache=none,io=io_uring`), `-vga std` (not virtio).
  Each hangs or fails in a way that reads as an unrelated bug.
- **Diagnosing a black window:** `-debugcon file:ovmf.log -global
  isa-debugcon.iobase=0x402`. A boot reaching the EFI shell writes ~110 KB; one
  hanging in MP init stops at ~7.8 KB with `CpuMpPei: 5-Level Paging = 0` last.
- **The boot prompt.** Windows Setup boots from CD only if a key is pressed.
  Unanswered, the firmware falls through to the UEFI shell, which looks exactly
  like a hang in a screenshot. `create` spams `sendkey ret` over the monitor for
  ~28s.
- **robocopy's exit code is a bitmap, not an error level.** 0 means nothing
  needed copying; failure is `>= 8`. And robocopy always takes a source
  *directory*, so a file is named as a filter on its parent.
- **`cache=none` on Windows** opens the image unbuffered and qemu then cannot
  read back its own qcow2 header: *"Image is not in qcow2 format"*.
- **PowerShell variable names are case-insensitive.** `$modules` and `$MODULES`
  are the same variable, and the driver's module loader clobbered its own module
  list with a path before it was renamed.
- **A PowerShell `switch -Regex` runs every branch whose pattern matches**
  unless each one breaks. A catch-all `'^-'` beside `'^(-s|--size)$'` refuses a
  flag it had just accepted.
- **`Set-StrictMode -Version Latest` turns an absent member into an exception,
  and qemu-ga omits members routinely.** `guest-exec-status` returns `signal`
  instead of `exitcode` for a process killed by one, so `$st.exitcode` throws
  `PropertyNotFoundException` -- and the one case `exec` most needs to report
  faithfully becomes a PowerShell error instead of an exit code. Read through
  `$x.PSObject.Properties.Name` for anything the agent may omit.
  `tests/exec.ps1` holds this.
- **`FileInfo.Target` is a `string[]` on Windows PowerShell 5.1 and a plain
  `string` on PowerShell 7.** Indexing it blindly takes the first *character* on
  7 -- `"C"` -- which then resolves against the working directory. `@($x)[0]`
  reads both.
- **`Remove-Item` cannot delete through an 8.3 short path**, `-LiteralPath`
  notwithstanding: `Test-Path` says the file is there, `Remove-Item` answers
  "An object at the specified path C:\Users\QUANG~1.PHA does not exist", and
  `[IO.File]::Delete` removes it. This broke `domain delete` on this very host,
  where `%TEMP%` is the short alias for the profile directory. The tilde is a
  red herring -- a directory *named* `FOO~1` deletes fine; what fails is a
  segment that is a real alias for a longer name. Windows gives one to any
  directory whose name is over eight characters or holds a dot, so an account
  called `quang.phan` has one. `Remove-VirutilsFile` in `modules/paths.ps1`
  exists for this, and `tests/domain.ps1` holds it.
- **`sed` leaves a CR on the line and `Get-Content` takes it off.** The two
  payload renderers strip comments with one each, so a clone with
  `core.autocrlf=true` would have them send different bytes into the same guest
  -- exactly what contract section 6 promises cannot happen. `.gitattributes`
  pins `payloads/**` and `tests/golden/**` to LF; do not remove it.

## Not done

- **Almost nothing has run against a guest.** The VM from the first session is still
  mid-install; see `HANDOFF.md`. Every module here is tested for shape, and the
  payload renderers are tested against each other, but no agent has answered and
  no file has crossed.
- `sync`, `push`, `pull`, `snapshot` and `ui` are bash-only. Step 1 above.
- No README change; the README still documents one program.
- `install.sh` installs the bash driver only. It needs no change to find the new
  directories -- `virutil` resolves through its own symlink -- but it does not
  install `virutil.ps1`.
