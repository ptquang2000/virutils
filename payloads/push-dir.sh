# push, Linux guest, directory source. Sent by `virutil push` when SRC is a
# directory: the host serves it from an rsync daemon and the guest pulls it down.
#
#   @SRC@   the daemon URL of the served tree, with its trailing slash
#   @DST@   where it lands in the guest, an absolute path
#
# -rlptD rather than -a: -a adds -g and -o, and the guest runs this as root, so
# it would try to reproduce the daemon's uid and gid on every delivered file.
# What is wanted is what a package would leave behind -- root-owned, with the
# permissions the source already had.
#
# The destination directory has its own mode put back afterwards, and this is
# not belt-and-braces. With -p, rsync applies the *source* tree root's mode to
# the destination root, so pushing a 0700 directory into / would chmod the
# guest's / to 0700 -- which locks every non-root user out of every path on the
# system. Modes *inside* the payload are still preserved; it is only the
# directory that was already there, and whose mode this transfer was never asked
# to change, that is left alone. Restored on failure as well as success.
#
# rsync's own exit status has to survive, so the transfer is not the left-hand
# side of a pipeline -- grep's success there would mask an rsync failure and
# report a delivery that never happened as "0 files copied".
#
# The itemised output is counted rather than parsed for a summary: rsync's
# --out-format is not localised, so the count is trustworthy in a guest of any
# language. `<` or `>` in the first column means a file's contents were
# transferred; a directory or an unchanged file shows neither.
#
# Prints: "<copied> <total> <ms>".
@@PROBE@@
src=@SRC@
dst=@DST@
mkdir -p "$dst" || { echo "cannot create $dst" >&2; exit @@RC_PUSH_MKDIR@@; }
log=$(mktemp)
dstmode=$(stat -c %a "$dst")
t0=$(date +%s%N)
rc=0
rsync -rlptD --out-format="%i %n" "$src" "$dst/" >"$log" || rc=$?
chmod "$dstmode" "$dst"
[ "$rc" = 0 ] || exit "$rc"
t1=$(date +%s%N)
n=$(grep -c "^[<>]" "$log" || true)
rm -f "$log"
total=$(find "$dst" -type f | wc -l)
echo "$n $total $(( (t1 - t0) / 1000000 ))"
