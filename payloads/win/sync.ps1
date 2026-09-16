# sync, Windows guest. Sent by `virutil sync`: one robocopy of the whole served
# share onto C:\, so the staging tree the host built lands as a tree in the
# guest.
#
#   @SRC@   the UNC of the served staging tree, \\ADDR\<share>
#
# /E and not /MIR. /MIR deletes everything under the destination that the source
# does not have, and the destination here is the root of C:. Deletions are the
# cleanup rules' job, which name the directories they are allowed to empty.
#
# robocopy's exit code is a bitmap and not an error level: 0 means nothing
# needed copying, and only >= 8 is a real failure -- so the usual "non-zero is
# bad" would call every successful delivery an error.
#
# Prints: "<copied> <ms>". No file count and no byte count on purpose: robocopy
# holds them only in its summary, and that summary is localised.
$ErrorActionPreference = "Stop"
$src = @SRC@
$dst = "C:\"
$sw = [Diagnostics.Stopwatch]::StartNew()
& robocopy $src $dst /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
$rc = $LASTEXITCODE
$sw.Stop()
if ($rc -ge 8) { [Console]::Error.WriteLine("robocopy exit $rc"); exit @@RC_PUSH_ROBO@@ }
"$([int][bool]($rc -band 1)) $([int]$sw.Elapsed.TotalMilliseconds)"
