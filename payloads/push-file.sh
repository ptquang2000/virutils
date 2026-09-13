# push, Linux guest, single-file source. Sent by `virutil push` when SRC is a
# file: the host stages it alone in a served directory and the guest rsyncs it
# onto DST.
#
#   @SRC@   the daemon URL of the one served file
#   @DST@   where it lands in the guest, an absolute path
#
# One invocation for both shapes, where the Windows side needs two entirely
# different commands: robocopy cannot rename onto a new name, so a file push
# there goes through Copy-Item and always copies. rsync renames and skips at
# once, so a file push here is incremental where the Windows one is not -- which
# is why this prints a "did it move" count that push-file.ps1 cannot.
#
# Prints: "<copied> <bytes> <ms>".
@@PROBE@@
src=@SRC@
dst=@DST@
dir=$(dirname "$dst")
mkdir -p "$dir" || { echo "cannot create $dir" >&2; exit @@RC_PUSH_MKDIR@@; }
log=$(mktemp)
t0=$(date +%s%N)
rsync -lptD --out-format="%i %n" "$src" "$dst" >"$log"
t1=$(date +%s%N)
n=$(grep -c "^[<>]" "$log" || true)
rm -f "$log"
echo "$n $(wc -c < "$dst") $(( (t1 - t0) / 1000000 ))"
