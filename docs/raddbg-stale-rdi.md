# raddbg shows the wrong breakpoint line after a re-sync

## Symptom

After syncing a rebuilt Windows build into the guest a second time, stepping into
`WinMain` (F11) in raddbg hits a breakpoint whose highlighted source line is
wrong. The first sync (fresh destination) was correct.

## Root cause

raddbg never reads PDBs directly. It converts PDB -> RDI (its own RAD Debug Info
format) and caches the result as `<pdb-name>.rdi` next to the PDB. On later
loads it decides whether to regenerate that cache **by comparing file mtimes
only** (plus the RDI encoding version), never by the PDB GUID/age that the
exe's debug directory carries.

The stale `.rdi` from a previous build is left in the guest because the sync
does not manage it: it is generated in-guest by raddbg, it is not part of the
repo/staging, and robocopy never deletes anything. When the guest is re-synced
with a rebuilt PDB:

- robocopy preserves the host *build* mtime on the new PDB;
- the stale `.rdi` was written by raddbg at *debug* time, which is later;

so `rdi.mtime >= pdb.mtime` and raddbg treats the stale cache as fresh and
reuses the old build's line table. Breaking at the (correct) new `WinMain`
address then maps through the old line numbers and displays them against the
new source, where `WinMain` may have moved hundreds of lines — hence the wrong
line.

## Evidence (win11-24h2, raddbg 0.9.27)

- `C:\winspace` (second sync) and `C:\winspace_fresh` (first sync) are each
  internally consistent and byte-identical to the host build (SHA-256 verified).
- `C:\winspace\build\winspace.rdi` is byte-identical to
  `C:\winspace_fresh\build\winspace.rdi` (same hash, same 12,548,740 bytes,
  same mtime) — it cannot match both different builds.
- mtimes (absolute UTC):
  - new PDB  `C:\winspace\build\winspace.pdb`  = 2026-08-20 21:54:39 UTC
  - stale    `C:\winspace\build\winspace.rdi`  = 2026-08-21 11:54:01 UTC (14h newer)
  - old PDB  `C:\winspace_fresh\build\winspace.pdb` = 2026-08-20 21:53:53 UTC
- raddbg's own config `C:\Users\test\AppData\Roaming\raddbg\default.raddbg_user`
  resolved the debug info to `C:/winspace/build/winspace.pdb` and maps the
  embedded source path `Z:/home/clovolc/Work` -> `C:` (opening
  `C:/winspace/win32.cpp`).
- Both exes embed the same PDB GUID, age 38 (old) vs 39 (new) — the signal
  raddbg ignores (an unimplemented `// TODO` in `di_key_from_path_timestamp`).

Note: host and guest file mtimes are the *same absolute instant*; they only
*display* differently because the host timezone is UTC+7 and the guest is
UTC-7. That is not the bug — the `.rdi` is genuinely 14h newer than the PDB.

## Fix

Delete the stale cache in the guest so raddbg re-converts the new PDB:

```
del C:\winspace\build\winspace.rdi
```

Leave `C:\winspace_fresh\build\winspace.rdi` in place — it is valid for that
(old) build.

## Prevention

This recurs on every rebuild + re-sync: the delivered PDB keeps its host build
mtime (older than any raddbg-written cache), so raddbg's mtime-only staleness
check always passes. Options:

- Delete the cache after each sync:
  `virutil exec cmd win11-24h2 del C:\winspace\build\*.rdi` (or the equivalent).
- Delete it on the host before building so robocopy propagates the deletion:
  `del build\*.rdi` in `build.sh` / `build.ps1`.
- Report upstream: raddbg should validate the RDI cache against the PDB
  GUID/age from the exe's debug directory instead of mtime only.

## Out of scope / related

The sync's fetch rsync runs without `--delete`, so the staging tree and guest
accumulate stale files (e.g. `build/win32.cod`) that are re-offered but never
deleted. Not the cause of this bug, but the same "robocopy only adds" behavior
is what lets the in-guest `.rdi` survive.