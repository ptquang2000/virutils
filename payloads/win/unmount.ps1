# unmount, Windows guest. The other half of mount.ps1: sent by `virutil push`
# and `virutil pull` on a Windows host once the copier payload has finished.
#
#   @UNC@    the share to let go of, \ADDR\<share>
#
# Best effort, and it exits 0 whatever happens. The session it drops is already
# dropped again by the *next* transfer's mount.ps1, which cannot trust that this
# one ran -- the run may have been interrupted between the two. So a failure
# here costs the next transfer nothing, and reporting it as a transfer failure
# would turn a copy that landed into a command that says it did not.
#
# The host removes the account this session authenticated with seconds later,
# which is what actually retires the credential. This is the guest-side half of
# the same tidying.
#
# Prints: "ok".
$ErrorActionPreference = "Continue"
$unc = @UNC@
& net use $unc /delete /y 2>&1 | Out-Null
"ok"
