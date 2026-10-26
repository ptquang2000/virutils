# ui, Windows guest. Sent by `virutil ui run` and by sync's >pre-ui/>post-ui
# rules: start one process on a session's interactive desktop and return.
#
#   @SESSION@  target session id as text; '' = the console session
#   @AS@       'user'   -- the token of the user logged on in that session
#              'system' -- this process's own SYSTEM token, moved to it
#   @ELEVATE@  '1' = that user's full (linked) token, when UAC split it
#   @ARGV@     the argv, joined with U+001F; quoted here, by the MSVC rules
#   @CMDLINE@  a whole command line, used as written; wins over @ARGV@
#
# This is what PsExec's service, PSEXESVC, does for `-i`, done in place. Read
# out of PsExec 2.43: a primary token -- its own for -s, else the caller's --
# has TokenSessionId set (SeTcbPrivilege; -1 becomes
# WTSGetActiveConsoleSessionId), -h swaps in TokenLinkedToken when
# TokenElevationType is Limited, CreateEnvironmentBlock builds the env, and
# CreateProcessAsUserW starts it. No service and no named pipes are needed here:
# the guest agent already runs this as SYSTEM, which is all the service was for.
# 'user' is the one step PsExec does not offer without a password:
# WTSQueryUserToken returns the logged-on user's own token, already in its
# session, so the process is that user's -- their HKCU, profile and drives.
#
# lpDesktop is winsta0\default, always. Leaving it NULL makes the child inherit
# this process's service desktop, which a user token cannot open: that is the
# STATUS_DLL_INIT_FAILED (0xC0000142) a bare CreateProcessAsUser from qemu-ga
# died with.
#
# Prints: "started PID <pid> in session <n> as <DOMAIN\user>". The process is
# not waited on.
$ErrorActionPreference = "Stop"
$session = @SESSION@
$as = @AS@
$elevate = @ELEVATE@
$argv = @ARGV@
$cmdline = @CMDLINE@
Add-Type -Namespace Vu -Name Ui -UsingNamespace System.ComponentModel,System.Text,System.Security.Principal -MemberDefinition @'
[DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
[DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
[DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
[DllImport("wtsapi32.dll", SetLastError=true)] static extern bool WTSQueryUserToken(uint s, out IntPtr t);
[DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr p, uint a, out IntPtr t);
[DllImport("advapi32.dll", SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr t, uint a, IntPtr sa, int il, int tt, out IntPtr n);
[DllImport("advapi32.dll", SetLastError=true)] static extern bool SetTokenInformation(IntPtr t, int c, ref uint v, int l);
[DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr t, int c, out int v, int l, out int r);
[DllImport("advapi32.dll", SetLastError=true, EntryPoint="GetTokenInformation")] static extern bool GetTokenHandle(IntPtr t, int c, out IntPtr v, int l, out int r);
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool LookupPrivilegeValue(string s, string n, out long l);
[DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr t, bool d, ref TP n, int l, IntPtr p, IntPtr r);
[DllImport("userenv.dll", SetLastError=true)] static extern bool CreateEnvironmentBlock(out IntPtr e, IntPtr t, bool i);
[DllImport("userenv.dll")] static extern bool DestroyEnvironmentBlock(IntPtr e);
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr t, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint f, IntPtr env, string dir, ref SI si, out PI pi);
[StructLayout(LayoutKind.Sequential, Pack=4)] struct TP { public int Count; public long Luid; public int Attr; }
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct SI { public int cb; public string r, desktop, title; public int x, y, xs, ys, xc, yc, fill, flags; public short show, r2; public IntPtr r3, i, o, e; }
[StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr p, t; public int pid, tid; }
public static int NoToken = 0;
static void Fail(string step) { int e = Marshal.GetLastWin32Error(); throw new Win32Exception(e, step + ": " + new Win32Exception(e).Message); }
static void Enable(string name) {
  IntPtr t; long l;
  if (!OpenProcessToken(GetCurrentProcess(), 0x28, out t)) Fail("OpenProcessToken");
  try {
    if (!LookupPrivilegeValue(null, name, out l)) Fail("LookupPrivilegeValue " + name);
    TP p = new TP(); p.Count = 1; p.Luid = l; p.Attr = 2;
    if (!AdjustTokenPrivileges(t, false, ref p, 0, IntPtr.Zero, IntPtr.Zero)) Fail("AdjustTokenPrivileges " + name);
  } finally { CloseHandle(t); }
}
public static string Run(int want, bool system, bool elevate, string cmdline) {
  Enable("SeTcbPrivilege"); Enable("SeAssignPrimaryTokenPrivilege"); Enable("SeIncreaseQuotaPrivilege");
  uint s = want < 0 ? WTSGetActiveConsoleSessionId() : (uint)want;
  if (s == 0xFFFFFFFF) { NoToken = 1; throw new Win32Exception(1008, "no session is attached to the console (no one is logged in)"); }
  IntPtr tok = IntPtr.Zero, env = IntPtr.Zero;
  try {
    if (system) {
      IntPtr own;
      if (!OpenProcessToken(GetCurrentProcess(), 0xB, out own)) Fail("OpenProcessToken");
      bool ok = DuplicateTokenEx(own, 0x02000000, IntPtr.Zero, 2, 1, out tok);
      CloseHandle(own);
      if (!ok) Fail("DuplicateTokenEx");
      if (!SetTokenInformation(tok, 12, ref s, 4)) Fail("SetTokenInformation(TokenSessionId " + s + ")");
    } else {
      if (!WTSQueryUserToken(s, out tok)) {
        if (Marshal.GetLastWin32Error() == 1008) { NoToken = 1; throw new Win32Exception(1008, "no user is logged on in session " + s); }
        Fail("WTSQueryUserToken(" + s + ")");
      }
      int type, n;
      if (elevate && GetTokenInformation(tok, 18, out type, 4, out n) && type == 3) {
        IntPtr linked;
        if (!GetTokenHandle(tok, 19, out linked, IntPtr.Size, out n)) Fail("GetTokenInformation(TokenLinkedToken)");
        CloseHandle(tok); tok = linked;
      }
    }
    if (!CreateEnvironmentBlock(out env, tok, false)) Fail("CreateEnvironmentBlock");
    SI si = new SI(); si.cb = Marshal.SizeOf(typeof(SI)); si.desktop = "winsta0\\default";
    PI pi;
    if (!CreateProcessAsUser(tok, null, new StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, false, 0x01000410, env, null, ref si, out pi)) {
      if (Marshal.GetLastWin32Error() != 5 || !CreateProcessAsUser(tok, null, new StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, false, 0x410, env, null, ref si, out pi)) Fail("CreateProcessAsUser");
    }
    CloseHandle(pi.t); CloseHandle(pi.p);
    int got, m; GetTokenInformation(tok, 12, out got, 4, out m);
    string who; using (WindowsIdentity id = new WindowsIdentity(tok)) { who = id.Name; }
    return "started PID " + pi.pid + " in session " + got + " as " + who;
  } finally {
    if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
    if (tok != IntPtr.Zero) CloseHandle(tok);
  }
}
'@
# The MSVC/CommandLineToArgvW rules, which is what the started program will
# parse with: quotes only when needed; a run of backslashes is doubled before a
# quote or the closing quote, and left alone anywhere else.
if (-not $cmdline) {
  $bs = [char]92
  $cmdline = (@($argv.Split([char]0x1F)) | ForEach-Object {
    if ($_.Length -gt 0 -and $_ -notmatch '[\s"]') { return $_ }
    $b = New-Object Text.StringBuilder; [void]$b.Append('"'); $n = 0
    foreach ($c in $_.ToCharArray()) {
      if ($c -eq $bs) { $n++; continue }
      if ($c -eq '"') { [void]$b.Append($bs, 2 * $n + 1) } elseif ($n) { [void]$b.Append($bs, $n) }
      $n = 0; [void]$b.Append($c)
    }
    [void]$b.Append($bs, 2 * $n).Append('"'); $b.ToString()
  }) -join ' '
}
$want = -1; if ($session) { $want = [int]$session }
try { [Console]::Out.WriteLine([Vu.Ui]::Run($want, $as -eq 'system', $elevate -eq '1', $cmdline)) }
catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  [Console]::Error.WriteLine($e.Message)
  if ([Vu.Ui]::NoToken) { exit @@RC_UI_NO_USER@@ }
  exit 1
}
exit 0
