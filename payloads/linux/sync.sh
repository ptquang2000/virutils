# sync, Linux guest. Sent by `virutil sync`: one rsync of the whole served
# staging tree onto /.
#
#   @SRC@   the daemon URL of the served staging tree, with its trailing slash
#
# -rlptD rather than -a: -a adds -g and -o, and the guest runs this as root, so
# it would try to reproduce the daemon's uid and gid on every delivered file.
# What is wanted is what a package would leave behind -- root-owned, with the
# permissions the staging fetch already set.
#
# / has its own mode put back afterwards, and this is not belt-and-braces: with
# -p, rsync applies the *source* tree root's mode to the destination root, and
# the source root here is a scratch directory on the host. Getting that wrong
# once chmod'ed a guest's / to 0700, which locks every non-root user out of
# every path on the system -- the session survives because it is already
# running, and everything it tries to launch afterwards fails with EACCES. It is
# restored whether the transfer succeeded or not, because the mode of / is not
# this transfer's to change either way.
#
# rsync's own exit status has to survive, so the transfer is not the left-hand
# side of a pipeline -- grep's success there would mask an rsync failure and
# report a delivery that never happened as "0 files copied".
#
# Prints: "<copied> <ms>".
@@PROBE@@
src=@SRC@
log=$(mktemp)
rootmode=$(stat -c %a /)
t0=$(date +%s%N)
rc=0
rsync -rlptD --out-format="%i %n" "$src" / >"$log" || rc=$?
chmod "$rootmode" /
[ "$rc" = 0 ] || exit "$rc"
t1=$(date +%s%N)
n=$(grep -c "^[<>]" "$log" || true)
rm -f "$log"
echo "$n $(( (t1 - t0) / 1000000 ))"
