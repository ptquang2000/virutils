#!/usr/bin/env bash
# tests/mac/input.sh -- modules/mac/input with QMP substituted.
#
# Unlike tests/mac/domain.sh this needs no Mac: the module is sourced on its
# own, with modules/mac/qemu's qmp() and the domain lookups replaced, so it
# runs wherever bash 4 and jq do. qmp() logs each command and answers
# query-status, query-mice and screendump (a 1280x800 PNG written where it was
# asked). What is asserted is what the macOS host would send: the same QMP
# tests/linux/input.sh holds the Linux module to, the refusals, and that a
# position is sized against the screendump.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0 FAIL=0 SKIP=0
ok()   { printf 'ok       %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL     %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi; }
has()   { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "wanted [*$2*], got [$3]"; fi; }

command -v jq >/dev/null || { printf 'skip     input needs jq, and there is none here\n'; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
export VIRUTILS_DIR="$WORK/root"
LOG="$WORK/qmp.log"

M="$ROOT/modules/mac"
# shellcheck source=/dev/null
source "$M/parser"; source "$M/paths"; source "$M/qemu"; source "$M/shot"; source "$M/input"
trap 'rm -rf -- "$WORK"' EXIT

STATUS=running RUNNING=1
MICE='[{"name":"QEMU HID Tablet","index":3,"current":true,"absolute":true}]'
domain_need()    { [[ "$1" != nosuch ]] || die "no such domain: $1 (see: virutil domain list)"; }
domain_running() { (( RUNNING )); }
qmp_need()       { printf 'open\n' >> "$LOG"; }
qmp() {
    case "$1" in
        query-status) printf '{"status":"%s"}\n' "$STATUS" ;;
        query-mice)   printf '%s\n' "$MICE"; printf 'query-mice\n' >> "$LOG" ;;
        screendump)   printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\x05\x00\0\0\x03\x20\x08\x02\0\0\0' > "$(jq -r .filename <<<"$2")"
                      printf '{}\n' ;;
        input-send-event)
            jq -r '.events | map(if .type == "abs" then "\(.data.axis)=\(.data.value)"
                   else "\(.data.button):\(if .data.down then "down" else "up" end)" end) | join(",")' <<<"$2" >> "$LOG"
            printf '{}\n' ;;
        send-key)
            jq -r '"key " + (.keys | map(.data) | join("-")) + " \(.["hold-time"])"' <<<"$2" >> "$LOG"
            printf '{}\n' ;;
        *) printf '{}\n' ;;
    esac
}
input_wait() { :; }

run()    { ( input_main "$@" ) 2>&1; }
events() { [[ -f "$LOG" ]] && grep -v '^open$' "$LOG" | paste -sd'|' -; rm -f -- "$LOG"; }

check 'input -h exits 0'               0 "$( ( input_main -h ) >/dev/null 2>&1; echo $?)"
check 'click with one coordinate exits 1' 1 "$( ( input_main click vm 3 ) >/dev/null 2>&1; echo $?)"
has 'an unknown key is refused'        "unknown key 'zz' in 'ctrl+zz'" "$(run key vm ctrl+zz)"
has 'an untypeable character is refused by code point' '(U+00E9)' "$(run type vm "$(printf '\xc3\xa9')")"
has 'an unknown domain is named'       'no such domain: nosuch' "$(run click nosuch 1 2)"
check '  and nothing was sent'         '' "$(events)"

out="$(run click vm 640 400)"
check 'click: mice, then move, press, release' 'query-mice|x=16396,y=16404|left:down|left:up' "$(events)"
check '  sized by the screendump'      'vm: click 640,400 on 1280x800' "$out"
run click vm 0 799 --double -b right >/dev/null
check 'double right click'  'query-mice|x=12,y=32747|right:down|right:up|right:down|right:up' "$(events)"
run wheel vm 10 10 -2 >/dev/null
check 'wheel -2'            'query-mice|x=268,y=430|wheel-down:down|wheel-down:up|wheel-down:down|wheel-down:up' "$(events)"
run drag vm 0 0 100 0 >/dev/null
check 'drag: mice, start, press, ten steps, release' 14 "$(events | tr '|' '\n' | wc -l | tr -d ' ')"
run key vm ctrl+alt+delete win >/dev/null
check 'key'                 'key ctrl-alt-delete 100|key meta_l 100' "$(events)"
run type vm 'Ok?' >/dev/null
check 'type'                'key shift-o 30|key k 30|key shift-slash 30' "$(events)"

STATUS=paused
has 'a paused domain is refused'       'vm is not running (paused)' "$(run key vm enter)"
check '  and nothing is sent'          '' "$(events)"
STATUS=running
RUNNING=0
has 'a shut-off domain is refused'     'vm is not running (shut off)' "$(run key vm enter)"
RUNNING=1

MICE='[{"name":"QEMU PS/2 Mouse","index":2,"current":true,"absolute":false}]'
out="$(run click vm 1 1)"
has 'no absolute pointer is refused'   'no absolute pointer' "$out"
has '  saying what to add'             '-device usb-tablet,bus=xhci.0' "$out"
check '  and nothing but the question is sent' 'query-mice' "$(events)"
MICE='[{"name":"QEMU HID Tablet","index":3,"current":true,"absolute":true}]'

has 'a position off the screen is refused' "1,800 is outside vm's 1280x800 screen" "$(run move vm 1 800)"
check 'no scratch file is left'        0 "$(find "$VIRUTILS_DIR/tmp" -name 'input-*' 2>/dev/null | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
