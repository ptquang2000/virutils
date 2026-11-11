#!/usr/bin/env bash
# tests/linux/exec.sh -- qemu-ga's exec records on the libvirt driver: a reused
# pid never answers for another process, the ledger is reaped before each exec,
# and `exec ps -d` leaves no record (docs/qga-exec-records.md).
#
# The cases are in tests/linux/exec-records.sh, shared with the macOS tree.
# Here they run through modules/linux/exec's own agent(), with virsh
# substituted: a stand-in that hands `qemu-agent-command`'s JSON to
# tests/mac/fake-qga.pl, started with `model`, and reports an agent error the
# way virsh does ("error: internal error: unable to execute QEMU agent command
# 'guest-exec-status': PID 5512 does not exist"). Needs bash 4, jq, perl and
# iconv, and a base64 that takes -w0 (GNU's; on a Mac, Homebrew's gbase64).
#
#   tests/linux/exec.sh
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
M="$ROOT/modules/linux"

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
trap '[[ -n "$FAKE" ]] && kill "$FAKE" 2>/dev/null; rm -rf -- "$WORK"' EXIT
export VIRUTILS_DIR="$WORK/v"
IMG="$VIRUTILS_DIR/images"
mkdir -p "$IMG" "$WORK/bin"
export PATH="$WORK/bin:$PATH"

if ! base64 -w0 </dev/null >/dev/null 2>&1; then
    command -v gbase64 >/dev/null || { printf 'skip     no base64 -w0 (GNU coreutils) here\n'; exit 0; }
    ln -s "$(command -v gbase64)" "$WORK/bin/base64"
fi

# virsh, as far as qemu-agent-command goes: the JSON to the fake, its reply
# back, and an agent error the way libvirt words it.
export FAKE_QGA_SOCK="$WORK/fake.qga"
cat > "$WORK/bin/virsh" <<'PERL'
#!/usr/bin/env perl
use strict; use warnings; use IO::Socket::UNIX; use JSON::PP;
my @a = @ARGV;
shift @a while @a && $a[0] ne 'qemu-agent-command';
shift @a; shift @a;                      # the subcommand and the domain
my $req = $a[0] // '';
my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $ENV{FAKE_QGA_SOCK})
    or do { print STDERR "error: failed to connect to the agent\n"; exit 1 };
print $s "$req\n";
my $line = <$s>;
close $s;
my $r = JSON::PP->new->decode($line);
if ($r->{error}) {
    my $cmd = eval { JSON::PP->new->decode($req)->{execute} } // '?';
    print STDERR "error: internal error: unable to execute QEMU agent command '$cmd': $r->{error}{desc}\n";
    exit 1;
}
print JSON::PP->new->canonical->encode($r), "\n";
PERL
chmod +x "$WORK/bin/virsh"

# shellcheck source=/dev/null
source "$M/parser"; source "$M/paths"; source "$M/guest"; source "$M/exec"
set +e

VM=lx
perl "$ROOT/tests/mac/fake-qga.pl" "$FAKE_QGA_SOCK" "$WORK/fake.log" model >/dev/null 2>&1 &
FAKE=$!
for (( i = 0; i < 100; i++ )); do grep -qx ready "$WORK/fake.log" 2>/dev/null && break; sleep 0.1; done

# shellcheck source=exec-records.sh
source "$HERE/exec-records.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
