#!/usr/bin/env bash
# fake-tart.sh -- a stand-in for tart, for tests/mac/tart.sh. It keeps VMs as
# directories under $FAKE_TART_HOME/vms and answers the subcommands
# modules/mac/tart* call, in tart 2.41's output shapes.
#
# `exec` runs the command on this host, as the "guest": the agent is said to be
# root (id -u answers 0), so nothing goes through sudo, and a guest path is a
# host path. The one command it never runs is shutdown, which marks the VM
# stopped instead.
set -uo pipefail
H="${FAKE_TART_HOME:?}"
vm_dir() { printf '%s/vms/%s' "$H" "$1"; }
need()   { [[ -d "$(vm_dir "$1")" ]] || { echo "Error: the specified VM \"$1\" does not exist" >&2; exit 1; }; }
get()    { cat "$(vm_dir "$1")/$2" 2>/dev/null || printf '%s' "${3:-}"; }

cmd="${1:-}"; shift || true
case "$cmd" in
list)
    first=1; printf '['
    for d in "$H"/vms/*/; do
        [[ -d "$d" ]] || continue
        n="$(basename "$d")"
        (( first )) || printf ','
        first=0
        printf '{"Source":"local","Name":"%s","State":"%s","Running":false,"Disk":50,"Size":1}' "$n" "$(get "$n" state stopped)"
    done
    printf ']\n' ;;
get)
    need "$1"
    printf '{"CPU":%s,"Memory":%s,"Disk":%s,"OS":"%s","MACAddress":"%s","State":"%s"}\n' \
        "$(get "$1" cpu 4)" "$(get "$1" memory 8192)" "$(get "$1" disk 50)" \
        "$(get "$1" os darwin)" "$(get "$1" mac 00:00:00:00:00:01)" "$(get "$1" state stopped)" ;;
clone)
    src="$1" dst="$2"
    [[ -d "$(vm_dir "$dst")" ]] && { echo "Error: VM \"$dst\" already exists" >&2; exit 1; }
    mkdir -p "$H/vms"
    if [[ -d "$(vm_dir "$src")" ]]; then cp -R "$(vm_dir "$src")" "$(vm_dir "$dst")"
    elif [[ "$src" == */* ]]; then mkdir -p "$(vm_dir "$dst")"; echo "pulled $src" > "$(vm_dir "$dst")/image"
    else echo "Error: the specified VM \"$src\" does not exist" >&2; exit 1
    fi
    echo stopped > "$(vm_dir "$dst")/state"
    printf '02:%02x:%02x:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) > "$(vm_dir "$dst")/mac" ;;
create)
    mkdir -p "$(vm_dir "$1")"; echo stopped > "$(vm_dir "$1")/state"; echo "ipsw" > "$(vm_dir "$1")/image" ;;
delete)
    need "$1"; rm -rf "$(vm_dir "$1")" ;;
rename)
    need "$1"; mv "$(vm_dir "$1")" "$(vm_dir "$2")" ;;
set)
    vm="$1"; shift; need "$vm"
    while (( $# )); do
        case "$1" in
            --cpu)       echo "$2" > "$(vm_dir "$vm")/cpu" ;;
            --memory)    echo "$2" > "$(vm_dir "$vm")/memory" ;;
            --disk-size) echo "$2" > "$(vm_dir "$vm")/disk" ;;
            --mac)       echo "$2" > "$(vm_dir "$vm")/mac" ;;
        esac
        shift 2
    done ;;
run)
    vm="${*: -1}"; need "$vm"
    printf '%s\n' "$*" > "$(vm_dir "$vm")/run-args"
    echo running > "$(vm_dir "$vm")/state"
    trap 'echo stopped > "$(vm_dir "$vm")/state"; exit 0' TERM INT USR2
    echo "VNC server is running at vnc://:${FAKE_VNC_PASSWORD:-pw}@127.0.0.1:${FAKE_VNC_PORT:-1}"
    while [[ "$(get "$vm" state)" == running ]]; do sleep 0.1; done ;;
stop)
    need "$1"; echo stopped > "$(vm_dir "$1")/state" ;;
ip)
    need "$1"; [[ "$(get "$1" state)" == running ]] || exit 1; echo 192.168.64.9 ;;
exec)
    [[ "${1:-}" == -i ]] && shift
    vm="$1"; shift; need "$vm"
    [[ "$(get "$vm" state)" == running && ! -e "$(vm_dir "$vm")/no-agent" ]] \
        || { echo "Error: failed to connect to the guest agent" >&2; exit 1; }
    case "$*" in
        "/usr/bin/id -u") echo 0; exit 0 ;;
        *shutdown*)       echo stopped > "$(vm_dir "$vm")/state"; exit 0 ;;
    esac
    exec "$@" ;;
*)  echo "fake-tart: unexpected subcommand: $cmd $*" >&2; exit 2 ;;
esac
