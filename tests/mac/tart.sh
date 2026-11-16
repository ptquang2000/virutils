#!/usr/bin/env bash
# tests/mac/tart.sh -- the macOS driver's tart half, with tart substituted.
#
# What tests/mac/domain.sh is to a QEMU domain, without a guest: `tart` is
# tests/mac/fake-tart.sh, which keeps VMs as directories and runs `tart exec`
# on this host, and the VNC console is tests/mac/fake-vnc.py. So every verb
# runs through the real modules -- the routing between the two kinds of domain,
# the grammar and the refusals, rsync through libexec/mac/tart-rsh, the RFB
# client -- and nothing here needs Virtualization.framework, an image or root.
#
# What it cannot reach is what a real guest and a real tart do with it. That
# half was measured by hand, and docs/contract.md section 7 has the numbers.
#
# Everything happens under a scratch VIRUTILS_DIR and a scratch tart home,
# removed at the end. Skips, loudly, on a host that is not a Mac or lacks
# rsync 3.2.4, jq or python3.
#
#   tests/mac/tart.sh
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
V="$ROOT/virutil"

PASS=0 FAIL=0
ok()  { printf 'ok       %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL     %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'skip     not a macOS host -- modules/mac was not exercised\n'
    exit 0
fi
for t in jq python3 rsync; do
    command -v "$t" >/dev/null || { printf 'skip     no %s on PATH\n' "$t"; exit 0; }
done
RSYNC_HELP="$(rsync --help 2>&1 || true)"
if ! grep -q -- '--old-args' <<<"$RSYNC_HELP"; then
    printf 'skip     rsync on PATH has no --old-args (brew install rsync)\n'
    exit 0
fi

S="$(mktemp -d "${TMPDIR:-/tmp}/vt.XXXXXX")"
S="$(cd "$S" && pwd -P)"
mkdir -p "$S/bin"
ln -s "$HERE/fake-tart.sh" "$S/bin/tart"
export FAKE_TART_HOME="$S/tart" TART_HOME="$S/tart" VIRUTILS_DIR="$S/v" PATH="$S/bin:$PATH"
export FAKE_VNC_PASSWORD='salon-physical-canal-tragic'
unset VIRUTILS_IMAGE_DIR VIRUTIL_IMAGE_DIR VIRUTILS_CONF_DIR VIRUTILS_STAGING_ROOT VIRUTILS_TMP_DIR
IMG="$VIRUTILS_DIR/images"
VNC_PID=""

cleanup() {
    [[ -n "$VNC_PID" ]] && kill "$VNC_PID" 2>/dev/null
    pkill -f "$S/bin/tart" 2>/dev/null
    rm -rf -- "$S"
}
trap cleanup EXIT

# Nothing here hands a guest any stdin, and `exec` reads it when it is not a
# terminal.
exec </dev/null

# run NAME WANT COMMAND... -- the exit code is the assertion; output is kept.
OUT=""
run() {
    local name="$1" want="$2"; shift 2
    local got=0
    OUT="$("$@" 2>&1)" || got=$?
    if [[ "$got" == "$want" ]]; then ok "$name"; else bad "$name" "wanted exit $want, got $got: $(head -3 <<<"$OUT")"; fi
}
# has NAME PATTERN -- the last run's output holds PATTERN (a glob).
has() { if [[ "$OUT" == *$2* ]]; then ok "$1"; else bad "$1" "wanted [*$2*], got [$(head -4 <<<"$OUT")]"; fi; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi; }

# --- the VNC helper's DES, against FIPS 46 and the classic worked example ------
printf '%s\n' '-- vnc.py --'
is 'DES: the worked example'  85e813540f0ab405 "$(python3 "$ROOT/libexec/mac/vnc.py" des-selftest 133457799BBCDFF1 0123456789ABCDEF)"
is 'DES: all-zero key and block' 8ca64de9c1b123a7 "$(python3 "$ROOT/libexec/mac/vnc.py" des-selftest 0000000000000000 0000000000000000)"
is 'DES: all-ones key and block' 7359b2163e4edc58 "$(python3 "$ROOT/libexec/mac/vnc.py" des-selftest FFFFFFFFFFFFFFFF FFFFFFFFFFFFFFFF)"

# --- create, list, start --------------------------------------------------------
printf '%s\n' '-- domain --'
run 'create from a registry image, -N'  0 "$V" domain create mac1 ghcr.io/acme/macos:1 -c 6 -m 4096 -N
has '  says it is a tart domain'        'mac1 (tart, arm64, macos)'
has '  -c and -m reach tart'            'cpu:      6 vcpus'
run 'create: the name is taken'         1 "$V" domain create mac1 ghcr.io/acme/macos:1 -N
run 'create: -p is refused by name'     1 "$V" domain create mac2 ghcr.io/acme/macos:1 -p 2222:22
has '  with the reason'                 'takes no port forward'
run 'create: clone a local tart VM'     0 "$V" domain create mac2 mac1 -N
run 'create: a missing ISO is QEMU'\''s to refuse' 1 "$V" domain create w11 "$S/none.iso" -N
has '  as an install ISO'               'install ISO not found'

# A QEMU launcher beside them: the two kinds in one list, and the QEMU one
# keeping every command it had.
mkdir -p "$IMG"
printf '%s\n' '#!/bin/sh' '# virutil domain: qemu1' > "$IMG/qemu1.sh"
run 'list: both kinds'                  0 "$V" domain list
has '  the QEMU domain'                 ' qemu1                    shut off'
has '  the tart domain'                 ' mac1                     shut off'
run 'a snapshot is not a domain'        0 "$V" domain list
[[ "$OUT" != *@* ]] && ok '  no VM@SNAP in the list' || bad '  no VM@SNAP in the list' "$OUT"

python3 "$HERE/fake-vnc.py" "$S/vnc.port" "$S/vnc.log" "$FAKE_VNC_PASSWORD" 300 200 &
VNC_PID=$!
for _ in $(seq 50); do [[ -s "$S/vnc.port" ]] && break; sleep 0.1; done
export FAKE_VNC_PORT="$(cat "$S/vnc.port")"

run 'start -G'                          0 "$V" domain start mac1 -G
is  '  tart run got the console and no window' '--vnc-experimental --no-graphics mac1' "$(cat "$S/tart/vms/mac1/run-args")"
run 'start again is a no-op'            0 "$V" domain start mac1
has '  and says so'                     'already running'
run 'start -m on a running domain is refused' 1 "$V" domain start mac1 -m 2048
run 'addr'                              0 "$V" domain addr mac1
is  '  prints the address alone'        192.168.64.9 "$OUT"
run 'port is refused by name'           1 "$V" domain port mac1 2222:22
has '  with the reason'                 'takes no port forward'
run 'delete of a running domain is refused' 1 "$V" domain delete mac1

# --- exec ----------------------------------------------------------------------
printf '%s\n' '-- exec --'
run 'exec ping'                         0 "$V" exec ping mac1
is  '  the contract'\''s line'          'mac1: agent up' "$OUT"
run 'exec sh: the guest'\''s exit code is virutil'\''s' 7 "$V" exec sh mac1 'echo hi; exit 7'
is  '  and its output'                  hi "$OUT"
run 'exec sh: set -e ends it at the first failure' 1 "$V" exec sh mac1 'false; echo after'
is  '  nothing after it ran'            '' "$OUT"
is  'exec sh: host stdin is the guest'\''s' ABC "$(echo abc | "$V" exec sh mac1 'tr a-c A-C')"
is  'exec sh -: the script from stdin'  from-stdin "$(echo 'echo from-stdin' | "$V" exec sh mac1 -)"
run 'exec sh -d prints a pid'           0 "$V" exec sh mac1 -d "touch '$S/detached'"
[[ "$OUT" =~ ^[0-9]+$ ]] && ok '  and only a pid' || bad '  and only a pid' "$OUT"
sleep 0.5
[[ -e "$S/detached" ]] && ok '  and the script ran' || bad '  and the script ran'
run 'exec ps is refused by name'        1 "$V" exec ps mac1 'Get-Date'
has '  naming sh'                       'virutil exec sh mac1'
run 'exec cmd is refused by name'       1 "$V" exec cmd mac1 dir
touch "$S/tart/vms/mac1/no-agent"
run 'exec ping with no agent'           1 "$V" exec ping mac1
has '  says which agent'                'tart guest agent is not answering'
rm -f "$S/tart/vms/mac1/no-agent"

# --- ui ------------------------------------------------------------------------
# The guest half needs a console user and launchctl, so only the grammar is
# reachable here.
printf '%s\n' '-- ui --'
run 'ui run -i is refused by name'      1 "$V" ui run mac1 -i 2 open -a Safari
run 'ui run --elevated is refused by name' 1 "$V" ui run mac1 --elevated open -a Safari
run 'ui run with no APP is a usage error' 1 "$V" ui run mac1
run 'ui run on a QEMU domain is refused by name' 1 "$V" ui run qemu1 open
has '  with the reason'                 'is not on the macOS driver for a QEMU domain'

# --- push, pull ----------------------------------------------------------------
# The "guest" is this host, so a guest path is a host path under the scratch.
printf '%s\n' '-- push, pull --'
G="${S#/}/guest"
mkdir -p "$S/src/sub" "$S/guest"
echo one > "$S/src/a.txt"; echo two > "$S/src/sub/b b.txt"; chmod 755 "$S/src/a.txt"
run 'push a directory'                  0 "$V" push mac1 "$S/src" "$G/"
has '  lands under its own name'        "mac1: 2 files present, 2 copied"
[[ -f "$S/guest/src/sub/b b.txt" ]] && ok '  a name with a space arrives whole' || bad '  a name with a space arrives whole'
[[ -x "$S/guest/src/a.txt" ]] && ok '  a new file keeps its mode' || bad '  a new file keeps its mode'
run 'a second push moves nothing'       0 "$V" push mac1 "$S/src" "$G/"
has '  and says so'                     '2 files present (all up to date)'
echo three > "$S/src/sub/c.txt"
run 'a third moves the one new file'    0 "$V" push mac1 "$S/src" "$G/"
has '  and says so'                     '3 files present, 1 copied'
run 'push SRC/ lands its contents'      0 "$V" push mac1 "$S/src/" "$G/flat"
[[ -f "$S/guest/flat/a.txt" && ! -e "$S/guest/flat/src" ]] && ok '  with no directory of its own' || bad '  with no directory of its own'
run 'push a file onto a new name'       0 "$V" push mac1 "$S/src/a.txt" "$G/deep/er/renamed.txt"
is  '  is that file'                    one "$(cat "$S/guest/deep/er/renamed.txt" 2>/dev/null)"
run 'push a file again'                 0 "$V" push mac1 "$S/src/a.txt" "$G/deep/er/renamed.txt"
has '  is already current'              '(already current)'
run 'push a file to DST/'               0 "$V" push mac1 "$S/src/a.txt" "$G/in dir/"
[[ -f "$S/guest/in dir/a.txt" ]] && ok '  goes inside it' || bad '  goes inside it'
run 'push: .. in DST is refused'        1 "$V" push mac1 "$S/src/a.txt" "$G/../x"
run 'push: a missing SRC is refused'    1 "$V" push mac1 "$S/nope" "$G/"
chmod 700 "$S/guest"
"$V" push mac1 "$S/src/" "$G" >/dev/null 2>&1
is  'push leaves an existing directory'\''s mode alone' 700 "$(stat -f %Lp "$S/guest")"
chmod 755 "$S/guest"

run 'pull by wildcard'                  0 "$V" pull mac1 "$G/src/sub/*.txt" "$S/out"
has '  counts what matched'             'mac1: 2 files pulled'
[[ -f "$S/out/b b.txt" && -f "$S/out/c.txt" ]] && ok '  into the directory' || bad '  into the directory'
run 'pull one file to a new name'       0 "$V" pull mac1 "$G/deep/er/renamed.txt" "$S/out2/got.txt"
[[ -f "$S/out2/got.txt" ]] && ok '  is that file' || bad '  is that file' "$(ls -la "$S/out2" 2>&1)"
[[ -z "$(find "$S/out2" -name '.virutil-pull-*')" ]] && ok '  and no landing directory is left' || bad '  and no landing directory is left'
run 'pull a directory'                  0 "$V" pull mac1 "$G/src" "$S/out3"
has '  counts it as one'                'mac1: 1 directory pulled'
if diff -r "$S/src" "$S/out3/src" >/dev/null; then ok 'push then pull round-trips the tree'; else bad 'push then pull round-trips the tree'; fi
run 'pull: no match is exit 94'         94 "$V" pull mac1 "$G/nope*" "$S/out4"
run 'push to a QEMU domain is refused by name' 1 "$V" push qemu1 "$S/src" x/
has '  with the reason'                 'is not on the macOS driver for a QEMU domain'
run 'pull from a QEMU domain is refused by name' 1 "$V" pull qemu1 x "$S/o"
[[ -z "$(ls -A "$VIRUTILS_DIR/tmp" 2>/dev/null)" ]] && ok 'no scratch is left under tmp' || bad 'no scratch is left under tmp' "$(ls -A "$VIRUTILS_DIR/tmp")"

# --- sync ----------------------------------------------------------------------
printf '%s\n' '-- sync --'
mkdir -p "$S/repo/build/bin" "$S/repo/build/obj" "$VIRUTILS_DIR/conf" "$S/guest/app/logs"
echo bin1 > "$S/repo/build/bin/tool"; echo o > "$S/repo/build/obj/x.o"; echo dbg > "$S/repo/build/bin/tool.dSYM"
echo stale > "$S/guest/app/logs/old.log"
cat > "$VIRUTILS_DIR/conf/app.conf" <<EOF
@repo=$S/repo
@staging=app
@guest=macos
@dest=$G/app
<build|.
!*.dSYM
bin/*|bin
-$G/app/logs
>pre  echo pre-ran > '$S/guest/pre'
>post test -f '$S/guest/app/bin/tool' && echo post-ran > '$S/guest/post'
EOF
run 'sync'                              0 "$V" sync mac1 -c app
has '  names the guest'                 'domain: mac1 (macos)'
has '  reports what crossed'            'mac1: 1 file offered, 1 copied'
has '  ends as every host does'         'copy complete -> mac1'
is  '  the mapped file landed'          bin1 "$(cat "$S/guest/app/bin/tool" 2>/dev/null)"
[[ ! -e "$S/guest/app/bin/tool.dSYM" ]] && ok '  the exclude held' || bad '  the exclude held'
[[ -d "$S/guest/app/logs" && ! -e "$S/guest/app/logs/old.log" ]] && ok '  the cleanup rule emptied its directory' || bad '  the cleanup rule emptied its directory'
[[ -f "$S/guest/pre" && -f "$S/guest/post" ]] && ok '  pre and post rules ran, post after the files' || bad '  pre and post rules ran, post after the files'
run 'a second sync'                     0 "$V" sync mac1 -c app
has '  moves nothing'                   'all already current in the guest'
sed -i '' 's/^@guest=macos$/@guest=linux/' "$VIRUTILS_DIR/conf/app.conf"
run 'sync: @guest that is not what tart runs is refused' 1 "$V" sync mac1 -c app
has '  naming the fix'                  '@guest=macos'
sed -i '' '/^@guest=/d' "$VIRUTILS_DIR/conf/app.conf"
run 'sync: no @guest means windows, and is refused' 1 "$V" sync mac1 -c app
run 'sync to a QEMU domain is refused by name' 1 "$V" sync qemu1 -c app
has '  with the reason'                 'is not on the macOS driver for a QEMU domain'

# --- shot, input ---------------------------------------------------------------
printf '%s\n' '-- shot, input --'
run 'shot'                              0 "$V" shot mac1 -o "$S/s.png"
has '  says the size'                   'mac1: 300x200'
is  '  writes a PNG'                    89504e470d0a1a0a "$(od -An -tx1 -N8 "$S/s.png" 2>/dev/null | tr -d ' \n')"
is  '  whose pixels are the frame'\''s' '42 150 7' "$(python3 - "$S/s.png" <<'EOF'
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read()
i = d.index(b'IDAT'); n = struct.unpack('>I', d[i-4:i])[0]
raw = zlib.decompress(d[i+4:i+4+n]); w = 300
row = raw[150 * (1 + w * 3):151 * (1 + w * 3)]
print(*row[1 + 42 * 3:1 + 42 * 3 + 3])
EOF
)"
: > "$S/vnc.log"
run 'input click'                       0 "$V" input click mac1 10 20
has '  says what it did'                'mac1: click 10,20 on 300x200'
is  '  move, press, release'            'pointer 0 10 20|pointer 1 10 20|pointer 0 10 20' "$(paste -sd'|' "$S/vnc.log")"
: > "$S/vnc.log"
run 'input click -b right --double'     0 "$V" input click mac1 5 6 -b right --double
is  '  two presses of the right button' 'pointer 0 5 6|pointer 4 5 6|pointer 0 5 6|pointer 4 5 6|pointer 0 5 6' "$(paste -sd'|' "$S/vnc.log")"
: > "$S/vnc.log"
run 'input wheel is refused for a macOS guest' 1 "$V" input wheel mac1 5 6 -2
has '  naming what scrolls instead'     'virutil input key mac1 down'
is  '  and nothing was sent'            '' "$(paste -sd'|' "$S/vnc.log")"
: > "$S/vnc.log"
run 'input drag'                        0 "$V" input drag mac1 0 0 100 50
is  '  press, ten steps, release'       13 "$(grep -c . "$S/vnc.log")"
is  '  ending where it was told'        'pointer 0 100 50' "$(tail -n 1 "$S/vnc.log")"
: > "$S/vnc.log"
run 'input key cmd+a'                   0 "$V" input key mac1 cmd+a
is  '  cmd is the keysym a Mac takes as Command' 'key down 0xffe9|key down 0x61|key up 0x61|key up 0xffe9' "$(paste -sd'|' "$S/vnc.log")"
: > "$S/vnc.log"
run 'input key alt+shift+1'             0 "$V" input key mac1 'alt+shift+1'
is  '  Option, and the plain key under a held Shift' 'key down 0xffe7|key down 0xffe1|key down 0x31|key up 0x31|key up 0xffe1|key up 0xffe7' "$(paste -sd'|' "$S/vnc.log")"
: > "$S/vnc.log"
run 'input type'                        0 "$V" input type mac1 'aB!'
has '  counts characters'               'typed 3 characters'
is  '  a capital and a ! are Shift and the plain key' 'key down 0x61|key up 0x61|key down 0xffe1|key down 0x62|key up 0x62|key up 0xffe1|key down 0xffe1|key down 0x31|key up 0x31|key up 0xffe1' "$(paste -sd'|' "$S/vnc.log")"
run 'input: a position off the screen is refused' 1 "$V" input click mac1 300 10
has '  by size'                         "300,10 is outside mac1's 300x200 screen"
run 'input: an unknown key is refused before anything is sent' 1 "$V" input key mac1 ctrl+nosuchkey

# --- shutdown, snapshot, delete -------------------------------------------------
printf '%s\n' '-- shutdown, snapshot --'
run 'snapshot create on a running domain is refused' 1 "$V" snapshot create mac1 s1
has '  with the two commands'           'virutil domain shutdown mac1'
run 'shutdown goes through the agent'   0 "$V" domain shutdown mac1
has '  and says so'                     '(guest agent)'
for _ in $(seq 30); do [[ "$("$V" domain list 2>/dev/null)" == *'mac1                     shut off'* ]] && break; sleep 0.1; done
run 'shot on a shut-off domain is refused' 1 "$V" shot mac1 -o "$S/no.png"
run 'exec on a shut-off domain is refused' 1 "$V" exec ping mac1
run 'push to a shut-off domain is refused' 1 "$V" push mac1 "$S/src" "$G/"
has '  naming start'                    'virutil domain start mac1'
run 'snapshot create'                   0 "$V" snapshot create mac1 s1
has '  disk-only, in every host'\''s words' 'created: s1'
run 'snapshot create: the name is taken' 1 "$V" snapshot create mac1 s1
run 'snapshot list'                     0 "$V" snapshot list mac1
has '  shows it shut off'               ' s1 '
[[ "$OUT" == *shutoff* ]] && ok '  with virsh'\''s word' || bad '  with virsh'\''s word' "$OUT"
MAC="$(cat "$S/tart/vms/mac1/mac")"
echo changed > "$S/tart/vms/mac1/image"
run 'snapshot revert'                   0 "$V" snapshot revert mac1 s1
has '  says so'                         'reverted: s1'
is  '  the disk is the snapshot'\''s'   'pulled ghcr.io/acme/macos:1' "$(cat "$S/tart/vms/mac1/image")"
is  '  the domain keeps its MAC address' "$MAC" "$(cat "$S/tart/vms/mac1/mac")"
is  '  and is running, started as it last was' '--vnc-experimental --no-graphics mac1' "$(cat "$S/tart/vms/mac1/run-args")"
run 'the power button, with no agent'   0 bash -c "touch '$S/tart/vms/mac1/no-agent'; '$V' domain shutdown mac1"
has '  says which it was'               '(power button)'
for _ in $(seq 30); do [[ "$("$V" domain list 2>/dev/null)" == *'mac1                     shut off'* ]] && break; sleep 0.1; done
run 'start, then destroy'               0 bash -c "'$V' domain start mac1 -G && '$V' domain destroy mac1"
has '  is tart stop'                    'mac1 is destroyed (tart stop)'
run 'destroy of a shut-off domain is refused' 1 "$V" domain destroy mac1
run 'snapshot revert: no such snapshot' 1 "$V" snapshot revert mac1 nosuch
run 'delete takes the snapshots with it' 0 "$V" domain delete mac1
[[ ! -e "$S/tart/vms/mac1" && ! -e "$S/tart/vms/mac1@s1" ]] && ok '  the VM and its clone are gone' || bad '  the VM and its clone are gone' "$(ls "$S/tart/vms")"
[[ -z "$(ls "$IMG" | grep '^mac1')" ]] && ok '  and nothing of it is left in images' || bad '  and nothing of it is left in images' "$(ls "$IMG")"
run 'the other tart domain is untouched' 0 "$V" domain list
has '  and still listed'                ' mac2 '

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
