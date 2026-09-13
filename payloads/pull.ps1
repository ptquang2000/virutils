# pull, Windows guest. Sent by `virutil pull`: the host serves a writable
# directory and the guest copies matches of SRC out into it. The direction is
# the export's, not the transport's -- the guest is still the one that moves the
# bytes, because under user-mode NAT the host cannot open a connection to it.
#
#   @SRC@   the pattern to match in the guest, an absolute C:\ path
#   @DST@   the UNC of the served directory, \\ADDR\<share>
#
# Get-Item resolves SRC, wildcards and all: Windows matches them
# case-insensitively itself, which is what the contract promises for a Windows
# guest. The Linux payload borrows its guest shell's case-sensitive matching for
# the same reason.
#
# Files and directories take two different robocopy shapes, because robocopy
# always takes a source *directory*: a file is named as a filter alongside its
# parent, a directory is copied whole into a subdirectory of the share named
# after it -- which is where rsync would put it too. Files are grouped by parent
# so a wildcard spanning directories costs one robocopy per directory rather
# than one per file.
#
# robocopy's exit code is a bitmap and not an error level: 0 means nothing
# needed copying, and only >= 8 is a real failure.
#
# Prints: "<files> <dirs> <ms>".
$ErrorActionPreference = "Stop"
$src = @SRC@
$dst = @DST@
$items = @(Get-Item -Path $src -Force -ErrorAction SilentlyContinue)
if ($items.Count -eq 0) { [Console]::Error.WriteLine("no match for $src"); exit @@RC_PULL_NOMATCH@@ }
$files = @($items | Where-Object { -not $_.PSIsContainer })
$dirs  = @($items | Where-Object { $_.PSIsContainer })
$flags = @("/R:1","/W:1","/NP","/NFL","/NDL","/NJH","/NJS")
$rc = 0
$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($g in @($files | Group-Object DirectoryName)) {
  & robocopy $g.Name $dst @($g.Group | ForEach-Object { $_.Name }) @flags | Out-Null
  if ($LASTEXITCODE -ge 8) { $rc = $LASTEXITCODE } }
foreach ($d in $dirs) {
  & robocopy $d.FullName (Join-Path $dst $d.Name) /E @flags | Out-Null
  if ($LASTEXITCODE -ge 8) { $rc = $LASTEXITCODE } }
$sw.Stop()
if ($rc -ge 8) { [Console]::Error.WriteLine("robocopy exit $rc"); exit @@RC_PULL_ROBO@@ }
"$($files.Count) $($dirs.Count) $([int]$sw.Elapsed.TotalMilliseconds)"
