#!/usr/bin/env bash
# tests/linux/input.sh -- modules/linux/input with virsh substituted.
#
# A stub `virsh` goes first on PATH and answers the three calls input makes:
# `domstate VM`, `screenshot VM --file F` (a 1280x800 PNG, or a PPM), and
# `qemu-monitor-command VM JSON`, which it logs and answers -- query-mice from
# STUB_MICE, everything else with an empty return. What is asserted:
#
#   * the grammar and its exit codes, which are contract;
#   * a bad combo and an untypeable character are refused before the domain is
#     looked up, the character by its code point;
#   * each verb's QMP, in order: absolute positions at the centre of the
#     pixel's slice of 0..32767, buttons, wheel notches, send-key combos, and
#     type's US layout;
#   * a paused domain, one with no absolute pointer and a position off the
#     screen are each refused, and nothing is sent.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0 FAIL=0 SKIP=0
ok()   { printf 'ok       %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL     %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
skip() { printf 'skip     %s\n' "$1"; SKIP=$((SKIP + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi; }
has()   { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "wanted [*$2*], got [$3]"; fi; }

if [[ "$(uname -s)" == Darwin ]]; then
    skip 'modules/linux/input is not the tree a Mac runs'
    printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
    exit 0
fi
command -v jq >/dev/null || { skip 'input needs jq, and there is none here'; printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
export VIRUTILS_DIR="$WORK/root"
export STUB_LOG="$WORK/qmp.log"
mkdir -p "$WORK/bin"

# STUB_STATE is what domstate prints ("" for no such domain); STUB_FORMAT png
# or ppm; STUB_MICE query-mice's return.
cat > "$WORK/bin/virsh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --connect ]] && shift 2
case "$1" in
    domstate)
        [[ -n "${STUB_STATE:-}" ]] || { echo "error: failed to get domain '$2'" >&2; exit 1; }
        printf '%s\n\n' "$STUB_STATE" ;;
    screenshot)
        file="$4"
        if [[ "${STUB_FORMAT:-png}" == ppm ]]; then printf 'P6\n1024 768\n255\n\0\0\0' > "$file"
        else printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\x05\x00\0\0\x03\x20\x08\x02\0\0\0' > "$file"; fi ;;
    qemu-monitor-command)
        printf '%s\n' "$3" >> "$STUB_LOG"
        case "$3" in
            *query-mice*) printf '{"return":%s,"id":"libvirt-1"}\n' "$STUB_MICE" ;;
            *) printf '{"return":{},"id":"libvirt-1"}\n' ;;
        esac ;;
esac
STUB
chmod +x "$WORK/bin/virsh"
export PATH="$WORK/bin:$PATH"

input() { bash "$ROOT/virutil" input "$@"; }
code() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
# events -- what was sent since the last call, one short line per command.
events() {
    [[ -f "$STUB_LOG" ]] || return 0
    jq -r 'if .execute == "input-send-event" then .arguments.events | map(
               if .type == "abs" then "\(.data.axis)=\(.data.value)"
               else "\(.data.button):\(if .data.down then "down" else "up" end)" end) | join(",")
           elif .execute == "send-key" then "key " + (.arguments.keys | map(.data) | join("-")) + " \(.arguments["hold-time"])"
           else .execute end' "$STUB_LOG" | paste -sd'|' -
    rm -f -- "$STUB_LOG"
}

export STUB_STATE=running STUB_FORMAT=png
export STUB_MICE='[{"name":"QEMU HID Tablet","index":3,"current":true,"absolute":true},{"name":"QEMU PS/2 Mouse","index":2,"current":false,"absolute":false}]'

check 'input -h exits 0'               0 "$(code input -h)"
check 'input click -h exits 0'         0 "$(code input click -h)"
check 'input with no verb exits 1'     1 "$(code input)"
check 'an unknown verb exits 1'        1 "$(code input poke vm)"
check 'click with one coordinate exits 1' 1 "$(code input click vm 3)"
check 'drag with two exits 1'          1 "$(code input drag vm 1 2)"
check 'key with no combo exits 1'      1 "$(code input key vm)"
has 'a coordinate must be a number'    "expected a number, got 'x'" "$(input click vm x 3 2>&1)"
has '-b takes left, right or middle'   'left, right or middle' "$(input click vm 1 2 -b side 2>&1)"
has '--double is click'"'"'s alone'    'unknown flag for move: --double' "$(input move vm 1 2 --double 2>&1)"

out="$(STUB_STATE='' input key nosuch ctrl+zz 2>&1)"
has 'an unknown key is refused before the domain is looked up' "unknown key 'zz' in 'ctrl+zz'" "$out"
han="$(printf '\xe4\xb8\xad')"
out="$(STUB_STATE='' input type nosuch "$(printf 'caf\xc3\xa9')" "$han" 2>&1)"
has 'an untypeable character is refused by code point' "(U+00E9), '$han' (U+4E2D)" "$out"
has '  and nothing is sent'              'Nothing was sent' "$out"
out="$(STUB_STATE='' input click nosuch 1 2 2>&1)"
has 'an unknown domain is named'         'no such VM: nosuch' "$out"
check '  and nothing reached the monitor' '' "$(events)"

err="$(input click vm 640 400 2>&1 >/dev/null)"
check 'click: mice, then move, press, release' 'query-mice|x=16396,y=16404|left:down|left:up' "$(events)"
check '  saying what it did'             'vm: click 640,400 on 1280x800' "$err"

input click vm 0 799 --double -b right >/dev/null 2>&1
check 'double right click'  'query-mice|x=12,y=32747|right:down|right:up|right:down|right:up' "$(events)"

input move vm 1279 0 >/dev/null 2>&1
check 'move'                'query-mice|x=32755,y=20' "$(events)"

input wheel vm 10 10 -2 >/dev/null 2>&1
check 'wheel -2: two notches down' 'query-mice|x=268,y=430|wheel-down:down|wheel-down:up|wheel-down:down|wheel-down:up' "$(events)"
input wheel vm 10 10 1 >/dev/null 2>&1
check 'wheel 1: one notch up'      'query-mice|x=268,y=430|wheel-up:down|wheel-up:up' "$(events)"

input drag vm 0 0 100 0 -b middle >/dev/null 2>&1
ev="$(events)"
check 'drag: mice, start, press, ten steps, release' 14 "$(tr '|' '\n' <<<"$ev" | wc -l | tr -d ' ')"
has '  pressed at the start'         'x=12,y=20|middle:down' "$ev"
has '  released at the end'          "x=$(( (2 * 100 + 1) * 32768 / 2560 )),y=20|middle:up" "$ev"

STUB_FORMAT=ppm input move vm 1023 767 >/dev/null 2>&1
check 'a PPM screenshot sizes the screen too' "query-mice|x=$(( 2047 * 32768 / 2048 )),y=$(( 1535 * 32768 / 1536 ))" "$(events)"

input key vm ctrl+a enter Alt+F4 'ctrl++' >/dev/null 2>&1
check 'key: each combo, default hold' 'key ctrl-a 100|key ret 100|key alt-f4 100|key ctrl-shift-equal 100' "$(events)"

input type vm 'Hi!' $'a\tb\n' '-x"' >/dev/null 2>&1
check 'type: US layout, words joined by a space, a dash typed' \
    'key shift-h 30|key i 30|key shift-1 30|key spc 30|key a 30|key tab 30|key b 30|key ret 30|key spc 30|key minus 30|key x 30|key shift-apostrophe 30' "$(events)"

out="$(STUB_STATE=paused input key vm enter 2>&1)"
has 'a paused domain is refused'       'vm is not running (paused)' "$out"
check '  and nothing is sent'          '' "$(events)"

out="$(STUB_MICE='[{"name":"QEMU PS/2 Mouse","index":2,"current":true,"absolute":false}]' input click vm 1 1 2>&1)"
has 'no absolute pointer is refused'   'no absolute pointer' "$out"
has '  naming what qemu has'           'qemu lists: QEMU PS/2 Mouse' "$out"
has '  and saying what to add'         "<input type='tablet' bus='usb'/>" "$out"
check '  and nothing but the question is sent' 'query-mice' "$(events)"
STUB_MICE='[]' input key vm enter >/dev/null 2>&1
check 'key still works without one'    'key ret 100' "$(events)"

out="$(input drag vm 1 1 1280 5 2>&1)"
has 'a position off the screen is refused' "1280,5 is outside vm's 1280x800 screen" "$out"
check '  and nothing is sent'          'query-mice' "$(events)"

check 'no scratch file is left'        0 "$(find "$VIRUTILS_DIR/tmp" -name 'input-*' 2>/dev/null | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
