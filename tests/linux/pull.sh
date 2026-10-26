#!/usr/bin/env bash
# tests/linux/pull.sh -- where modules/linux/pull puts what the guest sent.
#
# The transport is substituted: no smbd, no rsyncd, no guest. The module is
# sourced the way the driver sources it, and then the serve, the fetch and the
# routing are replaced, so the "guest" is a function that writes into whatever
# directory pull served. What is asserted is the shape rule, which is push's:
#
#   * one file into a DST that does not exist, with no trailing slash, is
#     that file -- out/run.json used to come back as a directory named
#     run.json with run.json inside it;
#   * an existing directory, a trailing slash, or a wildcard SRC means DST is
#     a directory, and the file goes inside;
#   * a directory source lands inside DST, whatever DST is called;
#   * nothing is left beside DST either way.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0 FAIL=0
ok()   { printf 'ok       %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL     %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi; }

if [[ "$(uname -s)" == Darwin ]]; then
    printf 'skip     modules/linux/pull is not the tree a Mac runs\n\n0 passed, 0 failed, 1 skipped\n'
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
export VIRUTILS_DIR="$WORK/root"

# What pull runs, against the stubs below. Each call is its own subshell: pull
# exits on failure, and its traps are its own.
pulls() {
    (
        M="$ROOT/modules/linux"
        # shellcheck source=/dev/null
        source "$M/parser"
        # The driver's order: the shared libraries, then the command modules.
        for f in "$M"/*; do
            n="${f##*/}"
            [[ "$n" == parser || " ${MODULES[*]} " == *" $n "* ]] || source "$f"
        done
        for n in "${MODULES[@]}"; do source "$M/$n"; done
        domain_exists()  { :; }
        guest_os()       { printf 'windows'; }
        xfer_check()     { :; }
        domain_ip()      { printf '192.0.2.10'; }
        xfer_host_addr() { printf '192.0.2.1'; }
        pull_net_serve() { SERVED="$1"; }
        pull_net_fetch() { guest_copies "$SERVED"; printf '1 0 5'; }
        xfer_stop()      { :; }
        now_ms()         { printf '0'; }
        pull_main "$@"
    ) >/dev/null 2>&1
}

# The guest: one file, or one directory, into the share.
one_file() { printf '{"ok":true}\n' > "$1/restore-success.json"; }
one_dir()  { mkdir -p "$1/logs" && printf 'a\n' > "$1/logs/a.log"; }

cd "$WORK"
export -f one_file one_dir

guest_copies() { one_file "$@"; }; export -f guest_copies
pulls vm 'uat/restore-success.json' ev/restore-success.json
check 'one file into a DST that does not exist is that file' file \
    "$( [[ -f ev/restore-success.json ]] && echo file || { [[ -d ev/restore-success.json ]] && echo directory || echo nothing; } )"
check '  with the bytes the guest sent' '{"ok":true}' "$(cat ev/restore-success.json 2>/dev/null)"
check '  and nothing left beside it' 0 "$(find ev -name '.virutil-pull-*' | wc -l | tr -d ' ')"

pulls vm 'uat/restore-success.json' ev/renamed.json
check 'one file to another name renames it' file "$( [[ -f ev/renamed.json ]] && echo file )"

mkdir -p into
pulls vm 'uat/restore-success.json' into
check 'one file into an existing directory goes inside it' file "$( [[ -f into/restore-success.json ]] && echo file )"

pulls vm 'uat/restore-success.json' slashed.json/
check 'a trailing slash makes DST a directory, even named like a file' file \
    "$( [[ -f slashed.json/restore-success.json ]] && echo file )"

pulls vm 'uat/*.json' globbed.json
check 'a wildcard SRC always fills a directory' file "$( [[ -f globbed.json/restore-success.json ]] && echo file )"

guest_copies() { one_dir "$@"; }; export -f guest_copies
pulls vm 'uat/logs' dirdst.json
check 'a directory SRC lands inside a DST that did not exist' file "$( [[ -f dirdst.json/logs/a.log ]] && echo file )"
check '  which is not left at mktemp'"'"'s 0700' "$(umask -S)" "$(stat -c %A dirdst.json | awk '{
    printf "u=%s,g=%s,o=%s", gensub(/-/, "", "g", substr($0,2,3)), gensub(/-/, "", "g", substr($0,5,3)), gensub(/-/, "", "g", substr($0,8,3)) }')"
check 'nothing is left beside any DST' 0 "$(find . -name '.virutil-pull-*' | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
