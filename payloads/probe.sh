# Refuse early and legibly when the guest has no rsync, rather than letting sh
# report "not found" with exit 127 and leaving the host to guess which command
# it meant. Included at the top of every .sh payload as @@PROBE@@.
#
# @@RC_NO_RSYNC@@ is distinct from every code rsync itself uses (its highest is
# in the thirties), so "the guest has no rsync" can be told apart from "rsync
# failed".
command -v rsync >/dev/null 2>&1 || {
  echo "rsync is not installed in this guest" >&2
  exit @@RC_NO_RSYNC@@
}
