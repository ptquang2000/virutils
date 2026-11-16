#!/usr/bin/env python3
"""vnc.py -- a tart domain's screen and input, over the VNC server tart starts
with `tart run --vnc-experimental` (Virtualization.framework's own).

    vnc.py size               print "WxH"
    vnc.py shot FILE          write the frame to FILE as PNG, print "WxH"
    vnc.py input              send the events on stdin, one per line:
                                move X Y
                                button NAME down|up    left right middle
                                                       wheel-up wheel-down
                                key QCODE... HOLD_MS   press in order, hold,
                                                       release in reverse
                                wait MS

The server is named in the environment, never on the command line, where the
password would be in every `ps`:

    VIRUTIL_VNC_HOST  VIRUTIL_VNC_PORT  VIRUTIL_VNC_PASSWORD

VIRUTIL_VNC_KEYS says which modifier row the guest has: `mac` (the default) or
`pc`; see "keys" below.

Standard library only. modules/mac/tart-screen is the one caller; it has
already refused everything that can be refused without the guest.

Exit 0, or 1 with one line on stderr saying what the server did.
"""
import os
import socket
import struct
import sys
import time
import zlib


def die(msg):
    sys.stderr.write("vnc: " + msg + "\n")
    sys.exit(1)


# --- DES, for VNC authentication ---------------------------------------------
#
# VNC authentication (RFB security type 2) is one DES-ECB encryption of a
# 16-byte challenge, keyed with the password's first 8 bytes, each with its bits
# reversed. Python's standard library has no DES, so it is here: the tables are
# FIPS 46-3's, and tests/mac/vnc.sh holds the whole thing to the published
# vectors.

_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
       62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
       57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
       61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
_FP = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
       38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
       36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
       34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25]
_E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13,
      12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25,
      24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
      2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
        10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
        14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10,
        23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48,
        44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
_S = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
     0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
     4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
     15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
     3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
     0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
     13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
     13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
     13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
     1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
     13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
     10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
     3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
     14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
     4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
     11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
     10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
     9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
     4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
     13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
     1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
     6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
     1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
     7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
     2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
]


def _permute(value, table, width):
    out = 0
    for pos in table:
        out = (out << 1) | ((value >> (width - pos)) & 1)
    return out


def des_encrypt_block(key, block):
    """One 8-byte block under one 8-byte key, as bytes."""
    k = _permute(int.from_bytes(key, "big"), _PC1, 64)
    c, d = k >> 28, k & 0xFFFFFFF
    subkeys = []
    for s in _SHIFTS:
        c = ((c << s) | (c >> (28 - s))) & 0xFFFFFFF
        d = ((d << s) | (d >> (28 - s))) & 0xFFFFFFF
        subkeys.append(_permute((c << 28) | d, _PC2, 56))
    v = _permute(int.from_bytes(block, "big"), _IP, 64)
    left, right = v >> 32, v & 0xFFFFFFFF
    for sk in subkeys:
        x = _permute(right, _E, 32) ^ sk
        f = 0
        for i in range(8):
            six = (x >> (42 - 6 * i)) & 0x3F
            row = ((six >> 4) & 2) | (six & 1)
            f = (f << 4) | _S[i][row * 16 + ((six >> 1) & 0xF)]
        left, right = right, left ^ _permute(f, _P, 32)
    return _permute((right << 32) | left, _FP, 64).to_bytes(8, "big")


def vnc_response(password, challenge):
    """The 16-byte answer to a VNC authentication challenge."""
    key = (password.encode("latin-1", "replace") + b"\0" * 8)[:8]
    key = bytes(int("{:08b}".format(b)[::-1], 2) for b in key)
    return des_encrypt_block(key, challenge[:8]) + des_encrypt_block(key, challenge[8:16])


# --- RFB ---------------------------------------------------------------------

class Rfb:
    def __init__(self, host, port, password, timeout=10.0):
        try:
            self.sock = socket.create_connection((host, port), timeout=timeout)
        except OSError as e:
            die("could not connect to %s:%s: %s" % (host, port, e))
        self.sock.settimeout(timeout)
        self.x = self.y = 0
        self.mask = 0
        self._handshake(password)

    def recv(self, n):
        buf = bytearray()
        while len(buf) < n:
            try:
                chunk = self.sock.recv(min(n - len(buf), 1 << 20))
            except socket.timeout:
                die("the VNC server stopped answering (wanted %d bytes, got %d)" % (n, len(buf)))
            except OSError as e:
                die("the VNC connection failed: %s" % e)
            if not chunk:
                die("the VNC server closed the connection")
            buf += chunk
        return bytes(buf)

    def send(self, data):
        try:
            self.sock.sendall(data)
        except OSError as e:
            die("the VNC connection failed: %s" % e)

    def _reason(self):
        (n,) = struct.unpack(">I", self.recv(4))
        return self.recv(min(n, 4096)).decode("utf-8", "replace")

    def _handshake(self, password):
        banner = self.recv(12)
        if not banner.startswith(b"RFB "):
            die("that is not a VNC server: it opened with %r" % banner)
        try:
            major, minor = int(banner[4:7]), int(banner[8:11])
        except ValueError:
            die("unreadable RFB version %r" % banner)
        # 3.8's handshake for anything that says 3.8 or later (Apple says
        # 003.889), 3.3's for the rest.
        new = (major, minor) >= (3, 7)
        self.send(b"RFB 003.008\n" if new else b"RFB 003.003\n")
        if new:
            (count,) = struct.unpack("B", self.recv(1))
            if count == 0:
                die("the VNC server refused the connection: " + self._reason())
            offered = list(self.recv(count))
            if 1 in offered:
                chosen = 1
            elif 2 in offered:
                chosen = 2
            else:
                die("the VNC server offers security types %s and this client "
                    "speaks None (1) and VNC authentication (2)" % offered)
            self.send(bytes([chosen]))
        else:
            (chosen,) = struct.unpack(">I", self.recv(4))
            if chosen == 0:
                die("the VNC server refused the connection: " + self._reason())
            if chosen not in (1, 2):
                die("the VNC server wants security type %d" % chosen)
        if chosen == 2:
            self.send(vnc_response(password, self.recv(16)))
        if chosen == 2 or new:
            (result,) = struct.unpack(">I", self.recv(4))
            if result != 0:
                why = ""
                if new:
                    try:
                        why = ": " + self._reason()
                    except SystemExit:
                        why = ""
                die("the VNC server refused the password" + why)
        self.send(b"\x01")  # shared: leave any other viewer connected
        self.width, self.height = struct.unpack(">HH", self.recv(4))
        self.recv(16)
        (n,) = struct.unpack(">I", self.recv(4))
        self.name = self.recv(n).decode("utf-8", "replace")
        # 32 bits per pixel, little-endian, blue in the low byte: B G R x.
        self.send(struct.pack(">BxxxBBBBHHHBBBxxx", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
        # Raw only, plus DesktopSize so a resize is announced, not garbled.
        self.send(struct.pack(">BxHii", 2, 2, 0, -223))

    def frame(self, timeout=15.0):
        """The whole screen as (width, height, rows of RGB bytes)."""
        w, h = self.width, self.height
        fb = bytearray(w * h * 4)
        seen = bytearray(h)  # a row is done once a rectangle has covered it
        self.send(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
        deadline = time.time() + timeout
        while not all(seen):
            if time.time() > deadline:
                die("the VNC server sent only part of a %dx%d frame in %ds" % (w, h, timeout))
            (kind,) = struct.unpack("B", self.recv(1))
            if kind == 0:
                _, nrects = struct.unpack(">BH", self.recv(3))
                for _ in range(nrects):
                    rx, ry, rw, rh, enc = struct.unpack(">HHHHi", self.recv(12))
                    if enc == -223:
                        # The guest changed resolution under us: start again
                        # at the new size.
                        self.width, self.height = rw, rh
                        return self.frame(timeout)
                    if enc != 0:
                        die("the VNC server sent encoding %d, and only raw was asked for" % enc)
                    data = self.recv(rw * rh * 4)
                    if rx + rw > w or ry + rh > h:
                        continue
                    for row in range(rh):
                        at = ((ry + row) * w + rx) * 4
                        fb[at:at + rw * 4] = data[row * rw * 4:(row + 1) * rw * 4]
                    if rx == 0 and rw == w:
                        for row in range(ry, ry + rh):
                            seen[row] = 1
                if not all(seen):
                    self.send(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
            elif kind == 1:
                _, _, ncol = struct.unpack(">BHH", self.recv(5))
                self.recv(ncol * 6)
            elif kind == 2:
                pass
            elif kind == 3:
                (n,) = struct.unpack(">xxxI", self.recv(7))
                self.recv(n)
            else:
                die("the VNC server sent message type %d, which this client does not know" % kind)
        rows = []
        for row in range(h):
            px = fb[row * w * 4:(row + 1) * w * 4]
            rgb = bytearray(w * 3)
            rgb[0::3] = px[2::4]
            rgb[1::3] = px[1::4]
            rgb[2::3] = px[0::4]
            rows.append(bytes(rgb))
        return w, h, rows

    def pointer(self):
        self.send(struct.pack(">BBHH", 5, self.mask, self.x, self.y))

    def key(self, sym, down):
        self.send(struct.pack(">BBxxI", 4, 1 if down else 0, sym))


def write_png(path, w, h, rows):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    raw = b"".join(b"\x00" + r for r in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


# --- keys ----------------------------------------------------------------------
#
# modules/mac/input names keys by qemu's qcodes, because that is what the QEMU
# half sends. RFB carries X11 keysyms, so the same names are translated here.
#
# Virtualization.framework's server reads a keysym as a *key*, not a character:
# measured against a macOS 27 guest, `A`, `!` and `_` sent with no Shift held
# typed "a1-", and `a`, `1`, `-` sent with Shift held typed "A!_". So a combo
# is sent as its plain keys with the modifiers held, which is what a qcode
# means anyway.
#
# The modifier row is Apple's VNC convention, measured the same way: Alt_L and
# Alt_R are Command (Alt+Q quit an app), Meta_L and Meta_R are Option (Meta+P
# typed a pi), and Super and Hyper do nothing. So for a macOS guest `alt` is
# sent as Meta and `meta_l` (win, cmd, super) as Alt. A Linux guest gets the
# PC row -- Alt is Alt, win is Super -- which is unmeasured: no Linux tart
# guest has been driven yet.

KEYSYMS = {
    "shift": 0xFFE1, "shift_r": 0xFFE2, "ctrl": 0xFFE3, "ctrl_r": 0xFFE4,
    "caps_lock": 0xFFE5, "alt": 0xFFE7, "alt_r": 0xFFE8,
    "meta_l": 0xFFE9, "meta_r": 0xFFEA, "compose": 0xFF67, "menu": 0xFF67,
    "esc": 0xFF1B, "backspace": 0xFF08, "tab": 0xFF09, "ret": 0xFF0D,
    "spc": 0x20, "delete": 0xFFFF, "insert": 0xFF63, "home": 0xFF50,
    "end": 0xFF57, "pgup": 0xFF55, "pgdn": 0xFF56, "left": 0xFF51,
    "up": 0xFF52, "right": 0xFF53, "down": 0xFF54, "print": 0xFF61,
    "pause": 0xFF13, "num_lock": 0xFF7F, "scroll_lock": 0xFF14,
    "minus": 0x2D, "equal": 0x3D, "bracket_left": 0x5B, "bracket_right": 0x5D,
    "backslash": 0x5C, "semicolon": 0x3B, "apostrophe": 0x27,
    "grave_accent": 0x60, "comma": 0x2C, "dot": 0x2E, "slash": 0x2F,
    "asterisk": 0x2A, "less": 0x3C,
    "kp_0": 0xFFB0, "kp_1": 0xFFB1, "kp_2": 0xFFB2, "kp_3": 0xFFB3,
    "kp_4": 0xFFB4, "kp_5": 0xFFB5, "kp_6": 0xFFB6, "kp_7": 0xFFB7,
    "kp_8": 0xFFB8, "kp_9": 0xFFB9, "kp_enter": 0xFF8D, "kp_add": 0xFFAB,
    "kp_subtract": 0xFFAD, "kp_multiply": 0xFFAA, "kp_divide": 0xFFAF,
    "kp_decimal": 0xFFAE, "kp_equals": 0xFFBD,
}
for _i in range(26):
    KEYSYMS[chr(0x61 + _i)] = 0x61 + _i
for _i in range(10):
    KEYSYMS[str(_i)] = 0x30 + _i
for _i in range(1, 25):
    KEYSYMS["f%d" % _i] = 0xFFBD + _i

PC_MODIFIERS = {"alt": 0xFFE9, "alt_r": 0xFFEA, "meta_l": 0xFFEB, "meta_r": 0xFFEC}

BUTTONS = {"left": 1, "middle": 2, "right": 4, "wheel-up": 8, "wheel-down": 16}


def keysyms_for(names, pc):
    """The keysym to send for each key of a combo, in order."""
    out = []
    for n in names:
        if n not in KEYSYMS:
            die("no VNC key for '%s'" % n)
        out.append(PC_MODIFIERS.get(n, KEYSYMS[n]) if pc else KEYSYMS[n])
    return out


def run_input(rfb, lines, pc):
    for line in lines:
        words = line.split()
        if not words:
            continue
        verb = words[0]
        if verb == "move" and len(words) == 3:
            rfb.x, rfb.y = int(words[1]), int(words[2])
            rfb.pointer()
        elif verb == "button" and len(words) == 3 and words[1] in BUTTONS:
            bit = BUTTONS[words[1]]
            rfb.mask = (rfb.mask | bit) if words[2] == "down" else (rfb.mask & ~bit)
            rfb.pointer()
        elif verb == "key" and len(words) >= 3:
            names, hold = words[1:-1], int(words[-1])
            syms = keysyms_for(names, pc)
            for s in syms:
                rfb.key(s, True)
                time.sleep(0.01)
            time.sleep(hold / 1000.0)
            for s in reversed(syms):
                rfb.key(s, False)
                time.sleep(0.01)
        elif verb == "wait" and len(words) == 2:
            time.sleep(int(words[1]) / 1000.0)
        else:
            die("unreadable input event: %r" % line)
    # The server reads events off the socket in its own time; closing at once
    # has been seen to drop the tail of a burst.
    time.sleep(0.15)


def main(argv):
    if len(argv) >= 2 and argv[1] == "des-selftest":
        # tests/mac/vnc.sh: KEY BLOCK in hex -> the ciphertext in hex.
        print(des_encrypt_block(bytes.fromhex(argv[2]), bytes.fromhex(argv[3])).hex())
        return 0
    if len(argv) < 2 or argv[1] not in ("size", "shot", "input"):
        sys.stderr.write(__doc__)
        return 1
    host = os.environ.get("VIRUTIL_VNC_HOST", "127.0.0.1")
    port = os.environ.get("VIRUTIL_VNC_PORT", "")
    if not port.isdigit():
        die("VIRUTIL_VNC_PORT is not set")
    rfb = Rfb(host, int(port), os.environ.get("VIRUTIL_VNC_PASSWORD", ""))
    if argv[1] == "size":
        print("%dx%d" % (rfb.width, rfb.height))
    elif argv[1] == "shot":
        if len(argv) != 3:
            die("shot wants one FILE")
        w, h, rows = rfb.frame()
        write_png(argv[2], w, h, rows)
        print("%dx%d" % (w, h))
    else:
        run_input(rfb, sys.stdin.read().splitlines(),
                  os.environ.get("VIRUTIL_VNC_KEYS", "mac") == "pc")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
