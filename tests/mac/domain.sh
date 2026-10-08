#!/usr/bin/env bash
# tests/mac/domain.sh -- the macOS driver against a real hvf domain with no OS.
#
# What tests/win/domain.ps1 is to the Windows driver, and more, because a guest
# with no OS in it is still a real qemu under hvf: a blank "ISO" the firmware
# cannot boot leaves the domain sitting in the UEFI shell, which is all that
# domain, port and snapshot need. What it cannot reach is anything inside a
# guest -- exec, and shutdown's agent path -- which need Windows and qemu-ga.
#
# Everything happens under a scratch VIRUTILS_DIR that is removed at the end,
# along with any qemu it started. Needs the macOS driver's own dependencies;
# skips, loudly, on any other host.
#
#   tests/mac/domain.sh
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
for t in qemu-system-aarch64 qemu-img swtpm jq; do
    command -v "$t" >/dev/null || { printf 'skip     no %s on PATH\n' "$t"; exit 0; }
done

# TMPDIR, not /tmp: macOS's per-user temp directory, and short enough that the
# deepest socket (images/VM.tpm/swtpm.sock) stays under the 104-byte cap.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/vu.XXXXXX")"
export VIRUTILS_DIR="$SCRATCH/v"
unset VIRUTILS_IMAGE_DIR VIRUTIL_IMAGE_DIR VIRUTILS_VIRTIO
IMG="$VIRUTILS_DIR/images"
VM=probe

cleanup() {
    local pid
    pid="$(cat "$IMG/$VM.pid" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    sleep 0.5
    rm -rf -- "$SCRATCH"
}
trap cleanup EXIT

# run NAME WANT COMMAND... -- the exit code is the assertion; output is kept
# for the line that fails.
OUT=""
run() {
    local name="$1" want="$2"; shift 2
    local got=0
    OUT="$("$@" 2>&1)" || got=$?
    if [[ "$got" == "$want" ]]; then ok "$name"; else bad "$name" "wanted exit $want, got $got: $(head -3 <<<"$OUT")"; fi
}

check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

state() { "$V" domain list 2>/dev/null | awk -v vm="$VM" '$1 == vm { $1 = ""; sub(/^ /, ""); print }'; }

# swtpm processes serving this domain's TPM. qemu takes swtpm down with it
# when it exits (--terminate), so a shut-off domain has none -- and one left
# behind is a leak that outlives the test.
swtpms() { pgrep -f -- "tpmstate dir=$IMG/$VM.tpm" | wc -l | tr -d ' '; }

# A hard stop for the tests that need a shut-off domain. Not `domain shutdown`:
# the UEFI shell does not act on the ACPI power button, and there is no agent.
# Every stop also asserts that swtpm went with qemu.
stop() {
    kill "$(cat "$IMG/$VM.pid")" 2>/dev/null
    local i
    for (( i = 0; i < 50; i++ )); do [[ -f "$IMG/$VM.pid" ]] || break; sleep 0.1; done
    for (( i = 0; i < 20; i++ )); do [[ "$(swtpms)" == 0 ]] && break; sleep 0.1; done
    check "swtpm exited with qemu ($1)" '[[ "$(swtpms)" == 0 ]]' "still running: $(swtpms)"
}

dd if=/dev/zero of="$SCRATCH/blank-arm64.iso" bs=1048576 count=8 2>/dev/null

printf '\n-- create --\n'
run 'domain create -N' 0 "$V" domain create "$VM" "$SCRATCH/blank-arm64.iso" -s 4 -m 2048 -c 2 -v none -N
# Contract section 8: create leaves exactly the files section 3 names.
check 'create leaves exactly disk, nvram, launcher and TPM dir' \
    '[[ "$(cd "$IMG" && ls -A | sort | tr "\n" " ")" == "$VM.qcow2 $VM.sh $VM.tpm ${VM}_VARS.qcow2 " ]]' \
    "found: $(cd "$IMG" 2>/dev/null && ls -A | tr '\n' ' ')"
check 'the launcher is marked as a domain' 'grep -q "^# virutil domain: $VM" "$IMG/$VM.sh"'
# Its own hardware identity: qemu's defaults make every guest the same machine,
# and a Windows guest on them was handed another organisation's Autopilot
# enrolment (modules/mac/domain says how).
check 'it has its own SMBIOS UUID and serial' \
    'grep -qE "^    -uuid [0-9a-f-]{36} " "$IMG/$VM.sh" && grep -qE "^    -smbios type=1,serial=VU[0-9A-F]+ " "$IMG/$VM.sh"'
check 'its own MAC' 'grep -qE "virtio-net-pci,netdev=net0,mac=52:54:00:[0-9a-f:]{8} " "$IMG/$VM.sh"'
check 'and its own NVMe serial, not a fixed one' \
    'grep -qE "nvme,drive=disk0,serial=VU[0-9A-F]+," "$IMG/$VM.sh" && ! grep -q "serial=disk0" "$IMG/$VM.sh"'
check 'the nvram is qcow2 (a raw one blocks snapshots)' \
    '[[ "$(qemu-img info --output=json "$IMG/${VM}_VARS.qcow2" | jq -r .format)" == qcow2 ]]'
# 13389, or the next free port when a real domain on this host already has it.
RDP="$(grep -oE 'hostfwd=tcp:127\.0\.0\.1:[0-9]+-:3389' "$IMG/$VM.sh" | sed -E 's/.*:([0-9]+)-:3389/\1/')"
check 'the default RDP forward binds 127.0.0.1' '[[ -n "$RDP" ]]'
check 'on a port nothing is listening on' '! nc -z -G 1 127.0.0.1 "$RDP" 2>/dev/null'
check 'list says shut off' '[[ "$(state)" == "shut off" ]]' "got: $(state)"
run 'create refuses an existing domain' 1 "$V" domain create "$VM" "$SCRATCH/blank-arm64.iso" -v none -N
run 'create refuses a name that needs quoting' 1 "$V" domain create 'a b' "$SCRATCH/blank-arm64.iso" -v none -N

printf '\n-- start --\n'
run 'domain start -G' 0 "$V" domain start "$VM" -G
check 'list says running' '[[ "$(state)" == running ]]' "got: $(state)"
check 'QMP and agent sockets exist' '[[ -S "$IMG/$VM.qmp" && -S "$IMG/$VM.qga" ]]'
run 'start on a running domain is not an error' 0 "$V" domain start "$VM"
run '-c on a running domain is refused' 1 "$V" domain start "$VM" -c 3
run 'delete refuses a running domain' 1 "$V" domain delete "$VM"

printf '\n-- port --\n'
run 'port add 2222:22' 0 "$V" domain port "$VM" 2222:22
check 'the forward is in the launcher' 'grep -q "hostfwd=tcp:127.0.0.1:2222-:22" "$IMG/$VM.sh"'
check 'qemu is listening on 127.0.0.1:2222' 'lsof -nP -iTCP@127.0.0.1:2222 -sTCP:LISTEN >/dev/null 2>&1'
run 'a duplicate host port is refused' 1 "$V" domain port "$VM" 2222
run 'port -c 2222' 0 "$V" domain port "$VM" -c 2222
check 'the forward is gone from the launcher' '! grep -q "2222-:22" "$IMG/$VM.sh"'
check 'and from qemu' '! lsof -nP -iTCP@127.0.0.1:2222 -sTCP:LISTEN >/dev/null 2>&1'
run 'domain addr' 0 "$V" domain addr "$VM"
check 'addr prints the forward' 'grep -q "127.0.0.1:$RDP -> guest:3389" <<<"$OUT"'

# A start qemu refuses -- here, a forward on a port the running domain holds --
# must fail by name and take its swtpm with it: qemu died before connecting to
# it, so swtpm's own --terminate never fires.
run 'a second domain on a held port is created' 0 \
    "$V" domain create probe2 "$SCRATCH/blank-arm64.iso" -s 1 -m 2048 -c 2 -v none -N -p "$RDP:3389"
check 'two domains never share a MAC' \
    '[[ "$(grep -oE "mac=[0-9a-f:]+" "$IMG/$VM.sh")" != "$(grep -oE "mac=[0-9a-f:]+" "$IMG/probe2.sh")" ]]'
run 'and fails to start' 1 "$V" domain start probe2 -G
check 'saying why' 'grep -q "Could not set up host forwarding" <<<"$OUT"' "$(head -5 <<<"$OUT")"
check 'leaving no swtpm behind' '! pgrep -f -- "tpmstate dir=$IMG/probe2.tpm" >/dev/null'
run 'probe2 deleted' 0 "$V" domain delete probe2

printf '\n-- snapshot --\n'
snap_state() { "$V" snapshot list "$VM" 2>/dev/null | awk -v s="$1" '$1 == s { print $NF }'; }
run 'snapshot create while running' 0 "$V" snapshot create "$VM" live
check 'it holds memory' '[[ "$(snap_state live)" == running ]]' "got: $(snap_state live)"
run 'a duplicate name is refused' 1 "$V" snapshot create "$VM" live
run 'revert to memory, running' 0 "$V" snapshot revert "$VM" live
check 'still running after' '[[ "$(state)" == running ]]' "got: $(state)"
stop 'after a running revert'
run 'snapshot create while shut off' 0 "$V" snapshot create "$VM" cold
check 'it is disk-only' '[[ "$(snap_state cold)" == shutoff ]]' "got: $(snap_state cold)"
check 'the TPM state was copied beside it' \
    '[[ ! -f "$IMG/$VM.tpm/tpm2-00.permall" || -f "$IMG/$VM.tpm/snapshot-cold.permall" ]]'
run 'revert to memory, shut off (-S and snapshot-load)' 0 "$V" snapshot revert "$VM" live
check 'running after' '[[ "$(state)" == running ]]' "got: $(state)"
run 'revert a running domain to disk-only' 0 "$V" snapshot revert "$VM" cold
check 'running after' '[[ "$(state)" == running ]]' "got: $(state)"
run 'snapshot delete while running' 0 "$V" snapshot delete "$VM" live
stop 'after reverting to disk-only'
run 'snapshot delete while shut off' 0 "$V" snapshot delete "$VM" cold
check 'no snapshots left, in either image' \
    '[[ -z "$(qemu-img snapshot -l "$IMG/$VM.qcow2")$(qemu-img snapshot -l "$IMG/${VM}_VARS.qcow2")" ]]'
check 'and no TPM copy' '[[ ! -e "$IMG/$VM.tpm/snapshot-cold.permall" ]]'
run 'revert to a snapshot that is not there' 1 "$V" snapshot revert "$VM" nosuch

printf '\n-- edits --\n'
run 'start -c 3 -m 3072 -s 5 -G' 0 "$V" domain start "$VM" -c 3 -m 3072 -s 5 -G
check 'the launcher says -smp 3' 'grep -q "^    -smp 3,sockets=1,cores=3,threads=1 " "$IMG/$VM.sh"'
check 'the launcher says -m 3072' 'grep -q "^    -m 3072 " "$IMG/$VM.sh"'
check 'the disk is 5 GiB' \
    '[[ "$(qemu-img info -U --output=json "$IMG/$VM.qcow2" | jq -r ".\"virtual-size\"")" == 5368709120 ]]'
stop 'after an edited start'
run 'the same values again are a no-op, not a failure' 0 "$V" domain start "$VM" -c 3 -m 3072 -G
stop 'after a no-op edit'

printf '\n-- delete --\n'
run 'domain delete' 0 "$V" domain delete "$VM"
check 'the image directory is empty' '[[ -z "$(ls -A "$IMG")" ]]' "left: $(ls -A "$IMG" | tr '\n' ' ')"
check 'no qemu or swtpm left running' '! pgrep -f "$IMG/" >/dev/null'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
