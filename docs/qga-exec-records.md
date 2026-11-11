# qemu-ga's exec records, and a pid that answers for another process

A `virutil sync` once printed `1153 files offered, all already current in the
guest` while nothing had been delivered: nine files that differed stayed stale
in the guest (an MDE-6273 run on win11-2, 2026-11-10). The copy never ran, and
the report read the missing result as "nothing to copy". This note records why,
and the defences both drivers now have. Read it before changing how
`modules/win/exec.ps1` or `modules/linux/exec` (and `modules/mac/exec`) waits
for a guest process, or how a transport reads the guest copier's line.

Source: QEMU v10.1.0, `qga/commands.c`. Line numbers below refer to it.

## How qemu-ga keeps track of a guest-exec

- `guest-exec` appends a record for the new process to a list
  (`guest_exec_info_add`, `QTAILQ_INSERT_TAIL`, l.122-132).
- `guest-exec-status PID` answers from the **first** record with that pid
  (`guest_exec_info_find`, l.134-145).
- A record is removed only when a `guest-exec-status` call finds it finished
  (l.171-218). Nothing else removes it: not the process exiting, and not time.
- When the process exits, qemu-ga marks the record finished and closes the
  process handle (`guest_exec_child_watch`, `g_spawn_close_pid`, l.259-268). On
  Windows that frees the pid, and the next process can be given it.

So a record that nobody polls to the end stays in the list, finished, after its
pid has gone back to the pool. The next `guest-exec` that is given that pid gets
a second record behind it. The caller's first `guest-exec-status` is answered
from the **old** record: `exited: true`, the old process's exit code, and its
output, which is none for a call started without `capture-output`.

Two kinds of call leave such a record:

- `virutil exec -d` (`capture-output: false`, and by design never polled);
- a waited-for call whose poller stopped early: killed, interrupted, or dead on
  an agent timeout.

Windows hands out freed pids again quickly, and a guest running Playwright and
browsers starts many processes, so a leftover record is met within hours.

## What it did to a sync

1. A detached run earlier that day (`exec ps -d`) left a finished record.
2. The sync's delivery payload, a `powershell.exe` running one robocopy, was
   given the same pid.
3. The first status call came back `exited`, exit 0, no output. Polling
   stopped, and the transport went on to unmount the share and retire it while
   the real payload was still starting. Its robocopy lost the share and copied
   nothing. Nobody was listening for its error.
4. `Write-SyncReport` read the missing `"<copied> <ms>"` line as `copied = 0`,
   took the host's own clock for the duration, and printed "all already current
   in the guest ... in 44.7s". That figure was the whole transfer, including a
   30 s wait for the elevated helper, not a guest copy time.

The real payload's own record was then never polled, which left a new trap of
the same kind for whichever process got that pid next.

## The defences (Windows driver)

All three are in `modules/win/exec.ps1`, under "qemu-ga's exec records", except
the last.

1. **A ledger, reaped before every exec.** Every call this host may leave a
   record for is written down as an empty file `images/VM.exec/<guest
   pid>.<owner>`. The owner is the host process polling it, or `0` for a
   detached call. The entry is removed once the record has been consumed, never
   in a `finally`, because an abandoned record is exactly what it is for. Each
   `Invoke-GuestExec` first polls every entry whose owner is gone (or is this
   process, which is single-threaded and so not mid-poll). A finished record is
   dropped by that poll, and so is its entry. A process still running keeps its
   entry.
2. **A per-call nonce.** The `ps` and `sh` wrappers print `virutil-call <32
   hex>` as their first line. A finished answer without it is either an older
   record for the same pid, which that answer has just removed, or this call's
   own process having died before its wrapper printed anything. One more status
   call tells the two apart: if no record is left, the answer was ours.
   Otherwise the poll goes on against the record that is now first. The nonce is
   stripped before the output reaches anyone. `cmd` has no nonce: `cmd.exe /c`
   cannot carry one through qemu-ga's quoting reliably.
3. **`exec ps -d` leaves no record at all.** It runs a small launcher as an
   ordinary captured call, polled to its end. The launcher reads the encoded
   script from stdin and starts it with `UseShellExecute`. ShellExecuteEx passes
   no inherited handles, so the child does not hold the launcher's stdout and
   stderr pipes open (qemu-ga waits for both to close before it reports a
   process exited). The child runs as SYSTEM with the agent's environment, as a
   detached guest-exec did, and its pid is what `-d` prints. Measured on a
   Windows 11 host, with the launcher started under redirected pipes as qemu-ga
   starts it: stdout closed after 0.8 s while the child ran on for 15 s and
   finished its work. stdin is the launcher's channel for the script, so `ps -d`
   with stdin is refused. `cmd -d` stays a plain detached guest-exec, because XP
   has no PowerShell for a launcher. `sh -d` stays one too, because Linux hands
   out pids in sequence up to `pid_max` and reuses them far more slowly. The
   ledger reaps both.
4. **The transports fail closed** (`Assert-XferReported`, `modules/win/xfer.ps1`).
   A sync, push or pull whose guest line is missing or not the expected numbers
   stops with "guest copier sent no result; delivery unverified" (exit 1), after
   its normal teardown. It no longer reports "all already current", "all up to
   date" or "0 files".

## The bash driver

`modules/linux/exec` and `modules/mac/exec` (`gexec`, under "qemu-ga's exec
records") have the same defences, and `xfer_reported` in `modules/linux/xfer`
is `Assert-XferReported`. Windows guests driven from a Linux or macOS host
reuse pids as quickly as on RNDLB; Linux guests hand them out in sequence up to
`pid_max`, so the risk there is real but much lower. Where they differ:

- The ledger is `$VIRUTILS_IMAGE_DIR/VM.exec/<guest pid>.<owner>`, and the
  owner is the run's `$$`, which every `$(...)` inside it shares. Owner-alive
  is `kill -0`, with `ps -p` behind it so another user's live process is not
  read as gone.
- An unknown pid reads as "no record left" in both drivers whether the agent
  says "PID N does not exist" or the generic "Invalid parameter 'pid'"
  (QERR_INVALID_PARAMETER). Measured 2026-11-11: virtio-win's qemu-ga 110.2.3
  (RNDLB win11, win11-2, win11-3) says "PID lld does not exist", Ubuntu 24.04's
  8.2.2 (LE11 qv-r14u) "PID ld does not exist" -- the format string carries no
  argument -- and the 7.6.2 an XP guest runs (LE11 winxp) "Invalid parameter
  'pid'".
- A status with neither `exitcode` nor `signal` is exit 1 with a warning, not
  0. A signal is 128 + the signal, as on Windows.

## What is left

- A reaper can still consume a record that a live caller on *another host* is
  about to read, if that caller's pid was reused. Each domain is driven from one
  host, so this needs two hosts sharing a guest's agent, which virutil does not
  do.
- `exec cmd` output is still unverified, as described in (2).
