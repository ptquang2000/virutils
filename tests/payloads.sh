#!/usr/bin/env bash
# tests/payloads.sh -- render every guest-side payload with fixed inputs and
# print them all. The output is compared against tests/golden/payloads.txt.
#
# These scripts are the most carefully bisected code in the repo and there is no
# way to unit-test what they do without a guest, so what is pinned here is their
# *text*: any change to a payload, or to the way a driver interpolates one, has
# to be an intentional edit of the golden file.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/modules/parser"
for module in "$HERE"/modules/*; do
    name="${module##*/}"
    [[ "$name" == *.* ]] && continue
    [[ "$name" == parser ]] && continue
    for m in "${MODULES[@]}"; do [[ "$name" == "$m" ]] && continue 2; done
    source "$module"
done
for module in "${MODULES[@]}"; do source "$HERE/modules/$module"; done

# The two agent entry points become "print the script and stop", so the payload
# is the observable rather than whatever a guest would have done with it.
exec_ps_text() { printf '%s\n' "$1"; }
exec_sh_text() { printf '%s\n' "$1"; }

DOMAIN=win11
GUEST_OS=windows
XFER_SMB_UNC='\\10.0.2.2\Tok3nTok3nTok3nTok3n'
XFER_RSYNCD_URL='rsync://10.0.2.2:23456/Tok3nTok3nTok3nTok3n'

# A real directory and a real file: push branches on which SRC is.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/tree"
: > "$SCRATCH/one.txt"

section() { printf '\n===== %s =====\n' "$1"; }

section 'push.ps1 dir -> dir'   ; push_smb_fetch "$SCRATCH/tree"  'opt/app' 1
section 'push.ps1 dir/ -> dir'  ; push_smb_fetch "$SCRATCH/tree/" 'opt/app' 1
section 'push.ps1 file -> dir'  ; push_smb_fetch "$SCRATCH/one.txt" 'opt/app' 1
section 'push.ps1 file -> file' ; push_smb_fetch "$SCRATCH/one.txt" 'opt/app/two.txt' 0
section 'push.sh dir -> dir'    ; push_lin_fetch "$SCRATCH/tree"  'opt/app' 1
section 'push.sh dir/ -> dir'   ; push_lin_fetch "$SCRATCH/tree/" 'opt/app' 1
section 'push.sh file -> dir'   ; push_lin_fetch "$SCRATCH/one.txt" 'opt/app' 1
section 'push.sh file -> file'  ; push_lin_fetch "$SCRATCH/one.txt" 'opt/app/two.txt' 0
section 'pull.ps1'              ; pull_smb_fetch 'Users/me/out/*.log'
section 'pull.sh'               ; pull_lin_fetch 'home/me/out/*.log'
section 'sync.ps1'              ; sync_win_fetch
section 'sync.sh'               ; sync_lin_fetch
section 'probe.sh'              ; payload_render probe.sh; echo
