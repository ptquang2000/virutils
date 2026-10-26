#!/usr/bin/env bash
# tests/linux/shot.sh -- modules/linux/shot with virsh substituted.
#
# A stub `virsh` goes first on PATH and answers the two calls shot makes:
# `domstate VM`, and `screenshot VM --file F`, which writes a PNG or a PPM as
# the test asks -- the two formats libvirt hands back depending on what it and
# qemu support. What is asserted:
#
#   * the grammar and its exit codes, which are contract;
#   * an unknown domain and a shut-off one are refused by name;
#   * a PNG passes through untouched, and a PPM arrives as a PNG with its
#     pixels intact (that half needs python3, and skips without it);
#   * a failed capture leaves an existing -o file alone, and no scratch file is
#     left either way;
#   * with no -o the file is VM-YYYYMMDD-HHMMSS.png in the current directory.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0 FAIL=0 SKIP=0
ok()   { printf 'ok       %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL     %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
skip() { printf 'skip     %s\n' "$1"; SKIP=$((SKIP + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi; }

if [[ "$(uname -s)" == Darwin ]]; then
    skip 'modules/linux/shot is not the tree a Mac runs'
    printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
export VIRUTILS_DIR="$WORK/root"
mkdir -p "$WORK/bin" "$WORK/out"

# STUB_STATE is what domstate prints ("" for no such domain); STUB_FORMAT is
# png, ppm or fail.
cat > "$WORK/bin/virsh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --connect ]] && shift 2
case "$1" in
    domstate)
        [[ -n "${STUB_STATE:-}" ]] || { echo "error: failed to get domain '$2'" >&2; exit 1; }
        printf '%s\n\n' "$STUB_STATE" ;;
    screenshot)
        file="$4"
        case "${STUB_FORMAT:-png}" in
            png)  printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\x02\x80\0\0\x01\xe0\x08\x02\0\0\0' > "$file" ;;
            ppm)  { printf 'P6\n# stub\n3 2\n255\n'
                    printf '\xff\0\0\0\xff\0\0\0\xff\x0a\x14\x1e\x28\x32\x3c\x46\x50\x5a'; } > "$file" ;;
            fail) echo "error: screenshot failed" >&2; exit 1 ;;
        esac
        echo "Screenshot saved to $file" ;;
esac
STUB
chmod +x "$WORK/bin/virsh"
export PATH="$WORK/bin:$PATH"

shot() { bash "$ROOT/virutil" shot "$@"; }
code() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
scratch() { find "$VIRUTILS_DIR/tmp" -name 'shot-*' 2>/dev/null | wc -l | tr -d ' '; }

export STUB_STATE=running STUB_FORMAT=png

check 'shot -h exits 0'              0 "$(code shot -h)"
check 'shot with no VM exits 1'      1 "$(code shot)"
check 'a second VM exits 1'          1 "$(code shot a b)"
check '-o with no value exits 1'     1 "$(code shot a -o)"
check 'an unknown flag exits 1'      1 "$(code shot a --nope)"

out="$(STUB_STATE='' shot nosuch 2>&1)"
[[ "$out" == *'no such VM: nosuch'* ]] && ok 'an unknown domain is named' || bad 'an unknown domain is named' "$out"
out="$(STUB_STATE='shut off' shot vm 2>&1)"
[[ "$out" == *'vm is not running'* ]] && ok 'a shut-off domain is refused' || bad 'a shut-off domain is refused' "$out"

out="$(shot vm -o "$WORK/out/a b.png" 2>/dev/null)"
check 'a PNG shot prints its path'   "$WORK/out/a b.png" "$out"
check '  and is the PNG virsh gave'  89504e47 "$(od -An -tx1 -N4 -- "$WORK/out/a b.png" | tr -d ' \n')"
err="$(shot vm -o "$WORK/out/a b.png" 2>&1 >/dev/null)"
check '  and says its size'          'vm: 640x480' "$err"

printf 'old' > "$WORK/out/keep.png"
check 'a failed capture exits 1'     1 "$(STUB_FORMAT=fail code shot vm -o "$WORK/out/keep.png")"
check '  and leaves -o alone'        old "$(cat "$WORK/out/keep.png")"

if command -v python3 >/dev/null; then
    out="$(STUB_FORMAT=ppm shot vm -o "$WORK/out/ppm.png" 2>/dev/null)"
    check 'a PPM arrives as a PNG'   "$WORK/out/ppm.png" "$out"
    pixels="$(python3 - "$WORK/out/ppm.png" <<'PY'
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n'
w, h = struct.unpack('>II', d[16:24])
pos, idat = 8, b''
while pos < len(d):
    n, = struct.unpack('>I', d[pos:pos + 4]); kind = d[pos + 4:pos + 8]
    if kind == b'IDAT': idat += d[pos + 8:pos + 8 + n]
    pos += 12 + n
raw = zlib.decompress(idat)
px = lambda x, y: ','.join(str(b) for b in raw[y * (w * 3 + 1) + 1 + x * 3:][:3])
print(f'{w}x{h} {px(0, 0)} {px(2, 0)} {px(1, 1)}')
PY
)"
    check '  3x2, pixels intact'     '3x2 255,0,0 0,0,255 40,50,60' "$pixels"
else
    skip 'a PPM arrives as a PNG -- no python3 here'
fi

( cd "$WORK/out" && shot vm >/dev/null 2>&1 )
named="$(cd "$WORK/out" && ls vm-*.png 2>/dev/null)"
[[ "$named" =~ ^vm-[0-9]{8}-[0-9]{6}\.png$ ]] && ok 'with no -o: VM-YYYYMMDD-HHMMSS.png here' \
    || bad 'with no -o: VM-YYYYMMDD-HHMMSS.png here' "$named"

check 'no scratch file is left'      0 "$(scratch)"

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
