# The guest agent with several host clients at once

`exec`, `push`, `pull`, `ui` and `sync` all reach the guest through the one
qemu-ga channel, the virtio-serial port `org.qemu.guest_agent.0`. When two
virutil sessions use one VM at the same time, one of them times out, or reads
the other's reply. The UAT session saw an agent call time out exactly while
another session ran a transfer test. This note records why that happens, the
options, and what virutil should do. Read it before you change how
`modules/*/guest*` open the agent.

Sources: QEMU **v11.1.0** and libvirt **v12.8.0**, read at those tags. Line
numbers below refer to them. Also the virtio v1.3 spec and Linux v6.12
`drivers/char/virtio_console.c`. Measurements were taken on this Windows host
(QEMU v11.1.0-12130, WHPX) against a throwaway qemu: the winxp disk under
`-snapshot`, running qemu-ga 7.6.2 on isa-serial. win11 was not touched. The
mailing-list archive (lore.kernel.org) was behind a bot challenge, so the
commit messages quoted here stand in for the threads.

## Summary

- **The host side serves one client at a time, and that is by design.**
  - A `-chardev socket,server=on` stops calling `accept()` while a client is
    connected. A second `connect()` still succeeds in the kernel and waits in
    the listen backlog, which has room for 1. It gets no reply, and it is served
    the moment the first client leaves.
  - virutil holds its connection for the **whole run**. So a second session
    waits behind the first session's entire `sync` or transfer, gives up after
    2 s, and reports "not answering".
- **The guest side is one byte stream feeding a sequential agent.** If a client
  leaves before its reply arrives, the next client receives that reply first,
  unless it syncs with a unique id. That is the "reads the other's reply"
  symptom.
- **libvirt already solves this on Linux.** It owns the socket, holds a
  per-domain agent job lock around every call, and re-syncs after any timeout.
  The Linux driver needs no change.
- **Recommendation for the Windows and macOS drivers:** a per-VM host lock
  around each agent round trip: connect, `guest-sync-delimited`, one command,
  its reply, close. This is libvirt's model without a daemon, and it needs no
  change in the guest. It is possible only because reconnecting turns out to
  work (measured below), which disproves the claim that made virutil hold the
  channel for the whole run.

## 1. Why the channel is single-client

### 1a. The QEMU socket chardev

- **The listen backlog is 1.**
  - `chardev/char-socket.c` `qmp_chardev_open_socket_server` (L1229) calls
    `qio_net_listener_open_sync(s->listener, s->addr, 1, errp)`.
  - That 1 becomes the backlog of `listen(fd, num)` (`util/qemu-sockets.c`
    L382; `io/net-listener.c` L98-140).
- **Accepting stops once a client is connected.**
  - `tcp_chr_new_client` (L889-933) runs only in state `CONNECTING`. It then
    clears the accept callback with
    `qio_net_listener_set_client_func_full(s->listener, NULL, ...)`.
  - With no callback, `qio_net_listener_watch` returns early (`if
    (!listener->io_func) return;`, `io/net-listener.c` L151). The listening
    socket stays open, but nothing accepts on it.
- **Accepting resumes only on disconnect.** `tcp_chr_disconnect_locked`
  (L460-478) re-arms `tcp_chr_accept`. The queued connection is then picked up,
  together with the bytes it had already sent.
- **The QEMU docs and commits say the same.**
  - `qemu-options.hx` L4878: "Only one TCP connection at a time is accepted."
  - Commit `4a0582f6` (2019) says server sockets "will always accept a new
    client connection immediately after the previous one went away".
- **The socket is read only while the frontend can take data.**
  - `chardev/char-io.c` `io_watch_poll_prepare` (L48) polls the client socket
    only while `fd_can_read() > 0`.
  - With no guest process holding the port open, QEMU never reads the client
    socket, so it never sees that client's EOF.
  - Commit `a8aa6197` (2018, "add POLLHUP handler") fixed this with a separate
    `G_IO_HUP` watch (`char-socket.c` L614-634). It reproduced the bug against
    libvirt's agent socket: "the first one is accepted by QEMU, then two are
    queued by the kernel, and the 4th blocks".
  - **On a Windows host that fix does not apply.** The Win32 socket source in
    `io/channel-watch.c` (about L113-153) only ever reports
    `G_IO_IN/OUT/PRI`, so a HUP-only watch never fires. This comes from reading
    the code, but the measurement below matches it.
- **`mux=on` does not help.** It is one backend shared by up to four QEMU
  *frontends* (`qemu-options.hx` L4141-4150), with input going only to the
  focused one (`chardev/char-mux.c` `mux_set_focus`). It does not give a
  backend several clients.

### 1b. The virtio-serial port

- One port is one pair of virtqueues: one byte stream (virtio v1.3 §5.3).
- The host connection drives `host_connected`. In `hw/char/virtio-console.c`
  `chr_event` (L156-163), `CHR_EVENT_OPENED` calls `virtio_serial_open` and
  `CHR_EVENT_CLOSED` calls `virtio_serial_close`.
- **Guest output with no host client connected is dropped.** See
  `hw/char/virtio-serial-bus.c` `handle_output` (L479-496), `if (!port ||
  !port->host_connected) { discard_vq_data(...) }`, and the discard in
  `virtio_serial_close` (L277-291).
- **Guest output written after the next client connects goes to that client.**
- qemu-ga does not close its channel on a virtio EOF. It sleeps for 100 ms and
  keeps the same JSON parser (`qga/main.c` `channel_event_cb`, L714-749). So a
  dead client's half-sent request can survive into the next client's stream.

### 1c. qemu-ga

- **One channel, synchronous dispatch.** `process_event` (`qga/main.c` L688-711)
  runs `qmp_dispatch` and then `send_response`: no queue and no threads.
  Replies come back strictly in request order, and a slow command blocks
  everything behind it.
- **`"id"` is echoed.** qemu-ga uses the shared QAPI dispatcher. In
  `qapi/qmp-dispatch.c`, L167 reads the id and L301-303 copies it into the
  reply. There are two exceptions:
  - A parse error is answered with no id (`main.c` L696-698).
  - `guest-shutdown` and `guest-suspend-*` send no reply at all
    (`'success-response': false`).
  - So the id makes a reply recognisable. It does not let requests run in
    parallel.
- **`guest-sync-delimited` is the documented resync.** `qga/qapi-schema.json`
  L50-119 says it "must be issued upon initial connection, and after any
  client-side timeouts". Its rules:
  - The request is preceded by 0xFF, which makes the agent drop any partial
    JSON.
  - The reply is preceded by 0xFF (`QGA_SENTINEL_BYTE`, `main.c` L60, L656-685).
  - The client ignores every reply until the one carrying its own id.
  - `docs/interop/qmp-spec.rst` L234-258 adds: "the client may receive output a
    previous client didn't read".
- **Other listening methods are also one client at a time.** `unix-listen` and
  `vsock-listen` accept one connection and stop listening (`/* only accept 1
  connection at a time */`, `qga/channel-posix.c` L54-55).
- **Windows qemu-ga supports only `virtio-serial` and `isa-serial`.** See
  `qga/channel-win32.c` L283-320. It opens the port with share mode 0
  (exclusive), so one guest process per port.
- **State is global within one agent instance, with no notion of an owner:**
  - guest-exec pids (`qga/commands.c` L107-145). The status call that reports
    the exit also frees the entry (L220-221).
  - file handles (`commands-win32.c` L94-180).
  - fsfreeze (`main.c` L138-146, L532-545).
  - virutil only ever polls its own pid, so the first point does no harm today.
    A broker that shares polling between callers would have to cache results.

## 2. How libvirt does it

The agent code is now `src/hypervisor/qemu_agent.c`. It used to be
`src/qemu/qemu_agent.c`.

- **libvirt is the client of a QEMU-listening UNIX socket.**
  - The XML is `<channel type='unix'>` with target `org.qemu.guest_agent.0`
    (`docs/formatdomain.rst`).
  - `qemuAgentOpen` (L594-661) accepts only UNIX sockets and `connect()`s to
    them.
  - libvirt connects when QEMU reports through `VSERPORT_CHANGE` that the
    guest has opened the port, and drops the connection when the guest closes
    it (`qemu_driver.c` `processSerialChangedEvent`, L4063-4132;
    `qemu_process.c` `qemuConnectAgent`, L212-268).
  - While libvirt holds the connection, no other process can reach the agent
    (§1a).
- **Every agent call takes an agent job, which is the lock.**
  - `qemuDomainQemuAgentCommand` (`qemu_driver.c` L16597-16640), the call
    behind `virsh qemu-agent-command`, wraps the call in
    `virDomainObjBeginAgentJob(vm, VIR_AGENT_JOB_MODIFY)` and
    `virDomainObjEndAgentJob`.
  - `virDomainObjCanSetJob` (`src/conf/virdomainjob.c` L264-273) allows one
    agent job at a time. A waiter gives up after `VIR_JOB_WAIT_TIME`, 30 s,
    with "cannot acquire state change lock (held by agent=…)".
  - libvirt's own agent APIs (`guestinfo`, `set-user-password`, …) take the
    same job.
- **libvirt syncs before a command whenever it is not known to be in sync.**
  - `qemuAgentGuestSync` (L869-917) sends plain `guest-sync`, with no 0xFF and
    a millisecond-timestamp id (`qemuAgentGuestSyncSend`, L817-854).
  - `qemuAgentIOProcessLine` (L216-278) discards non-matching replies ("Guest
    agent returned ID … instead of …", "Ignoring delayed reply").
  - This is enough because the stream is FIFO: every stale reply arrives
    before the sync reply.
- **Timeouts.**
  - The default is 5 s (`QEMU_AGENT_WAIT_TIME`, L714). `-2` blocks and `0`
    returns immediately. `virsh qemu-agent-command --timeout/--block/--async`
    choose between them.
  - On a timeout libvirt sets `agent->inSync = false` (L783), so the next call
    re-syncs. It does **not** reconnect.
- **The command is officially unsupported.** `qemu-agent-command` taints the
  domain with `custom-ga-command` (`qemuDomainObjTaint(...,
  VIR_DOMAIN_TAINT_CUSTOM_GA_COMMAND)`). The libvirt-qemu pass-through APIs are
  documented as "unsupported" (`docs/drvqemu.rst` L546-560). That is the cost
  of the Linux driver's design, not a multi-client problem.

## 3. Measured on this host

All measurements used throwaway qemus with the probe in the session
scratchpad, on QEMU 11.1 under WHPX:

- a winxp `-snapshot` guest with qemu-ga 7.6.2 on COM1, and a second chardev
  on COM2;
- a guestless `-S` q35 with a `virtserialport` nobody opens.

| # | What was done | What happened |
|---|---|---|
| 1 | A connected and synced; B connected | B's `connect` **succeeded**. B's sync got no reply in 5 s. A kept working. |
| 2 | C connected while A held and B waited | **Refused** ("actively refused") in one run. In a 3-thread run, the third client was queued instead. Winsock decides, not QEMU. |
| 3 | A closed | QEMU accepted B within **50 ms** and answered the sync B had sent seconds earlier. |
| 4 | A sent 40 `guest-info` and left without reading; B, queued, sent `guest-get-osinfo` | B's first reads were **23 of A's replies**. B's own reply was still queued behind them after 6 s (isa-serial runs at about 9 KB/s). |
| 5 | 50 sequential connect → `guest-sync-delimited` → close cycles | **50/50 ok**, 1.7 s total, about **35 ms each**. |
| 6 | 3 threads at once, each connecting, syncing, holding 2 s and closing | All synced, at 0.1 s, 2.1 s and 4.1 s: served one after another. |
| 7 | Guestless qemu, 6 connect/close cycles | conn 1-2 ok, **3-6 refused**. |
| 8 | A second qemu-ga run in the guest with `-m isa-serial -p COM2 -f … -t …` | It ran alongside the service. 20 interleaved requests on each port all came back. Asking about A's guest-exec pid on the COM2 agent gave "Invalid parameter 'pid'": pids are per instance. |
| 9 | HMP `chardev-add socket,…,port=24874` + `device_add virtio-serial-pci` + `device_add virtserialport,…,name=org.qemu.guest_agent.1` | The port was listening, and `info qtree` showed the new port as "guest off, host on". Whether the guest picks up a hot-added port was not tested (XP has no virtio). |

What these show:

- **Rows 1, 3 and 6:** the socket queues. It does not lock anyone out.
- **Row 4:** the stale-reply problem is real, and the sync fixes it.
- **Row 5 disproves the rationale in `modules/win/guest.ps1` L89-106.** That
  comment says a `socket` chardev "accepts two and then refuses", and
  `modules/mac/guest` L13-16 repeats it. With a guest agent present,
  reconnecting works indefinitely.
- **Row 7 is that original probe, reproduced, and §1a explains it.** With no
  guest reading the port, QEMU never reads client 1's socket, never sees its
  EOF, and on Windows no HUP watch fires either. The one accept slot and the
  backlog stay full.
  - **Inference, not measured:** this should clear once a guest agent opens the
    port and the read path resumes.
  - Either way, a client should not open and drop connections in a loop while
    the agent is down. `Test-GuestAgent` already retries over one held
    connection, and the new design must keep that.

## 4. The options

| Option | Concurrency | Guest change | Windows/WHPX | Linux libvirt | macOS hvf | Verdict |
|---|---|---|---|---|---|---|
| **A. Per-VM host lock around each round trip** (connect, sync, command, close) | Serialised per command; sessions interleave | none | yes | not needed | yes | **Recommended** |
| B. Host broker daemon that owns the socket and serialises or id-tags requests | Serialised per command | none | yes | libvirt already is one | yes | Same result as A, plus a daemon to start, find, upgrade and clean up |
| C. Extra virtserialport + a second qemu-ga per port | Truly parallel, one port per session | a second agent instance and a launcher change | yes (measured on isa-serial) | yes; a hot-attached channel stays unmanaged by libvirt | yes | Only if parallel guest work becomes a need |
| D. qemu-ga over vsock | — | Linux guests only | **no**: vhost is Linux-only, and Windows qemu-ga rejects `vsock-listen` | Linux guests only | no | Rejected |
| E. `-chardev hub` (QEMU ≥ 10.0), 4 sockets into one port | Clients connected at once, but writes interleave | none | yes | n/a | yes | Rejected |
| F. `mux=on`, `chardev-change` | none | — | — | — | — | Do not apply |
| G. Do nothing; retry the connect | Queues by accident | none | partly | — | partly | Rejected |

**A. A per-VM host lock around each round trip.** libvirt's agent job, done
with a lock file.

- Because the hold is now one command (tens of milliseconds), sessions
  interleave at command granularity, as they do under libvirt.
  - `exec`'s `guest-exec-status` poll backs off to 1 s, so another session's
    calls fit between polls.
  - A whole `sync` no longer blocks other sessions.
- Costs:
  - One connect plus sync per call: 35 ms on isa-serial, less on virtio.
  - A lock file per VM.
  - A wait message that names the holder.
- The lock also gives a clear error ("waiting for virutil pid N, `sync win11`")
  where today there is a misleading "not answering".

**B. A host broker daemon.** Same result as A, plus a daemon to start, find,
upgrade and clean up.

- It would also have to handle replies that never come (`guest-shutdown`) and
  shared `guest-exec-status` consumption (§1c).
- It wins only if virutil ever needs many commands in flight from many
  sessions, and qemu-ga runs them one at a time anyway (§1c).

**C. A second virtserialport with its own qemu-ga.** The only option with real
parallelism, and it costs a lot:

- a second agent instance in every guest, with its own `-p/-f/-t`;
- a second Windows *service* is unverified, because `-s install` always
  creates the service named `qemu-ga` (`qga/service-win32.h`). A hand-made
  `sc create` under another name may or may not dispatch;
- fsfreeze is not coordinated between instances (`main.c` L138-146);
- a launcher change for every domain;
- each port is still single-client, so it helps only with one port per
  concurrent session.

**D. qemu-ga over vsock.** Not available where it matters.

- `vhost-vsock` needs `VHOST_KERNEL`, which is Linux-only (`meson.build`
  L234-236), and QEMU has no non-vhost virtio-vsock device.
- Windows qemu-ga rejects `vsock-listen` (`channel-win32.c` L290-293).
- It is one client at a time anyway (`channel-posix.c` L239).

**E. `-chardev hub`.** Output is broadcast to every client, and the slowest
reader throttles everyone.

- Input is forwarded raw, so two clients' JSON can interleave (`char-hub.c`
  L39-47, L96-104).
- One client's 0xFF resets the parser for all.
- It still needs a lock to be safe.

**F. `mux=on` and `chardev-change`.** `mux` is N frontends on one backend
(§1a). `chardev-change` swaps a backend and adds no clients.

**G. Do nothing; retry the connect.** The backlog does queue a second client,
which is why it works sometimes. But:

- the backlog holds one, and Winsock refuses the next;
- a queued client cannot tell "waiting behind another session" from "agent
  down";
- the current 2 s sync timeout is far shorter than a session's run.

## 5. Per host

- **Windows/WHPX, launcher `.cmd`.** win11's launcher has `-chardev
  "socket,id=qga0,host=127.0.0.1,port=24728,server=on,wait=off"` + `-device
  virtio-serial` + `virtserialport,…,name=org.qemu.guest_agent.0`, and an HMP
  `-monitor tcp:…`.
  - **A works** with no launcher change: the mechanics in rows 3, 5 and 6 are
    exactly what it relies on.
  - C would mean a second `-chardev`/`virtserialport` in the launcher. Row 9
    shows it could even be hot-added over the HMP monitor without a restart,
    on the existing bus (read its name from `info qtree`). The guest-side
    pickup is unverified.
- **Linux, libvirt.** `virsh qemu-agent-command` already runs under the agent
  job and re-syncs, so concurrent sessions serialise per call. Two things to
  know:
  - A caller waits at most 30 s for the job.
  - A plain call times out after 5 s.
  - Neither is a problem at virutil's call sizes. No change is needed. A second
    `--channel unix,target.name=org.qemu.guest_agent.1` would be C, and libvirt
    would treat it as a plain channel.
- **macOS, QEMU/hvf.** The launcher has the same chardev, on a UNIX socket
  (`<VM>.qga`), reached through `nc -U` in `modules/mac/qemu` `chan_open`.
  - It has the same single-client semantics as Windows, plus the POSIX HUP
    watch, so the guestless wedge (row 7) should not be permanent there
    (unverified).
  - **A works.** macOS has no `flock(1)`; see §6 for the lock.
  - QMP (`<VM>.qmp`) is also a single-client socket, and so is the Windows HMP
    monitor. `shot`, `input` and `snapshot` have the same latent collision, and
    the same lock (keyed by channel) covers them.

## 6. Recommendation and design

**Adopt option A on the Windows and macOS drivers. Change nothing on Linux.**

The round trip, per agent call:

1. **Take the per-VM agent lock.**
   - Wait up to `VIRUTIL_AGENT_LOCK_SECS` (default 120). This is separate from
     the reply timeout.
   - While waiting, print once: `waiting for <VM>'s guest agent: held by
     virutil pid N (<command>) since T`.
   - At the limit, die naming the holder.
2. **Connect, then send 0xFF + `guest-sync-delimited` with a random id.**
   Discard input up to the 0xFF and until `return == id`. This is today's
   `Open-GuestAgent` and `agent_open`, unchanged.
3. **Send the command with an `"id"` of its own.** Read lines until one carries
   that id. Discard others, which belt-and-braces the sync. A reply with no id
   is a parse error and is reported as such.
4. **Close the connection, then release the lock.** On a reply timeout, close
   and release, and the next call's sync cleans up after it. libvirt re-syncs
   instead of reconnecting; here the reconnect itself is cheap (row 5).
5. **Exception:** waiting for the agent to come up (`Test-GuestAgent`,
   `guest_agent_wait`) keeps one connection across its retries, as it does now,
   because of row 7. It takes the lock for the duration of the wait.

**The lock:**

- **Windows.**
  - The lock file is `<images>\<VM>.agent.lock`. The holder opens it with
    `[IO.File]::Open(path, OpenOrCreate, ReadWrite, FileShare.Read)` and writes
    `pid command start-time` into it.
  - A second opener gets a sharing violation, so it waits and retries every
    100 ms.
  - The holder info stays readable because the holder shares Read.
  - The OS releases the lock when the process dies, so a crash never leaves a
    stale lock. This also works across elevated and unelevated processes, which
    a `Local\` named mutex would not do reliably.
- **macOS.**
  - bash has no `flock(1)`. Use an fd that bash holds open (`exec
    {fd}>"$IMAGE_DIR/$vm.agent.lock"`) and a child that locks it: `perl
    -MFcntl=:flock -e 'open(F, ">&=", $ARGV[0]) or die; flock(F, LOCK_EX) or
    die' "$fd"`.
  - A flock belongs to the open file description, so it outlives the perl
    child and is released when bash closes the fd or exits.
  - For the bounded wait, use `LOCK_EX|LOCK_NB` in a loop.
  - None of this has been run on a Mac.

**What it changes in `modules/`:**

- **`modules/win/guest.ps1`**
  - `Invoke-GuestAgent` becomes lock → `Open-GuestAgent` → send with id → read
    the matching id → dispose → unlock.
  - `$script:GuestAgentChannels`, `Get-GuestAgentChannel`,
    `Reset-GuestAgentChannel` and the run-scoped hold go away.
    `Close-GuestAgentChannels` stays as a no-op, or `virutil.ps1` stops calling
    it.
  - `Test-GuestAgent` keeps one held connection while it waits.
  - Rewrite the L89-106 comment with §3's rows 5 and 7.
  - New helpers: `Enter-GuestAgentLock` / `Exit-GuestAgentLock`, in a
    `try/finally`.
- **`modules/win/exec.ps1`.** No change. Each `guest-exec` and
  `guest-exec-status` call is one locked round trip, so polls from different
  sessions interleave. `push`, `pull`, `sync`, `ui` and `xfer` reach the agent
  only through `Invoke-GuestPsText` and `Invoke-GuestExec`, so they need no
  change either.
- **`modules/mac/guest` and `modules/mac/qemu`**
  - `agent()` becomes `agent_lock` → `agent_open` → `chan_send` with id →
    `chan_line` until the id matches → `chan_close` → `agent_unlock`.
  - `guest_os` and `guest_agent_wait` follow.
  - Delete the L13-16 "refusing a client" rationale.
  - Optionally, give `qmp_open`/`qmp_close` the same lock under
    `<VM>.qmp.lock`, since QMP is the same kind of socket.
- **`modules/linux/*`.** Nothing. Optionally pass `--timeout` to virsh where a
  single agent call can run past 5 s. None does today: guest-exec returns at
  once.
- **`docs/contract.md`.** Note that agent calls from concurrent sessions are
  serialised per call on every host, and that waiting for the lock is reported,
  not silent.

**What it does not give:** parallel guest work. Two sessions' commands still
run one at a time in qemu-ga, but each command is short: virutil's long work
runs as guest processes that the agent only starts and polls. If real
parallelism is ever needed, option C is the path, and §3 rows 8 and 9 are its
first evidence.

## 7. How to test it

On a throwaway domain, never a leased one. On Windows, boot a disk with
`-snapshot` as §3 did.

1. **No-VM unit test (`tests/win/agent.ps1`, `tests/mac/agent.sh`).** Use a
   fake qemu-ga: a loopback listener that accepts one client at a time, keeps
   backlog 1, answers `guest-sync-delimited` with 0xFF + id, and can be told to
   emit stale replies first. Assert that:
   - the stale replies are discarded and the id matches;
   - a second caller waits on the lock, prints the holder once, and succeeds
     after release;
   - a holder killed mid-call (`Stop-Process`, `kill -9`) frees the lock;
   - a reply with the wrong id is skipped.
2. **Two sessions, one VM.** Run two loops in parallel, each doing 30 `virutil
   exec ps VM "Write-Output $tag-$i"`, plus a third that runs a long `exec`
   (`Start-Sleep 20`). Assert that:
   - every output line carries its own loop's tag and index;
   - nothing times out;
   - the run takes less than the sum of the parts, because polls interleave.
   This is the UAT failure, reproduced; it fails today.
3. **Interrupted run.** Kill a `virutil exec` partway through a big
   `guest-exec-status` reply, then run `virutil exec ping VM` at once. It must
   succeed: the sync drains the dead run's reply (§3 row 4).
4. **Agent down.** With the guest agent service stopped, run two virutil
   commands that wait for the agent (`Test-GuestAgent` / `guest_agent_wait`),
   one after the other, then start the service. A third command must connect
   at once: no wedge from row 7.
5. **Linux.** Run case 2 against a libvirt domain to confirm that the agent job
   already serialises (expected to pass with no change).
