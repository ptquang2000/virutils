#!/usr/bin/env bash
# install.sh -- put virutil on PATH and its zsh completion on fpath.
#
# virutil resolves its module directory from its own path *through* a symlink
# (readlink -f), so installing is a matter of linking the driver rather than
# copying it: the checkout stays the source of truth and `git pull` is the
# upgrade path.
#
#   ./install.sh                 link into ~/.local/bin and the zsh site-functions dir
#   ./install.sh --check         report on dependencies and exit
#   ./install.sh --uninstall     remove the links this script made
#
# The dotfiles setup already links $DOTS/virutils/vir* into ~/.local/bin, so
# this script is for standalone checkouts -- it is idempotent either way.
set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

BIN="${BIN:-$HOME/.local/bin}"
COMP_DIR="${COMP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions}"
DO_COMPLETIONS=1
ACTION=install

usage() {
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    cat <<EOF

Options:
  --bin DIR           where to link virutil       (default: $HOME/.local/bin)
  --completions DIR   where to link _virutil      (default: \${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions)
  --no-completions    skip the zsh completion
  --check             only report on host dependencies
  --uninstall         remove the links, leave the checkout alone
  -h, --help          this message

Both directories also read from the BIN and COMP_DIR environment variables.
EOF
}

while (( $# )); do
    case "$1" in
        --bin)            BIN="${2:?--bin needs a directory}"; shift 2 ;;
        --completions)    COMP_DIR="${2:?--completions needs a directory}"; shift 2 ;;
        --no-completions) DO_COMPLETIONS=0; shift ;;
        --check)          ACTION=check; shift ;;
        --uninstall)      ACTION=uninstall; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

# --- dependencies ------------------------------------------------------------
#
# Nothing here is fatal: the modules are independent, and a host that only ever
# runs `virutil exec` has no use for virt-install. So the check reports per
# module and leaves the judgement to whoever is reading.

have() { command -v "$1" >/dev/null 2>&1; }

# "module|command command ..." -- one line per group in `virutil help`.
REQUIRED=(
    "core            |virsh awk"
    "sync pull push  |qemu-nbd rsync sudo partx blkid blockdev lsblk mount"
    "domain          |virt-install qemu-img"
    "exec            |jq python3"
    "usb             |jq usbipd.exe powershell.exe"
)
OPTIONAL=(
    "domain: TPM 2.0 device, which a stock Windows 11 installer requires|swtpm"
    "domain: --osinfo autodetection for an install ISO|osinfo-query"
    "domain: fixing ISO permissions under a 0700 home|setfacl"
    "sync pull: NTFS volumes on the guest disk|mount.ntfs-3g"
)

check_deps() {
    local missing_any=0 entry mod cmds cmd miss

    log "Checking dependencies"
    for entry in "${REQUIRED[@]}"; do
        mod="${entry%%|*}"; cmds="${entry##*|}"
        miss=()
        for cmd in $cmds; do
            have "$cmd" || miss+=("$cmd")
        done
        if (( ${#miss[@]} )); then
            warn "$mod -- missing: ${miss[*]}"
            missing_any=1
        else
            ok "$mod -- ok"
        fi
    done

    for entry in "${OPTIONAL[@]}"; do
        mod="${entry%%|*}"; cmds="${entry##*|}"
        for cmd in $cmds; do
            have "$cmd" || warn "optional: $cmd not found -- no $mod"
        done
    done

    # The nbd module backs every qemu-nbd mount; sync reloads it with max_part
    # itself, but a host that cannot load it at all will fail late instead of here.
    if [[ ! -e /sys/module/nbd ]] && ! modinfo nbd >/dev/null 2>&1; then
        warn "the nbd kernel module is unavailable -- sync, pull and push need it"
        missing_any=1
    fi
    [[ -e /dev/kvm ]] || warn "no /dev/kvm -- virutil domain cannot start a guest (nested virtualisation, under WSL2)"
    if have id && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx libvirt; then
        warn "$USER is not in the libvirt group -- qemu:///system will prompt or fail"
    fi

    return $missing_any
}

# --- linking -----------------------------------------------------------------

link() {
    local src="$1" dest="$2"

    if [[ ! -e "$src" ]]; then
        warn "skip, source missing: $src"
        return 0
    fi
    if [[ "$(readlink "$dest" 2>/dev/null)" == "$src" ]]; then
        log "already linked: $dest"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    if [[ -e "$dest" || -L "$dest" ]]; then
        log "backing up $dest -> $dest.bak.$STAMP"
        mv "$dest" "$dest.bak.$STAMP"
    fi
    ln -sfn "$src" "$dest"
    ok "linked $dest -> $src"
}

unlink_ours() {
    local dest="$1" src="$2"

    if [[ ! -L "$dest" ]]; then
        [[ -e "$dest" ]] && warn "not a symlink, leaving alone: $dest"
        return 0
    fi
    if [[ "$(readlink "$dest")" != "$src" ]]; then
        warn "points elsewhere, leaving alone: $dest -> $(readlink "$dest")"
        return 0
    fi
    rm -f "$dest"
    ok "removed $dest"
}

install_links() {
    link "$HERE/virutil" "$BIN/virutil"
    (( DO_COMPLETIONS )) && link "$HERE/completions/_virutil" "$COMP_DIR/_virutil"

    case ":$PATH:" in
        *":$BIN:"*) ;;
        *) warn "$BIN is not on PATH -- add: export PATH=\"$BIN:\$PATH\"" ;;
    esac
    if (( DO_COMPLETIONS )); then
        log "for completion, ensure your .zshrc has this before compinit:"
        printf '      fpath+=( "%s" )\n' "$COMP_DIR"
    fi
}

uninstall_links() {
    unlink_ours "$BIN/virutil" "$HERE/virutil"
    unlink_ours "$COMP_DIR/_virutil" "$HERE/completions/_virutil"
}

case "$ACTION" in
    check)
        check_deps || exit 1
        ;;
    uninstall)
        log "Uninstalling virutil"
        uninstall_links
        ok "Done. The checkout at $HERE is untouched."
        ;;
    install)
        log "Installing virutil from $HERE"
        install_links
        check_deps || warn "installed, but some dependencies are missing (see above)"
        ok "Done."
        ;;
esac
