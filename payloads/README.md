# payloads -- the scripts virutil sends *into* a guest

These are the only code the two drivers share. They are keyed on the **guest's**
OS, never the host's, so `virutil` (bash, Linux host) and `virutil.ps1`
(PowerShell, Windows host) send byte-identical text to a guest of a given kind.
Keeping them here as data is rule 2 of the fork: see `docs/contract.md` §6.

`linux/` and `win/` here are therefore the *guest's* halves, not the host's --
the opposite of `modules/linux` and `modules/win`, which are one driver each.
Both drivers read both halves, and a caller names a payload by its bare
filename: the renderer settles the half from the extension, which is what
already settles the quoting. See `payload_render` in `modules/linux/payload` and
`Invoke-Payload` in `modules/win/payload.ps1`.

`mount.ps1` and `unmount.ps1` are the one exception, and §6 names them as such:
they are keyed on the **host**, because only one host has to authenticate the
share it is serving. A Linux host serves an anonymous share and sends neither of
them. Both drivers still render both, and both are in the golden file, because
that is what keeps "byte-identical" a fact rather than an intention -- the two
renderers have to agree on text only one of them is obliged to use.

They are also the most carefully bisected code in the repo. robocopy's exit code
is a bitmap and not an error level, so `0` means "nothing needed copying" and
only `>= 8` is a failure. robocopy always takes a source *directory*, so a file
is named as a filter on its parent. `-rlptD` rather than `-a` on the rsync side,
because the guest runs these as root and `-a` would try to reproduce the
daemon's uid and gid on every delivered file. Do not reason any of that out
again from the shape of the code; it is written down where it happens.

## The placeholder grammar

A driver reads one of these files and substitutes two kinds of hole. Nothing
else in the text is touched.

| form | meaning |
|---|---|
| `@NAME@` | a value, interpolated as a **quoted string literal** in the payload's own language: single quotes for `.ps1` (doubling any quote inside), single quotes for `.sh` (closing, escaping and reopening). The driver quotes; the payload never carries its own quotes around one of these. |
| `@@NAME@@` | raw text, substituted as written. Exit codes, and `@@PROBE@@`, which expands to the whole of `probe.sh`. |

Both drivers must refuse to render a payload with a hole left in it -- an
unsubstituted `@DST@` reaching a guest is a script that fails there, in a way
that reads as an unrelated error rather than as a missing argument here.

**Comment-only lines and blank lines are stripped at render time**, in both
drivers, so the commentary below costs the guest nothing. That is not tidiness:
a PowerShell payload is base64'd as UTF-16LE onto a command line Windows caps at
32767 characters, which is about 12000 characters of source, and an sh payload
travels as a single argv entry Linux caps at 128KB. The budget is for the
transfer, not for the prose. `#` opens a comment in both languages, and a line
whose first non-space character is `#` is dropped whole -- so a `#` that has to
survive must not start its line.

`@NAME@` is chosen so that it cannot collide with what surrounds it: PowerShell
spells splatting `@flags` and an array `@(...)`, both lowercase or punctuation,
and `@` means nothing at all to `sh`.

## The files

| file | sent to | what it does |
|---|---|---|
| `linux/probe.sh` | Linux guest | refuse early and legibly when the guest has no rsync |
| `win/push-dir.ps1` | Windows guest | robocopy a served tree into a directory |
| `win/push-file.ps1` | Windows guest | Copy-Item one served file onto a path |
| `linux/push-dir.sh` | Linux guest | rsync a served tree into a directory |
| `linux/push-file.sh` | Linux guest | rsync one served file onto a path |
| `win/pull.ps1` | Windows guest | robocopy matches of a pattern out to the share |
| `linux/pull.sh` | Linux guest | rsync matches of a pattern out to the daemon |
| `win/sync.ps1` | Windows guest | robocopy the whole share onto `C:\` |
| `linux/sync.sh` | Linux guest | rsync the whole export onto `/` |
| `win/mount.ps1` | Windows guest | authenticate to a credentialled share (**Windows host only**) |
| `win/unmount.ps1` | Windows guest | let go of it again (**Windows host only**) |

Each prints one space-separated line on stdout, which its caller parses; the
shapes are documented at the head of each file.

`tests/linux/payloads.sh` and `tests/win/payloads.ps1` render every one of them
with fixed inputs and diff the result against `tests/golden/payloads.txt`. A
change to a payload is a change to that golden file, deliberately.
