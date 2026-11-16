#!/usr/bin/env bash
# tests/linux/payloads.sh -- render every guest-side payload with fixed inputs
# and print them all. The output is compared against tests/golden/payloads.txt.
#
# These scripts are the most carefully bisected code in the repo and there is no
# way to unit-test what they do without a guest, so what is pinned here is their
# *text*: any change to a payload, or to the way a driver interpolates one, has
# to be an intentional edit of the golden file.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$HERE/modules/linux"
source "$MODULE_DIR/parser"
for module in "$MODULE_DIR"/*; do
    name="${module##*/}"
    [[ "$name" == parser ]] && continue
    for m in "${MODULES[@]}"; do [[ "$name" == "$m" ]] && continue 2; done
    source "$module"
done
for module in "${MODULES[@]}"; do source "$MODULE_DIR/$module"; done

# The two agent entry points become "print the script and stop", so the payload
# is the observable rather than whatever a guest would have done with it.
exec_ps_text() { printf '%s\n' "$1"; }
exec_sh_text() { printf '%s\n' "$1"; }

DOMAIN=win11
GUEST_OS=windows
XFER_SMB_UNC='\\10.0.2.2\Tok3nTok3nTok3nTok3n'
XFER_RSYNCD_URL='rsync://10.0.2.2:23456/Tok3nTok3nTok3nTok3n'

# The mount pair is the one payload pair keyed on the *host* rather than on the
# guest: only a Windows host has to authenticate its share, so this driver never
# sends either of them. It renders them all the same, because that is the whole
# point of the golden file -- the two renderers have to agree on text neither of
# them is obliged to use.
XFER_MOUNT_UNC='\\10.0.2.2\k7m3qp9wr2xz'
XFER_MOUNT_USER='vxp-k7m3qp9wr2xz'
XFER_MOUNT_PASS='Pa55w0rdPa55w0rdPa55w0rd'

# The same share as a Linux guest is given it. mount.sh and unmount.sh are the
# mount pair's other half, and ui.sh is `ui` for a Linux guest: the Windows
# driver sends all three and this one renders them, for the golden file.
XFER_MOUNT_POSIX='//10.0.2.2/k7m3qp9wr2xz'
XFER_MOUNT_MNT='/run/virutil/k7m3qp9wr2xz'
US=$''

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
section 'mount.ps1'             ; payload_render mount.ps1 UNC="$XFER_MOUNT_UNC" USER="$XFER_MOUNT_USER" PASS="$XFER_MOUNT_PASS"; echo
section 'unmount.ps1'           ; payload_render unmount.ps1 UNC="$XFER_MOUNT_UNC"; echo
section 'ui.ps1 argv'           ; ui_run win11 -i 2 --elevated 'C:\Program Files\App\app.exe' "it's" --flag
section 'ui.ps1 cmdline'        ; ui_run_cmdline win11 '"C:\Program Files\App\app.exe" --restored'
section 'ui.ps1 system'         ; ui_run win11 -s notepad.exe
section 'mount.sh'               ; payload_render mount.sh UNC="$XFER_MOUNT_POSIX" USER="$XFER_MOUNT_USER" PASS="$XFER_MOUNT_PASS" MNT="$XFER_MOUNT_MNT"; echo
section 'unmount.sh'             ; payload_render unmount.sh MNT="$XFER_MOUNT_MNT"; echo
section 'ui.sh argv'             ; payload_render ui.sh SESSION=2 AS=user ARGV="/opt/My App/app${US}it's${US}--flag" CMDLINE=; echo
section 'ui.sh cmdline'          ; payload_render ui.sh SESSION= AS=user ARGV= CMDLINE='"/opt/My App/app" --restored'; echo
section 'ui.sh system'           ; payload_render ui.sh SESSION= AS=system ARGV=gnome-text-editor CMDLINE=; echo
