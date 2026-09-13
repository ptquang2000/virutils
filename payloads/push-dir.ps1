# push, Windows guest, directory source. Sent by `virutil push` when SRC is a
# directory: the host serves it read-only and the guest robocopies it down.
#
#   @SRC@   the UNC of the served tree, \\ADDR\<share>
#   @DST@   where it lands in the guest, an absolute C:\ path
#
# robocopy is the whole reason this transport exists: it compares the tree the
# guest already has against the one being served and copies only what differs,
# so a second push of a build where one file changed moves one file.
#
# Its exit code is a bitmap and not an error level. 0 means nothing needed
# copying, bit 0 means files were copied, and only >= 8 is a real failure -- so
# the usual "non-zero is bad" is wrong here and would call every successful copy
# an error.
#
# The stopwatch times the copy alone. The host's own wall clock would fold in an
# agent round trip and a powershell starting up, which for a small payload is
# nearly all of it.
#
# Prints: "<copied> <total> <ms>" -- whether anything moved, how many files are
# present afterwards, and the guest's own elapsed milliseconds.
$ErrorActionPreference = "Stop"
$src = @SRC@
$dst = @DST@
try { if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Force -Path $dst | Out-Null } }
catch { [Console]::Error.WriteLine($_.Exception.Message); exit @@RC_PUSH_MKDIR@@ }
$sw = [Diagnostics.Stopwatch]::StartNew()
& robocopy $src $dst /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
$rc = $LASTEXITCODE
$sw.Stop()
if ($rc -ge 8) { [Console]::Error.WriteLine("robocopy exit $rc"); exit @@RC_PUSH_ROBO@@ }
$copied = [int][bool]($rc -band 1)
$total  = (Get-ChildItem -LiteralPath $dst -Recurse -File).Count
"$copied $total $([int]$sw.Elapsed.TotalMilliseconds)"
