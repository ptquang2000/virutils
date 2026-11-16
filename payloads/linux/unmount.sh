# unmount, Linux guest. The other half of mount.sh: sent by `virutil push`,
# `pull` and `sync` on a Windows host once the copier payload has finished.
#
#   @MNT@    the mount point mount.sh made
#
# Best effort, and it exits 0 whatever happens, as win/unmount.ps1 does and for
# its reason: the next transfer's mount.sh lets go of whatever this one left,
# so a failure here costs nothing, and reporting it would turn a copy that
# landed into a command that says it did not.
#
# Prints: "ok".
mnt=@MNT@
umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
rmdir "$mnt" 2>/dev/null || true
echo ok
