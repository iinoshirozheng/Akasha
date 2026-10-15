# Base-level metadata-read probe — not adopted

The probe replaces each target's level read at level zero with a slot-domain
check. Upper layers retain the level read. Both graph representations store
UInt16 levels; the graph trait was documented as returning a nonnegative level.
Qdrant's ordinary traversal does not read every target's level. Akasha's checked
slot bound remained before scratch indexing; mapped edge loads retained their
open-state and byte-range checks. No graph, score, ef or format changed.

Two additional boundary tests cover out-of-domain entry/later edges and a
cross-level edge after upper descent has moved away from its initial entry.
All 16 layer tests pass before and after. Candidate validation totals 32 tests
across layer, range, mapped view, cancellation and batched scoring files. The
extracted upstream search matches 98 fixtures on scalar and F32 batch paths;
construction matches 24 fixtures and 2,467 adjacency rows. One initial runner
referenced nonexistent `test_hnsw_cancel.mojo`; the actual `test_hnsw_control`
file then passed. Logs retain the command error.

The rebuilt candidate was compared with source-bitmap commit `c8e0ddf` on the
same saved graphs, original workloads/efs and seven public Python query passes.
Serial old/new/old and new/old/new preserve every result digest, recall and
query counter across all twelve cells per order. No builds/tests overlap timing.

The benefit is too small and inconsistent to adopt. Uniform 128D all improves
6.6% then 3.9% QPS, but independent changes from +5.0% to -0.7% and its reversed
p95 regresses 3.7%. Uniform 1536D correlated changes from +1.2% to -0.2% with
p95 regressions in both orders. Real independent changes from +5.8% to -3.2%,
with reversed p95 +7.0%. The exact selective controls also vary; one untouched
uniform 1536D control has QPS .803 and p95 1.635 of baseline. These samples are
retained rather than excluded or attributed to the changed code.

The production source and installed Python binary were restored to `c8e0ddf`.
No full fresh Qdrant acceptance matrix was run for this unadopted candidate.
The last accepted source-bitmap matrix remains recall 36/36, speed 5/36,
overall FAILED. Further work should address public-ID-to-metadata-ordinal
translation during filtered admission before repeating this level-read change.

[All raw comparisons, source patch, oracles and validation](results/2026-10-16-hnsw-base-level-probe.json.gz)
(71 files, 357,916 bytes; SHA-256
`ad2a7803896be7f2690969b8ddb4edae89853bb0d010fc832b196128171d3a37`).
