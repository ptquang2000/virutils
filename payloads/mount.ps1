# mount, Windows guest. Sent by `virutil push` and `virutil pull` on a Windows
# *host*, immediately before the payload that moves the bytes, and paired with
# unmount.ps1 afterwards.
#
#   @UNC@    the share to authenticate to, \ADDR\<share>
#   @USER@   the throwaway local account the host minted for this transfer
#   @PASS@   its password
#
# This pair is the one place in payloads/ keyed on the **host** rather than on
# the guest, and docs/contract.md section 6 says so. Only one host has to
# authenticate: the Linux host serves an anonymous share and sends neither of
# these. A Windows host cannot -- a stock Windows guest refuses an insecure
# guest logon, and the host's own Guest account is disabled -- so the share
# carries a credential and the guest has to present it before robocopy can see
# the UNC at all.
#
# The session is SYSTEM's, not a user's: qemu-ga runs as LocalSystem, so the
# session this establishes is the same one the copier payload then reads
# through. No drive letter is mapped. A letter is a scarce global name that can
# collide with whatever the guest already has, and the copier payloads are
# written around a UNC.
#
# **Existing sessions to this server are dropped first, every time.** Windows
# permits a client exactly one identity toward a given server, whatever the
# share -- a second one fails with "System error 1219". A run that died between
# mounting and unmounting leaves SYSTEM holding a session under an account the
# host has since deleted, and every later transfer would fail at the logon for a
# reason that has nothing to do with its own credential. So this is a
# precondition of the transfer rather than tidying after one.
#
# Get-SmbConnection names the shares held against this server without parsing
# `net use`, whose output is localised. Where it is unavailable the IPC$ delete
# below is the fallback, and it is also the belt-and-braces case: a session with
# no share connection left still holds the server.
#
# **Continue, not Stop**, and this is the one payload where that is right rather
# than lax. The session drops below are expected to fail -- there is usually no
# session to drop -- and `net use` says so on stderr. Under Stop, PowerShell
# turns a native command's stderr into a terminating NativeCommandError, so the
# *successful* case of "nothing stale to clear" ended the script before it
# reached the mount, and the run reported the guest as unable to authenticate to
# a share it had never been asked about. Every statement here is checked through
# $LASTEXITCODE instead, which is what a `net use` failure actually reports.
#
# Prints: "ok".
$ErrorActionPreference = "Continue"
$unc  = @UNC@
$user = @USER@
$pass = @PASS@
$server = $unc.Split("\") | Where-Object { $_ } | Select-Object -First 1
try {
  foreach ($c in @(Get-SmbConnection -ServerName $server -ErrorAction SilentlyContinue)) {
    & net use ("\\" + $server + "\" + $c.ShareName) /delete /y 2>$null | Out-Null } } catch { }
& net use ("\\" + $server + "\IPC$") /delete /y 2>$null | Out-Null
$said = (& net use $unc $pass /user:$user 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("net use $unc /user:$user failed with exit $LASTEXITCODE")
  [Console]::Error.WriteLine($said.Trim())
  exit 1 }
"ok"
