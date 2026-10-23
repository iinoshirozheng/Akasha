# Local branch consolidation

The user paused performance optimization and requested all branches merged into
`main`, then redundant local branches, worktrees, build caches and temporary files
removed. The existing no-push preference remains in effect.

## Inputs and preserved work

- Previous main: `f6a938a5458f7be472420939becd577057950939`.
- Qdrant alignment: `91dbef34dd163438edb814b43315c0695f7f0375`, followed by the
  preservation commit `d3b8bdd`.
- Bounded generation branch: `8241450` (62 commits outside previous main).
- Remote refs were fetched before integration. No additional remote branch work
  was found. Remote refs are not deleted or pushed.
- [Paused work snapshot](../research/2026-10-23-paused-work-snapshot.md) preserves
  the two final isolated prototypes and all eight originally untracked research
  files before cleanup. Older experiments remain in their committed archives.

## Merge decisions

The Qdrant branch's current public contracts take precedence over older behavior:
zero cosine scores, half-precision cosine preprocessing, replacement upsert,
cardinality dispatch, filtered traversal, bounded mapped codecs, mandatory point
storage, and unlocked compaction capture/reclamation remain in effect. Removed
legacy HNSW search functions are not restored; boundary tests use the current
production traversal through the existing test adapters.

The other branch contributes Python callback/lifetime fixes, returned-container
ownership, native four-candidate reranking, metadata encoding reuse, live delta
work bounds, immutable-run named HNSW reuse and optional persisted named caches.
Named graph construction retains Qdrant payload subgraphs and checks cardinality
before building. Persisted graph identity includes payload bytes because those
subgraphs depend on metadata. Its decoder uses the current bounded mapped codec.
Native four-candidate scoring preserves the Qdrant zero/F16 cosine contracts;
F16 bit fixtures use the existing independent NumPy oracle.

The visit-argument helper is not reinstated: the main branch's explicit
[rejection](../benchmarks/2026-10-13-visit-args-port.md) supersedes its older feature
branch adoption. All commits and the rejected experiment evidence remain in Git.
The layered named-graph ownership test validates visibility, payload eligibility,
current-authority scores and the bounded result count against a full exact
oracle. Its tight ANN budget no longer assumes exact recall through excluded
bridge points. The separate full-budget named search checks still compare exact
result order. Production search settings are unchanged by these test updates.

This is an integration check, not a new performance acceptance run. M5/M6 remain
incomplete and native Linux x86_64 acceptance stays deferred. The paused prototypes
are archived only; they are not promoted into production source.

## Validation and cleanup

The final merged source passed the following local checks with Mojo 1.0.0
(ed45d567):

- 50 relevant Mojo modules / 256 top-level cases; 14 successful modules from the
  same integration were reused, and the remaining changed call paths were checked.
  This is not a rerun of all 176 Mojo modules.
- 618 Python tests passed with one optional Qdrant adapter skipped; rerunning the
  adapter pair using the existing pinned Qdrant Edge 0.8.0 dependency passed both,
  yielding 619 distinct Python cases covered.
- All 9 crash-recovery modules / 24 cases and 10 local distributed cases passed.
- Python native library, C library/API smoke, native worker, and all three Mojo
  example builds passed. `git diff --check` and changed Python AST parsing passed.

The earlier merge-test failures, their corrections, raw logs, commands, final
source/test hashes, native artifact hashes and cleanup inventory are preserved in
[the validation archive](2026-10-23-merge-validation.tar.gz). All 78 archive entries
were read back and verified against `MANIFEST.json` before cleanup. Archive SHA-256:
`fdb0bd92f350f9c727d6a1def553281c1ee5c2d88f6c7891ec005023b53372d1`.

The guarded cleanup runs after this validated merge is committed. It removes only
merged local branches, the extra worktree, generated project build/test files,
project-specific temporary entries, and the stopped Akasha benchmark containers
and their four dedicated volumes. Installed dependencies, reference checkouts,
committed evidence, Git history and remote refs are preserved. Final cleanup
counts are recorded separately after execution.
