"""hmp.py PORT CMD... -- send each HMP command to a QEMU monitor on 127.0.0.1:PORT, wait for the
next (qemu) prompt, print the reply and the seconds it took (le11-vm-bench snapshot timing).
Runs on the Windows host (WHPX guests) and in WSL (KVM guests)."""
import socket, sys, time

def until_prompt(s):
    buf = b""
    while not buf.endswith(b"(qemu) "):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    return buf.decode(errors="replace")

port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=1800)
until_prompt(s)
for cmd in sys.argv[2:]:
    t = time.time()
    s.sendall(cmd.encode() + b"\n")
    out = until_prompt(s)
    dt = time.time() - t
    lines = [l.strip() for l in out.replace("\r", "").split("\n")]
    lines = [l for l in lines if l and not l.startswith("(qemu)") and l != cmd]
    print("%s | %.2fs | %s" % (cmd, dt, " / ".join(lines)[-300:]))
