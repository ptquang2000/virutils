#!/usr/bin/env bash
# tests/conformance.sh -- drive both drivers and check they agree where
# docs/contract.md says they must.
#
# There is no shared library between virutil and virutil.ps1, so a test that
# drives both and diffs the observable behaviour is worth more than any amount
# of code review -- it is the only thing that can catch the two drifting apart.
# Section 8 of the contract lists the minimum; what is here is the part of that
# minimum which needs no guest:
#
#   * every --help exits 0
#   * every usage error exits 1
#   * both payload renderers emit byte-identical text
#
# The rest of section 8 -- a push/pull round trip, a second push moving nothing,
# exec propagating a guest exit code, domain create leaving exactly the files
# section 3 names -- needs a running guest with an agent in it and is not run
# here. That is a gap and is written down as one.
#
#   tests/conformance.sh            both drivers, or whichever is runnable here
#
# The PowerShell half is skipped, loudly, on a host with no pwsh; the bash half
# is always run.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'ok       %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL     %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
skip() { printf 'skip     %s\n' "$1"; SKIP=$((SKIP + 1)); }

# exits WANT NAME COMMAND... -- run it with its output thrown away and check the
# code. The code is the whole assertion: a caller's script branches on it.
exits() {
    local want="$1" name="$2"; shift 2
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "$got" == "$want" ]]; then ok "$name"; else bad "$name" "wanted exit $want, got $got"; fi
}

# --- the bash driver --------------------------------------------------------

# Read out of the driver rather than repeated here, exactly as the PowerShell
# list is below: a module added there is then tested here without an edit, and a
# list that has to be kept in step by hand is a list that stops being in step.
# shellcheck source=/dev/null
BASH_MODULES=($(source "$ROOT/modules/parser" >/dev/null 2>&1; printf '%s ' "${MODULES[@]}"))
(( ${#BASH_MODULES[@]} )) || { bad 'read MODULES out of modules/parser'; }

printf '\n-- virutil (bash driver) --\n'
exits 0 'virutil help'            bash "$ROOT/virutil" help
exits 0 'virutil --help'          bash "$ROOT/virutil" --help
exits 1 'virutil (no arguments)'  bash "$ROOT/virutil"
exits 1 'virutil nosuchmodule'    bash "$ROOT/virutil" nosuchmodule
for m in "${BASH_MODULES[@]}"; do
    exits 0 "virutil $m -h"     bash "$ROOT/virutil" "$m" -h
    exits 0 "virutil $m --help" bash "$ROOT/virutil" "$m" --help
done
exits 1 'virutil domain bogus'    bash "$ROOT/virutil" domain bogus
exits 1 'virutil exec bogus VM'   bash "$ROOT/virutil" exec bogus VM

printf '\n-- payloads (bash renderer) --\n'
if diff -u "$HERE/golden/payloads.txt" <(bash "$HERE/payloads.sh" 2>&1) > /tmp/vp.bash.diff; then
    ok 'payloads render as the golden file'
else
    bad 'payloads render as the golden file' "$(head -20 /tmp/vp.bash.diff)"
fi

# --- the PowerShell driver --------------------------------------------------

PWSH="$(command -v pwsh || command -v powershell || true)"

# PowerShell cannot resolve /c/Users/... -- that is a shape only this shell
# understands, and a path in that form inside a -Command string comes back as
# "is not recognized as a name of a cmdlet". Git Bash rewrites an argument that
# looks like a lone path, which is why -File works and the dot-source below did
# not until this existed.
WROOT="$ROOT"
if [[ -n "$PWSH" ]]; then
    WROOT="$(cd "$ROOT" && { pwd -W 2>/dev/null || cygpath -w . 2>/dev/null || pwd; })"
fi

printf '\n-- virutil.ps1 (PowerShell driver) --\n'
if [[ -z "$PWSH" ]]; then
    skip 'no pwsh or powershell on PATH -- the Windows driver was not exercised'
else
    # Shorter than the bash list on purpose: snapshot, sync, push, pull and ui
    # are not ported. The list is read out of the driver itself rather than
    # repeated here, so a module added there is tested here without an edit.
    mapfile -t PS_MODULES < <("$PWSH" -NoProfile -Command \
        ". '$WROOT/modules/parser.ps1'; \$MODULES" 2>/dev/null | tr -d '\r')

    if (( ${#PS_MODULES[@]} == 0 )); then
        bad 'read $MODULES out of modules/parser.ps1'
    else
        ok "modules under test: ${PS_MODULES[*]}"
    fi

    exits 0 'virutil.ps1 help'           "$PWSH" -NoProfile -File "$ROOT/virutil.ps1" help
    exits 0 'virutil.ps1 --help'         "$PWSH" -NoProfile -File "$ROOT/virutil.ps1" --help
    exits 1 'virutil.ps1 (no arguments)' "$PWSH" -NoProfile -File "$ROOT/virutil.ps1"
    exits 1 'virutil.ps1 nosuchmodule'   "$PWSH" -NoProfile -File "$ROOT/virutil.ps1" nosuchmodule
    for m in "${PS_MODULES[@]}"; do
        exits 0 "virutil.ps1 $m -h"     "$PWSH" -NoProfile -File "$ROOT/virutil.ps1" "$m" -h
        exits 0 "virutil.ps1 $m --help" "$PWSH" -NoProfile -File "$ROOT/virutil.ps1" "$m" --help
    done
    exits 1 'virutil.ps1 domain bogus'   "$PWSH" -NoProfile -File "$ROOT/virutil.ps1" domain bogus
    exits 1 'virutil.ps1 exec bogus VM'  "$PWSH" -NoProfile -File "$ROOT/virutil.ps1" exec bogus VM

    # Each of these needs a scratch VIRUTILS_DIR of its own and has to take it
    # away again, so they run as their own scripts rather than inline.
    #
    #   domain.ps1  the launcher is the domain: modules/domain.ps1 keeps no
    #               state beside the per-VM .cmd, so reading one back is a
    #               contract the file has with itself.
    #   exec.ps1    the guest's exit code becomes virutil's (contract section 5)
    #               -- including for a process killed by a signal, where
    #               qemu-ga sends no exitcode at all.
    #   usb.ps1     an attach is a line in that same launcher, inserted
    #               into the middle of it rather than appended.
    printf '\n-- PowerShell unit tests --\n'
    for t in domain exec usb; do
        if out="$("$PWSH" -NoProfile -File "$ROOT/tests/$t.ps1" 2>&1)"; then
            printf '%s\n' "$out" | sed 's/^/  /'
            ok "tests/$t.ps1"
        else
            printf '%s\n' "$out" | sed 's/^/  /'
            bad "tests/$t.ps1"
        fi
    done

    printf '\n-- payloads (both renderers) --\n'
    # The one that matters. Both drivers are compared against the same golden
    # file, so this fails when either renderer drifts -- a quoting rule that
    # stops matching, a placeholder filled differently, a comment line stripped
    # by one and not the other. There is no shared code to make it true.
    if "$PWSH" -NoProfile -File "$ROOT/tests/payloads.ps1" 2>/tmp/vp.ps.err | \
       diff -u "$HERE/golden/payloads.txt" - > /tmp/vp.ps.diff; then
        ok 'PowerShell renderer agrees with the golden file, byte for byte'
    else
        bad 'PowerShell renderer agrees with the golden file, byte for byte' \
            "$(head -20 /tmp/vp.ps.diff /tmp/vp.ps.err)"
    fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
