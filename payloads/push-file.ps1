# push, Windows guest, single-file source. Sent by `virutil push` when SRC is a
# file: the host stages it alone in a served directory and the guest copies it
# out onto DST.
#
#   @SRC@   the UNC of the one served file, \\ADDR\<share>\<name>
#   @DST@   where it lands in the guest, an absolute C:\ path
#
# Copy-Item rather than robocopy, and it is robocopy's limitation rather than a
# preference: robocopy cannot rename onto a new name, so a file push here loses
# the skip-what-matches behaviour that is the whole point of the directory path
# above. The Linux side does not have this problem -- rsync renames and skips at
# once -- which is the one place the Linux payload is better rather than merely
# different.
#
# Prints: "<bytes> <ms>" -- the size that landed and the guest's own elapsed
# milliseconds, which is the copy alone without the agent round trip and
# powershell start-up the host's wall clock would fold in.
$ErrorActionPreference = "Stop"
$src = @SRC@
$dst = @DST@
$dir = Split-Path -Parent $dst
try { if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
catch { [Console]::Error.WriteLine($_.Exception.Message); exit @@RC_PUSH_MKDIR@@ }
$sw = [Diagnostics.Stopwatch]::StartNew()
Copy-Item -LiteralPath $src -Destination $dst -Force
$sw.Stop()
"$((Get-Item -LiteralPath $dst).Length) $([int]$sw.Elapsed.TotalMilliseconds)"
