# pull, Linux guest. Sent by `virutil pull`: the host serves a writable rsync
# module and the guest copies matches of the pattern out into it.
#
#   @SRC@   the pattern to match in the guest, an absolute path
#   @DST@   the daemon URL of the served directory, with its trailing slash
#
# The globbing is the whole design problem. The pattern has to be expanded by
# the guest, and the obvious way -- writing it into the script as source, where
# the shell can see it -- makes every pattern shell source, so a path with a
# space word-splits and one with a `;` runs. The way out is that field splitting
# and pathname expansion are separate steps, and only the first reads IFS: with
# IFS empty, `set -- $pat` splits into no fields, and the glob still expands to
# one field per match. So the pattern travels as data in a quoted variable,
# whatever is in it, and still globs.
#
# The match is case-sensitive, because it is the guest's own shell doing it --
# where the Windows payload leans on Windows matching case-insensitively. A
# Linux guest has no case-insensitive matching to borrow, and inventing one
# would be a worse surprise than the plain shell behaviour.
#
# Only pathname expansion happens, and a glob only ever yields paths that exist,
# so the one arrangement in which an argument can be missing is a pattern that
# matched nothing and was left as its own literal text. That is exactly the
# no-match case, and it is detected here rather than handed to rsync, which
# would report it as a partial transfer.
#
# Prints: "<files> <dirs> <ms>".
@@PROBE@@
pat=@SRC@
dst=@DST@
oldifs=$IFS; IFS=""; set -- $pat; IFS=$oldifs
if [ $# -eq 1 ] && [ ! -e "$1" ] && [ ! -L "$1" ]; then
  echo "no match for $pat" >&2
  exit @@RC_PULL_NOMATCH@@
fi
nf=0 nd=0
for f do
  if [ -d "$f" ] && [ ! -L "$f" ]; then nd=$((nd+1)); else nf=$((nf+1)); fi
done
t0=$(date +%s%N)
rsync -rlptD "$@" "$dst"
t1=$(date +%s%N)
echo "$nf $nd $(( (t1 - t0) / 1000000 ))"
