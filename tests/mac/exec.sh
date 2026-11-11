#!/usr/bin/env bash
# tests/mac/exec.sh -- qemu-ga's exec records on the macOS driver: a reused
# pid never answers for another process, the ledger is reaped before each
# exec, and `exec ps -d` leaves no record (docs/qga-exec-records.md).
#
# The cases are in tests/linux/exec-records.sh, shared with the libvirt tree.
# Here they run through modules/mac's own agent(), the locked round trip over
# the agent socket, against tests/mac/fake-qga.pl started with `model`. Like
# tests/mac/agent.sh this needs no Mac: it runs wherever bash 4, jq, perl,
# iconv and `nc -U` or socat do.
#
#   tests/mac/exec.sh
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

for t in jq perl iconv; do
    command -v "$t" >/dev/null || { printf 'skip     no %s here\n' "$t"; exit 0; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vu.XXXXXX")"
FAKE=""
cleanup() { [[ -n "$FAKE" ]] && kill "$FAKE" 2>/dev/null; rm -rf -- "$WORK"; }
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

# shellcheck source=/dev/null
source "$M/parser"; source "$M/paths"; source "$M/qemu"; source "$M/guest"; source "$M/exec"
domain_running() { return 0; }
# After the sourcing: modules/mac/qemu sets its own EXIT trap.
trap cleanup EXIT
set +e

VM=fx
printf '#!/bin/sh\n%s %s -- tests/mac/exec.sh\n' "$DOMAIN_MARK" "$VM" > "$IMG/$VM.sh"
perl "$HERE/fake-qga.pl" "$IMG/$VM.qga" "$WORK/fake.log" model >/dev/null 2>&1 &
FAKE=$!
for (( i = 0; i < 100; i++ )); do grep -qx ready "$WORK/fake.log" 2>/dev/null && break; sleep 0.1; done
agent_need "$VM"

# shellcheck source=../linux/exec-records.sh
source "$ROOT/tests/linux/exec-records.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
