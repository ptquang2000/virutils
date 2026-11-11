#!/usr/bin/env bash
# tests/linux/xfer.sh -- what sync, push and pull report when the guest
# copier's line never came back.
#
# Each payload ends by printing one fixed line of numbers, and the reports used
# to read a missing field as zero. MDE-6273 r1-4 is the case: the answer to a
# delivery's status came from another process's qemu-ga record, carrying no
# output, and the sync printed "all already current in the guest" for a
# delivery that never ran (docs/qga-exec-records.md). No line, or one that is
# not the payload's shape, has to stop the command instead -- after its normal
# teardown -- and a good line still reports as before. tests/win/sync.ps1 and
# tests/win/xfer.ps1 have the same cases for the Windows driver.
#
# The transport is substituted the way tests/linux/pull.sh does it: no smbd, no
# rsyncd, no guest. The modules are sourced as the driver sources them, then
# the serve, the fetch and the teardown are replaced; the "guest" prints
# GUEST_OUT. Needs GNU du (on a Mac, Homebrew's gdu).
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0 FAIL=0
ok()    { printf 'ok       %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf 'FAIL     %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi; }
has()   { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "wanted [*$2*], got [$3]"; fi; }
hasnt() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "wanted no [*$2*], got [$3]"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vu.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
export VIRUTILS_DIR="$WORK/root"
mkdir -p "$WORK/bin"
export PATH="$WORK/bin:$PATH"
if ! du -sb --apparent-size "$WORK" >/dev/null 2>&1; then
    command -v gdu >/dev/null || { printf 'skip     no GNU du here\n'; exit 0; }
    ln -s "$(command -v gdu)" "$WORK/bin/du"
fi
hash -r

# run FUNCTION ARGS... -- one command against the stubs, stdout and stderr
# together into OUT and its exit code into RC. Each in its own subshell: the
# commands exit on failure, and their traps are their own. xfer_stop says when
# it ran, so the teardown can be placed against the report.
run() {
    OUT="$( {
        M="$ROOT/modules/linux"
        # shellcheck source=/dev/null
        source "$M/parser"
        for f in "$M"/*; do
            n="${f##*/}"
            [[ "$n" == parser || " ${MODULES[*]} " == *" $n "* ]] || source "$f"
        done
        for n in "${MODULES[@]}"; do source "$M/$n"; done
        domain_exists()  { :; }
        guest_os()       { printf '%s' "$GUEST"; }
        xfer_check()     { :; }
        push_check_readable() { :; }
        domain_ip()      { printf '192.0.2.10'; }
        xfer_host_addr() { printf '192.0.2.1'; }
        xfer_room_for()  { :; }
        guest_root_show() { :; }
        push_net_serve() { :; }
        pull_net_serve() { :; }
        sync_net_serve() { :; }
        sync_map_into()  { printf 'x\n' > "$1/a.txt"; }
        push_net_fetch() { printf '%s' "$GUEST_OUT"; }
        pull_net_fetch() { printf '%s' "$GUEST_OUT"; }
        sync_net_fetch() { printf '%s' "$GUEST_OUT"; }
        xfer_stop()      { [[ -n "${STOPPED:-}" ]] || echo 'TEARDOWN'; STOPPED=1; }
        now_ms()         { printf '0'; }
        set -euo pipefail
        "$@"
    } 2>&1 )"
    RC=$?
}

# torn_down_first -- the teardown ran, and before the stop was reported.
torn_down_first() {
    local before="${OUT%%guest copier sent no result*}"
    [[ "$before" == *TEARDOWN* ]] && echo yes || echo no
}

cd "$WORK"
mkdir -p tree/sub && printf 'a\n' > tree/sub/a.txt && printf 'one\n' > one.bin

# --- sync -------------------------------------------------------------------
# What sync_main has settled by the time it delivers, then the delivery.
run_sync() {
    DOMAIN=vm GUEST_OS="$GUEST" STAGING="$WORK/tree"
    RUN_PRE=() RUN_POST=() CLEANUP=()
    sync_net_push
}
sync_with() {
    export GUEST="$1" GUEST_OUT="$2"
    run run_sync
}

for bad_line in '' '1' 'robocopy said something' '1 1234 9'; do
    sync_with windows "$bad_line"
    check "a Windows guest's line of [$bad_line] stops the sync" 1 "$RC"
    has   '  unverified' 'guest copier sent no result; delivery unverified' "$OUT"
    hasnt '  and never reads as current' 'already current' "$OUT"
    check '  after the share was taken down' yes "$(torn_down_first)"
done
sync_with windows '0 1234'
check 'a Windows guest'"'"'s good line still reports' 0 "$RC"
has   '  as current when nothing moved' 'all already current in the guest' "$OUT"
sync_with windows '1 1234'
has   '  and as copied when something did' 'the ones that differed copied' "$OUT"

for bad_line in '' '5'; do
    sync_with linux "$bad_line"
    check "a Linux guest's line of [$bad_line] stops the sync" 1 "$RC"
    has   '  unverified' 'guest copier sent no result; delivery unverified' "$OUT"
    hasnt '  and never reads as current' 'already current' "$OUT"
done
sync_with linux '3 1234'
check 'a Linux guest'"'"'s good line still reports' 0 "$RC"
has   '  with its count' '1 file offered, 3 copied in' "$OUT"

# --- push -------------------------------------------------------------------
push_with() {
    export GUEST="$1" GUEST_OUT="$2"; shift 2
    run push_main vm "$@"
}

for c in "tree|opt/app|" "tree|opt/app|1 2" "one.bin|opt/app/|"; do
    IFS='|' read -r src dst line <<<"$c"
    push_with windows "$line" "$src" "$dst"
    check "a push of $src to a Windows guest answered [$line] stops" 1 "$RC"
    has   '  unverified' 'guest copier sent no result; delivery unverified' "$OUT"
    hasnt '  and never reads as up to date' 'up to date' "$OUT"
    check '  after the share was taken down' yes "$(torn_down_first)"
done
push_with windows '0 1 40' tree opt/app
has 'a good directory line still reports' '1 file present (all up to date)' "$OUT"
push_with windows '4 40' one.bin opt/app/
has 'and a good file line' 'done (4' "$OUT"

for c in "tree|opt/app|" "one.bin|opt/app/|4 40" "one.bin|opt/app/|"; do
    IFS='|' read -r src dst line <<<"$c"
    push_with linux "$line" "$src" "$dst"
    check "a push of $src to a Linux guest answered [$line] stops" 1 "$RC"
    has   '  unverified' 'guest copier sent no result; delivery unverified' "$OUT"
    hasnt '  and never reads as current' 'already current' "$OUT"
    hasnt '  or up to date' 'up to date' "$OUT"
done
push_with linux '0 4 40' one.bin opt/app/
has 'a Linux guest'"'"'s good file line still reports' '(already current)' "$OUT"
push_with linux '1 1 40' tree opt/app
has '  and its directory line' '1 file present, 1 copied' "$OUT"

# --- pull -------------------------------------------------------------------
for g in windows linux; do
    for line in '' '2 1'; do
        export GUEST="$g" GUEST_OUT="$line"
        run pull_main vm 'logs/*.log' "$WORK/out/"
        check "a pull from a $g guest answered [$line] stops" 1 "$RC"
        has   '  unverified' 'guest copier sent no result; delivery unverified' "$OUT"
        hasnt '  and never reads as 0 files' '0 files pulled' "$OUT"
        check '  after the share was taken down' yes "$(torn_down_first)"
    done
done
export GUEST=windows GUEST_OUT='2 1 30'
run pull_main vm 'logs/*.log' "$WORK/out/"
has 'a good pull line still reports' '2 files and 1 directory pulled' "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
