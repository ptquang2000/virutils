# `ui`: how PsExec crosses Session 0, and what `ui` does instead

This note records what PsExec does, measured from the binary. Read it before
you change `payloads/win/ui.ps1` or the `ui run` grammar. The code comments say
*how*; this note says *why that recipe*.

## What PsExec does (Sysinternals PsExec 2.43, read from the binary)

Source: `PsExec.exe` 2.43 (Microsoft-signed, SHA-256 `078163D5…937B`). The
service is embedded as resource `BINRES/PSEXESVC`, which is an x86 PE. Its
pdb path is `psexec\svc\Win32\Release\psexesvc.pdb`. The findings come from
its imports, its strings and a disassembly of the launch routine.

1. **Service and pipes.** The client copies PSEXESVC to `ADMIN$`, then
   creates and starts it with the SCM (`CreateServiceW`/`StartServiceW`). It
   talks to the service over the control pipe `\\.\pipe\PSEXESVC`. Each launch
   gets three more pipes, `\\.\pipe\PSEXESVC-<host>-<pid>-stdin|stdout|stderr`.
   The service exists only to get code running as SYSTEM on the target.
2. **Token choice**, one of three:
   - `-s`: `OpenProcessToken(self)` then `DuplicateTokenEx(TokenPrimary)`.
     This gives SYSTEM.
   - `-u/-p`: `LogonUserExExW`. With `-i` it uses an interactive logon and
     adds the target session user's **logon SID** (from `WTSQueryUserToken` →
     `TokenGroups`, the `SE_GROUP_LOGON_ID` entry) to the new token's groups,
     so the new token may open that session's `winsta0`.
   - neither: `ImpersonateNamedPipeClient` on the control pipe, then
     `OpenThreadToken` and `DuplicateTokenEx`. The process runs as the caller.
3. **Restrict / elevate.** `-l` uses `CreateRestrictedToken` at Low integrity
   (`S-1-16-4096`). `-h` reads `TokenElevationType`. When it is `Limited` (3),
   `-h` swaps in `TokenLinkedToken`.
4. **Profile and environment.** `LoadUserProfileW` runs unless `-e` is given.
   Then `CreateEnvironmentBlock(token)`, with `CREATE_UNICODE_ENVIRONMENT`.
5. **Session (`-i [N]`).** `SetTokenInformation(TokenSessionId)` runs after
   `SeTcbPrivilege` is enabled. A session of -1 (a bare `-i`) becomes
   `WTSGetActiveConsoleSessionId`.
6. **Desktop.** For session 0, or with `-x`, PsExec opens `winsta0` and
   `default` (or `Winlogon`) and adds an ACE for the token's SID to each. It
   then sets `lpDesktop` to `winsta0\default` or `winsta0\winlogon`. For any
   other session it leaves `lpDesktop` NULL.
7. **Start.** `CreateProcessAsUserW(token, …, CREATE_SUSPENDED |
   CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT)`. With `-d` it returns the
   PID; without `-d` it waits and returns the exit code.

## What `ui run` did before

It wrapped PsExec: `PsExec.exe -accepteula -i <console> -d APP`, started from
qemu-ga. That has three costs:

- **The process ran as SYSTEM.** qemu-ga is the pipe client, so case "neither"
  above gives SYSTEM, with SYSTEM's HKCU, profile and drive mappings. Running
  as the logged-on user would need their password on the command line.
- `ui setup` had to download PsExec and deliver it with `push`. On a Windows
  host that means Administrator and a throwaway SMB account. Each guest
  needed it once, and a guest without it failed with exit 97.
- Each launch installed and removed a service.

## What `ui run` does now

`payloads/win/ui.ps1` runs steps 2–7 itself, in the SYSTEM powershell that
qemu-ga already starts. SYSTEM is all the service provided, so `ui run` needs
no service, no pipes and no file in the guest.

| `ui run` | token | PsExec equivalent |
|---|---|---|
| default | `WTSQueryUserToken(session)`: the logged-on user's own token, already in its session | `-i` with `-u/-p`, without the password |
| `-s` | own SYSTEM token, duplicated, `TokenSessionId` set | `-s -i` |
| `--elevated` | `TokenLinkedToken` when the elevation type is Limited | `-h` |
| `-i N` | that session; the default is `WTSGetActiveConsoleSessionId` | `-i N` / bare `-i` |

The launch always passes `lpDesktop = winsta0\default`. The user's own token
holds the session logon SID that can open it, and SYSTEM can open it anyway.
A NULL desktop makes the child inherit the agent's service desktop, which a
user token cannot open. That is what caused the STATUS_DLL_INIT_FAILED
(0xC0000142) that a bare `CreateProcessAsUser` from qemu-ga used to hit.

The launch asks for `CREATE_BREAKAWAY_FROM_JOB` and retries without it on
ACCESS_DENIED, so a job object around the agent does not take the GUI down
with the powershell process that launched it.

Not carried over, on purpose: `-u/-p` (the session's own token replaces it),
`-l`, `-x`, profile loading (an interactive user's profile is already
loaded), and waiting on the process (`ui` runs fire-and-forget). Add one of
these only when a caller needs it.

Exit 96 means no one is logged on in the target session. Log a user on, or
use `-s`.
