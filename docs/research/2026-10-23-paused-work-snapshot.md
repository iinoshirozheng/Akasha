# Paused optimization snapshot before branch consolidation

The user paused performance work on 2026-10-23 and requested merging all local
branches into `main`, followed by removal of redundant branches, worktrees,
build caches and temporary files. No new performance run is authorized by this
snapshot. M5/M6 remain incomplete; native Linux x86_64 acceptance remains deferred.

[Snapshot archive](2026-10-23-paused-work-snapshot.tar.gz) preserves 712 files
(263,720,563 uncompressed bytes), including both isolated prototype source trees,
tests, scripts, raw JSON results, logs, frozen input plans and eight untracked
research files from the original main worktree. `MANIFEST.json` records the size
and SHA-256 of every artifact; all entries were read back and verified before
removing originals. Rebuildable native binaries, databases and interpreter caches
are excluded. This archive preserves research; it does not install prototype code
into the production engine.

Archive SHA-256:
`952d879f8b9d4e8a364c45e1e80b62464f33187aec6a75955362be71155c1e6c`

## Captured state

- `immutable-point-delta-score-certificate`: 147 recorded test cases; mixed
  screen has 12 completed workers. The full mixed run finished with 36 workers,
  all exit 0; its recorded speed gates are production 23/36, retained 33/36,
  candidate 32/36. One retained pass becomes a failure. Full warm acceptance
  was not run. The prior decision to continue is superseded by the user's pause.
  Native SHA-256: `374cdded5e86503c686ff0514d5818e42d4a3cd2f37e233fed73d2bb18ffac04`.
- `immutable-point-delta-score-slot`: 148 recorded test cases and a five-case
  overlay recheck; 12 completed screen workers and six completed warm diagnostic
  workers. Its recorded decision does not advance this variant.
  Native SHA-256: `06b791d1402d5acaf8a626785323d3abb1a4f2d2e47dad191a95f53bdce620dc`.
- These are captured runtime reports. The new full mixed run and warm diagnostic
  have not received the independent archive-only result audit. No new acceptance,
  broad integration check, capacity result, or production adoption is claimed.
- Five original main-worktree reference files differ from the incoming branch;
  their exact original bytes are retained under `main-untracked/`. The incoming
  tracked versions remain the current reference implementation. Three other
  originals are byte-identical to incoming tracked files and are also preserved.

The earlier retained weak-base certificate and other experiments remain available
in their previously committed research archives. Paths inside historical scripts
refer to the removed worktree and require restoration or relocation before reuse.
