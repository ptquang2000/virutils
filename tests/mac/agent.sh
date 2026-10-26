#!/usr/bin/env bash
# tests/mac/agent.sh -- two virutil runs against one domain's guest agent, on
# the macOS driver. Check that they take turns rather than collide.
#
# tests/win/agent.ps1 is the same test for the Windows driver, and the header
# there says what is checked and why. Like tests/mac/input.sh this needs no Mac:
# modules/mac is sourced on its own against tests/mac/fake-qga.pl, a stand-in
# agent on a Unix socket, so it runs wherever bash 4, jq and perl do. A host
# with no `nc -U` (Linux, WSL) talks to the socket through socat instead.
#
#   tests/mac/agent.sh
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
M="$ROOT/modules/mac"

PASS=0 FAIL=0
ok()    { printf 'ok       %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf 'FAIL     %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi; }
has()   { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "wanted [*$2*], got [$3]"; fi; }

for t in jq perl; do
    command -v "$t" >/dev/null || { printf 'skip     no %s here\n' "$t"; exit 0; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vu.XXXXXX")"
FAKES=()
cleanup() {
    local p
    for p in "${FAKES[@]+"${FAKES[@]}"}"; do kill "$p" 2>/dev/null; done
    rm -rf -- "$WORK"
}
export VIRUTILS_DIR="$WORK/v"
IMG="$VIRUTILS_DIR/images"
mkdir -p "$IMG" "$WORK/bin"

# macOS's nc speaks -U; elsewhere socat stands in for it.
if [[ "$(uname -s)" != Darwin ]]; then
    command -v socat >/dev/null || { printf 'skip     no nc -U and no socat here\n'; exit 0; }
    printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == -U ]] && exec socat - "UNIX-CONNECT:$2"' \
        'exit 2' > "$WORK/bin/nc"
    chmod +x "$WORK/bin/nc"
    export PATH="$WORK/bin:$PATH"
fi

# What a child -- a stand-in for another virutil run -- sources.
PRELUDE="set -uo pipefail; export LC_ALL=C; source '$M/parser'; source '$M/paths'; source '$M/qemu'; source '$M/guest'; source '$M/exec'; domain_running() { return 0; }"
eval "$PRELUDE"
# After the sourcing: modules/mac/qemu sets its own EXIT trap.
trap cleanup EXIT
set +e

# fake NAME [OPTS] -- a fake agent behind a fake domain NAME; its log path in
# FAKE_LOG. Not on stdout: called in a $(...) its pid would not reach FAKES.
fake() {
    local name="$1" log="$WORK/$1.log" i; shift
    printf '#!/bin/sh\n%s %s -- tests/mac/agent.sh\n' "$DOMAIN_MARK" "$name" > "$IMG/$name.sh"
    # Not on our stdout: a $(fake ...) would wait for perl to close it.
    perl "$HERE/fake-qga.pl" "$IMG/$name.qga" "$log" "$@" >/dev/null 2>&1 &
    FAKES+=("$!")
    for (( i = 0; i < 100; i++ )); do grep -qx ready "$log" 2>/dev/null && break; sleep 0.1; done
    FAKE_LOG="$log"
}
connects() { grep -c '^connect' "$1"; }

# child NAME [RELEASE] -- take NAME's lock as another run would, say so, hold
# it until RELEASE exists, let go.
child() {
    bash -c "$PRELUDE; AGENT_LOCK_COMMAND='sync $1'; agent_lock '$1'; echo got; while [[ -n '${2:-}' && ! -e '${2:-}' ]]; do sleep 0.05; done; agent_unlock" \
        >"$WORK/$1.$3.out" 2>"$WORK/$1.$3.err"
}
wait_for() { local i; for (( i = 0; i < 300; i++ )); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

# --- the lock ------------------------------------------------------------------

agent_lock lk
has 'the holder writes who it is' "virutil pid $$" "$(cat "$(domain_agent_lock lk)")"
agent_lock lk; agent_unlock
VIRUTILS_AGENT_WAIT=0 child lk '' a; check 're-entrant: one unlock of two leaves it held' 1 "$?"
agent_unlock
VIRUTILS_AGENT_WAIT=0 child lk '' b; check 'and the second lets it go' 0 "$?"

child lw "$WORK/lw.release" a & HOLDER=$!
wait_for "$WORK/lw.a.out" got
VIRUTILS_AGENT_WAIT=60 child lw '' b & WAITER=$!
wait_for "$WORK/lw.b.err" 'waiting for'
touch "$WORK/lw.release"
wait "$WAITER"; check 'a waiter gets the lock once the holder lets go' 0 "$?"
wait "$HOLDER"
has 'and was told who held it' "waiting for lw's guest agent: held by virutil pid" "$(cat "$WORK/lw.b.err")"
has '  with what it is doing' '`sync lw`' "$(cat "$WORK/lw.b.err")"
check '  once' 1 "$(grep -c 'waiting for' "$WORK/lw.b.err")"

child lt "$WORK/lt.release" a & HOLDER=$!
wait_for "$WORK/lt.a.out" got
VIRUTILS_AGENT_WAIT=1 child lt '' b; check 'a wait that runs out fails' 1 "$?"
has '  naming the holder and the knob' "gave up after 1s waiting for lt's guest agent" "$(cat "$WORK/lt.b.err")"
has '  and the knob' 'VIRUTILS_AGENT_WAIT' "$(cat "$WORK/lt.b.err")"
touch "$WORK/lt.release"; wait "$HOLDER"

child lk2 "$WORK/never" a & HOLDER=$!
wait_for "$WORK/lk2.a.out" got
kill -9 "$HOLDER"; wait "$HOLDER" 2>/dev/null
pkill -9 -f "agent_lock 'lk2'" 2>/dev/null
VIRUTILS_AGENT_WAIT=0 child lk2 '' b; check 'a killed holder frees the lock at once' 0 "$?"

has 'a VIRUTILS_AGENT_WAIT that is not a number is refused' 'whole number of seconds' \
    "$( (VIRUTILS_AGENT_WAIT=soon; agent_lock bad) 2>&1)"

# --- the round trip ------------------------------------------------------------

n() { jq -r '.return.n // empty' 2>/dev/null; }
call() { ( agent "$1" "${3:-10}" "$2" ) 2>&1; }

fake fa
check 'a round trip returns its own reply' 7 "$(call '{"execute":"guest-echo","arguments":{"n":7}}' fa | n)"
check '  and leaves no lock held' '' "$AGENT_LOCK_FD"
has 'an agent error is reported as one' 'CommandNotFound' "$(call '{"execute":"guest-nope"}' fa)"
has 'a reply that does not come in time fails the call' 'did not answer guest-slow within 1s' \
    "$(call '{"execute":"guest-slow","arguments":{"ms":2500,"n":1}}' fa 1)"
check '  and the next call reads its own reply, not that one' 2 "$(call '{"execute":"guest-echo","arguments":{"n":2}}' fa | n)"

fake fs stale=3
check 'replies left over from an earlier client are drained' 3 "$(call '{"execute":"guest-echo","arguments":{"n":3}}' fs | n)"

# virtio-win's qemu-ga 7.6.2 refuses a request carrying an "id"; so none is sent.
fake fn rejectid
check 'an agent that refuses an id still works' 4 "$(call '{"execute":"guest-echo","arguments":{"n":4}}' fn | n)"

fake fb boot=3000; log="$FAKE_LOG"
( guest_agent_wait fb 15 ); check 'guest_agent_wait waits for an agent to come up' 0 "$?"
check '  over one connection' 1 "$(connects "$log")"

printf '#!/bin/sh\n%s fz\n' "$DOMAIN_MARK" > "$IMG/fz.sh"
( guest_agent_wait fz 1 ); check 'guest_agent_wait with nothing listening is false' 1 "$?"
has '  and a call says the agent is not answering' "fz's QEMU guest agent is not answering" \
    "$(call '{"execute":"guest-ping"}' fz)"

# --- several runs at once ----------------------------------------------------------
#
# Each loop is its own bash running `exec cmd` in turn, and the fake's exec
# output is the argv it was given, so a crossed reply shows up as another
# loop's text.
fake fc
for t in A B C; do
    bash -c "$PRELUDE"'
        for (( i = 1; i <= 8; i++ )); do
            got="$( (exec_main cmd fc "echo '"$t"'-$i") 2>/dev/null)"; rc=$?
            if [[ $rc == 0 && "$got" == "/c echo '"$t"'-$i" ]]; then echo "ok '"$t"'-$i"
            else echo "BAD '"$t"'-$i rc=$rc got=[$got]"; fi
        done' > "$WORK/loop-$t.out" 2>&1 &
done
for j in $(jobs -p); do
    for f in "${FAKES[@]}"; do [[ "$j" == "$f" ]] && continue 2; done
    wait "$j"
done
check 'three concurrent exec loops: every call answered' 24 "$(cat "$WORK"/loop-*.out | grep -c '^ok ')"
check '  with its own output, and none timed out' '' "$(grep -hv '^ok ' "$WORK"/loop-*.out | paste -sd';' -)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
