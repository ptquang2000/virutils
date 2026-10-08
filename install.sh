#!/usr/bin/env bash
# install.sh -- put virutil on PATH and its zsh completion on fpath.
#
# virutil resolves its module directory through the symlink, so this links the
# driver rather than copying it: the checkout stays the source of truth.
#
#   ./install.sh                 link into ~/.local/bin and the zsh site-functions dir
#   ./install.sh --check         report on dependencies and exit
#   ./install.sh --uninstall     remove the links this script made
#   ./install.sh --qemu          macOS: build the qemu that boots Windows on Arm
set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

# The qemu --qemu builds. The version is pinned because patches/qemu/ is written
# against its source. The checksum is of the tarball as served by
# download.qemu.org over HTTPS; its GPG signature was not checked, there being
# no gpg on the host it was pinned from.
QEMU_VERSION=11.1.1
QEMU_SHA256=079ffbff8a7111bbc89022107cbabf3bbfd614d5fc9d7cc675991196aca12482

BIN="${BIN:-$HOME/.local/bin}"
COMP_DIR="${COMP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions}"
DO_COMPLETIONS=1
ACTION=install

usage() {
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//'
    cat <<EOF

Options:
  --bin DIR           where to link virutil       (default: $HOME/.local/bin)
  --completions DIR   where to link _virutil      (default: \${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions)
  --no-completions    skip the zsh completion
  --check             only report on host dependencies
  --uninstall         remove the links, leave the checkout alone
  --qemu              macOS only: build qemu $QEMU_VERSION with patches/qemu/ into
                      \$VIRUTILS_CACHE_DIR/qemu, which the macOS driver prefers
                      to the qemu on PATH (stock qemu cannot boot Windows on Arm)
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
        --qemu)           ACTION=qemu; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

# --- dependencies ------------------------------------------------------------
#
# Nothing here is fatal: the modules are independent, so the check reports per
# module and leaves the judgement to whoever is reading.

have() { command -v "$1" >/dev/null 2>&1; }

# "module|command command ..." -- one line per group in `virutil help`. A Mac
# runs modules/mac, which has no libvirt and fewer modules, so it has a list of
# its own.
if [[ "$(uname -s)" == Darwin ]]; then
    REQUIRED=(
        "core            |nc jq"
        "domain snapshot |qemu-system-aarch64 qemu-img swtpm"
        "exec            |iconv"
    )
    OPTIONAL=()
else
    REQUIRED=(
        "core            |virsh awk"
        "sync pull push  |rsync sudo smbd ss"
        "domain          |virt-install virt-xml qemu-img"
        "exec            |jq python3"
    )
    OPTIONAL=(
        "domain: TPM 2.0 device, which a stock Windows 11 installer requires|swtpm"
        "domain: detecting --osinfo from an install ISO|osinfo-detect"
        "domain: fixing ISO permissions under a 0700 home|setfacl"
        "domain port: the relay that carries a guest port to the host|socat"
    )
fi

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

    for entry in ${OPTIONAL[@]+"${OPTIONAL[@]}"}; do
        mod="${entry%%|*}"; cmds="${entry##*|}"
        for cmd in $cmds; do
            have "$cmd" || warn "optional: $cmd not found -- no $mod"
        done
    done

    if [[ "$(uname -s)" == Darwin ]]; then
        # /bin/bash is 3.2 there, and virutil hands itself to a newer one it
        # finds at Homebrew's prefix; without one it stops at the first line.
        if [[ -x /opt/homebrew/bin/bash || -x /usr/local/bin/bash ]]; then
            ok "bash 4+ -- ok"
        else
            warn "core -- missing: bash 4 or newer (brew install bash)"
            missing_any=1
        fi
        if have qemu-system-aarch64 \
           && ! grep -qx hvf <<<"$(qemu-system-aarch64 -accel help 2>/dev/null || true)"; then
            warn "qemu-system-aarch64 has no hvf accelerator -- virutil domain cannot start a guest"
            missing_any=1
        fi
        local own="${VIRUTILS_CACHE_DIR:-${VIRUTILS_DIR:-$HOME/.virutils}/cache}/qemu"
        if grep -qx hvf-smc-windows "$own/VIRUTIL_PATCHES" 2>/dev/null; then
            ok "qemu for Windows on Arm -- ok ($own)"
        else
            warn "no patched qemu in $own -- stock qemu cannot boot Windows on Arm" \
                 "under hvf. Build it with: ./install.sh --qemu"
        fi
    else
        [[ -e /dev/kvm ]] || warn "no /dev/kvm -- virutil domain cannot start a guest (nested virtualisation, under WSL2)"
        if have id && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx libvirt; then
            warn "$USER is not in the libvirt group -- qemu:///system will prompt or fail"
        fi
    fi

    return $missing_any
}

# --- a qemu that boots Windows on Arm (macOS) -------------------------------
#
# Stock qemu under hvf answers an SMC it does not recognise with an undefined
# instruction exception, and Windows on Arm issues one (0xc3000001) at boot and
# parks its boot CPU on it: the installer never gets past the firmware logo.
# modules/mac/qemu records how that was found. UTM's qemu carries a one-line
# patch for it; this builds qemu with the same patch, patches/qemu/, into
# $VIRUTILS_CACHE_DIR/qemu -- which the macOS driver prefers to anything on
# PATH. Homebrew's qemu is left alone, and still provides the libraries this
# build links against.
#
# QEMU_VERSION and QEMU_SHA256 are at the top of this file.

build_qemu() {
    local root prefix work src log brewp p t names=()
    [[ "$(uname -s)" == Darwin ]] \
        || { err "--qemu builds the macOS driver's qemu, and this is not a Mac"; return 1; }
    for t in curl tar patch shasum ninja pkg-config python3; do
        have "$t" || { err "--qemu needs $t (brew install ninja pkgconf python)"; return 1; }
    done
    have qemu-system-aarch64 \
        || warn "no Homebrew qemu: 'brew install qemu' first brings the libraries this build links against"

    root="${VIRUTILS_DIR:-$HOME/.virutils}"
    prefix="${VIRUTILS_CACHE_DIR:-$root/cache}/qemu"
    log="${VIRUTILS_CACHE_DIR:-$root/cache}/qemu-build.log"
    brewp="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/virutil-qemu.XXXXXX")"
    trap 'rm -rf -- "$work"' RETURN
    mkdir -p "$(dirname "$log")"
    : > "$log"

    log "downloading qemu $QEMU_VERSION"
    curl -fL --progress-bar -o "$work/qemu.tar.xz" \
        "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz" || { err "download failed"; return 1; }
    [[ "$(shasum -a 256 "$work/qemu.tar.xz" | cut -d' ' -f1)" == "$QEMU_SHA256" ]] \
        || { err "qemu-$QEMU_VERSION.tar.xz does not match its pinned checksum"; return 1; }
    tar -xf "$work/qemu.tar.xz" -C "$work"
    src="$work/qemu-$QEMU_VERSION"

    for p in "$HERE"/patches/qemu/*.patch; do
        [[ -f "$p" ]] || continue
        patch -d "$src" -p1 --forward --quiet < "$p" \
            || { err "$(basename "$p") does not apply to qemu $QEMU_VERSION"; return 1; }
        names+=("$(basename "$p" .patch)")
        ok "patched: $(basename "$p")"
    done

    # pvg (the macOS paravirtualized-graphics device) is off because its source
    # uses APIs the macOS 27 SDK has removed, and the driver does not use it.
    log "configuring and building (a few minutes; log in $log)"
    mkdir -p "$src/build"
    if ! ( cd "$src/build" && ../configure --prefix="$prefix" \
             --target-list=aarch64-softmmu --enable-hvf --enable-cocoa \
             --enable-slirp --enable-png --enable-tools --disable-pvg \
             --disable-docs --disable-gtk --disable-sdl --disable-werror \
             --disable-debug-info \
             --extra-cflags="-I$brewp/include" --extra-ldflags="-L$brewp/lib" \
             && ninja ) >> "$log" 2>&1; then
        tail -20 "$log" >&2
        err "the qemu build failed; the whole log is $log"
        return 1
    fi

    # A domain running on the old build keeps its open binary and firmware:
    # the files go, the inodes stay until that qemu exits.
    rm -rf -- "$prefix"
    ninja -C "$src/build" install >> "$log" 2>&1 || { err "ninja install failed; see $log"; return 1; }
    printf '%s\n' "${names[@]}" > "$prefix/VIRUTIL_PATCHES"
    ok "qemu $QEMU_VERSION with ${names[*]:-no patches} in $prefix"
    log "domains created from now on use it; an existing domain keeps the qemu its"
    log "launcher names until it is recreated, or its exec line is edited by hand"
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
    (( DO_COMPLETIONS )) && link "$HERE/completions/linux/_virutil" "$COMP_DIR/_virutil"

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
    unlink_ours "$COMP_DIR/_virutil" "$HERE/completions/linux/_virutil"
}

case "$ACTION" in
    check)
        check_deps || exit 1
        ;;
    qemu)
        build_qemu || exit 1
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
