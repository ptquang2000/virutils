# mount, Linux guest. Sent by `virutil push`, `pull` and `sync` on a Windows
# *host*, immediately before the payload that moves the bytes, and paired with
# unmount.sh afterwards. The Linux counterpart of win/mount.ps1, and keyed on
# the host for the same reason: a Linux host serves an rsync daemon the guest
# reaches by URL and sends neither.
#
#   @UNC@    the share to mount, //ADDR/<share>
#   @USER@   the throwaway local account the host minted for this transfer
#   @PASS@   its password
#   @MNT@    where it is mounted, a directory of this transfer's own
#
# A Windows host has no rsync daemon to offer and does have an SMB server, so
# the share the Windows guest is given is mounted here and the copier payloads
# are handed the mount point where a Linux host hands them a daemon URL. They
# are the same payloads byte for byte: rsync takes a path as readily as a URL.
#
# mount.cifs is cifs-utils, and it is asked for by name before anything else
# so its absence reads as that rather than as mount's "wrong fs type, bad
# option, bad superblock" (exit 32), which names three things it is not.
#
# **Whatever an earlier transfer left mounted is let go first**, as mount.ps1
# drops stale sessions: a run that died between its mount and its unmount
# leaves a mount of a share the host has since taken away, and every path under
# it hangs until the client gives up. Lazily, because a dead share cannot be
# unmounted any other way.
#
# The password goes through a credentials file rather than onto mount's
# command line, where it would sit in /proc for the life of the helper. The
# file is made 0600 by the umask, on /run where there is one, and removed
# whether the mount worked or not.
#
# file_mode and dir_mode are 0755 and that is a choice with a cost: NTFS
# carries no mode, the copiers preserve the source's, so every file delivered
# from a Windows host arrives executable. The other choice, 0644, delivers a
# build whose binaries will not run, and rewrites a 0755 file already in the
# guest to 0644 the next time it is pushed. mfsymlinks so that a pull of a tree
# holding a symlink does not fail on it: the link is written as a stub file,
# which the host takes back out and names (Remove-PullLinkStubs). nobrl because
# rsync asks for no byte-range locks and a Windows server charges for them.
#
# Prints: "ok".
command -v mount.cifs >/dev/null 2>&1 || {
  echo "cifs-utils is not installed in this guest (no mount.cifs)" >&2
  exit @@RC_NO_CIFS@@
}
unc=@UNC@
mnt=@MNT@
for m in "$(dirname "$mnt")"/*; do
  [ -d "$m" ] || continue
  umount -l "$m" 2>/dev/null || true
  rmdir "$m" 2>/dev/null || true
done
mkdir -p "$mnt"
umask 077
if [ -d /run ]; then cred=$(mktemp -p /run); else cred=$(mktemp); fi
printf 'username=%s\npassword=%s\n' @USER@ @PASS@ > "$cred"
rc=0
mount -t cifs "$unc" "$mnt" -o "credentials=$cred,uid=0,gid=0,file_mode=0755,dir_mode=0755,mfsymlinks,nobrl" || rc=$?
rm -f "$cred"
if [ "$rc" != 0 ]; then
  rmdir "$mnt" 2>/dev/null || true
  echo "mount -t cifs $unc failed with exit $rc" >&2
  exit 1
fi
echo ok
