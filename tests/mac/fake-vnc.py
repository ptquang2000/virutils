#!/usr/bin/env python3
"""fake-vnc.py -- a stand-in for Virtualization.framework's VNC server, for
tests/mac/tart.sh: RFB 3.8, VNC authentication, one raw frame, and a log of
every pointer and key event it is sent.

    fake-vnc.py PORTFILE LOG PASSWORD WIDTH HEIGHT

Listens on a loopback port it picks and writes to PORTFILE. The frame's pixel
at (x, y) is red = x & 255, green = y & 255, blue = 7. The password check is
done with the client's own DES on purpose: what is under test is the protocol
around it, and the DES is held to published vectors separately.
"""
import importlib.util
import os
import socket
import struct
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("vnc", os.path.join(here, "..", "..", "libexec", "mac", "vnc.py"))
vnc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vnc)

portfile, logpath, password, W, H = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])


def recv(c, n):
    buf = b""
    while len(buf) < n:
        chunk = c.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def serve(c, log):
    c.sendall(b"RFB 003.889\n")
    recv(c, 12)
    c.sendall(bytes([2, 30, 2]))          # Apple's own type first, then VNC auth
    if recv(c, 1) != b"\x02":
        return
    challenge = os.urandom(16)
    c.sendall(challenge)
    if recv(c, 16) != vnc.vnc_response(password, challenge):
        c.sendall(struct.pack(">I", 1) + struct.pack(">I", 3) + b"bad")
        return
    c.sendall(struct.pack(">I", 0))
    recv(c, 1)
    name = b"fake"
    c.sendall(struct.pack(">HH", W, H) + bytes(16) + struct.pack(">I", len(name)) + name)
    while True:
        kind = recv(c, 1)[0]
        if kind == 0:
            recv(c, 19)
        elif kind == 2:
            (n,) = struct.unpack(">xH", recv(c, 3))
            recv(c, 4 * n)
        elif kind == 3:
            recv(c, 9)
            # Two rectangles, top half and bottom half, to hold the client to
            # assembling a frame rather than expecting one.
            half = H // 2
            c.sendall(struct.pack(">BxH", 0, 2))
            for y0, rows in ((0, half), (half, H - half)):
                c.sendall(struct.pack(">HHHHi", 0, y0, W, rows, 0))
                data = bytearray()
                for y in range(y0, y0 + rows):
                    for x in range(W):
                        data += bytes((7, y & 255, x & 255, 0))
                c.sendall(bytes(data))
        elif kind == 4:
            down, sym = struct.unpack(">BxxI", recv(c, 7))
            log.write("key %s 0x%x\n" % ("down" if down else "up", sym))
        elif kind == 5:
            mask, x, y = struct.unpack(">BHH", recv(c, 5))
            log.write("pointer %d %d %d\n" % (mask, x, y))
        else:
            return
        log.flush()


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(4)
with open(portfile, "w") as f:
    f.write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept()
    try:
        with open(logpath, "a") as log:
            serve(c, log)
    except (EOFError, OSError):
        pass
    finally:
        c.close()
