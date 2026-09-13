# payloads -- the scripts virutil sends *into* a guest

These are the only code the two drivers share. They are keyed on the **guest's**
OS, never the host's, so `virutil` (bash, Linux host) and `virutil.ps1`
(PowerShell, Windows host) send byte-identical text to a guest of a given kind.
Keeping them here as data is rule 2 of the fork: see `docs/contract.md` §6.

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
| `probe.sh` | Linux guest | refuse early and legibly when the guest has no rsync |
| `push-dir.ps1` | Windows guest | robocopy a served tree into a directory |
| `push-file.ps1` | Windows guest | Copy-Item one served file onto a path |
| `push-dir.sh` | Linux guest | rsync a served tree into a directory |
| `push-file.sh` | Linux guest | rsync one served file onto a path |
| `pull.ps1` | Windows guest | robocopy matches of a pattern out to the share |
| `pull.sh` | Linux guest | rsync matches of a pattern out to the daemon |
| `sync.ps1` | Windows guest | robocopy the whole share onto `C:\` |
| `sync.sh` | Linux guest | rsync the whole export onto `/` |

Each prints one space-separated line on stdout, which its caller parses; the
shapes are documented at the head of each file.

`tests/payloads.sh` renders every one of them with fixed inputs and diffs the
result against `tests/golden/payloads.txt`. A change to a payload is a change to
that golden file, deliberately.
