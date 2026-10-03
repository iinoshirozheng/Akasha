# Share named HNSW by immutable run

Baseline `4e63018` (engine `a57f11a`). The diagnostic under
`.build/2026-10-03-named-root-cost` imports the first 2,048 final-state points of
each existing fixed corpus. At ef=512, all six queries per corpus return 10/10
exact matches. A one-point payload/vector update rebuilds all 2,048 graph rows:
1.41–1.42 s (128D), 4.65–4.73 s (uniform 1536D), 3.00–3.01 s (real cosine).
Warm unchanged-root queries take 0.48/1.81/1.84 ms. This is a lifecycle diagnostic,
not the complete Qdrant acceptance matrix.

Move the named HNSW artifact owner from `ReadGeneration` to `ReadRun`. A published
run's contents are immutable; its base/sealed owner already survives later roots.
Keep the existing locked `FieldArtifacts`/`ArtifactState` lifecycle, with one graph
per run and field. Store run-local ordinals, never a root's layer number. The
collection field catalog is immutable for its lifetime (`PointStore.open` rejects
a different catalog); reopening/migration creates fresh run owners. Check the
artifact's authority scalar and exact graph config before reuse as well.

Search each run with root-specific visibility and payload admission before Top-K.
Merge the run candidates by the graph's public F32 score and ID tie break into a
single bounded candidate set. The explicit rerank budget remains global. Resolve
those IDs in the captured root and rerank against their native authority in F64.
Sum traversal counters, distinguish base/delta candidate counts, and retain the
existing exact exhaustion path and query controls. No stale row may consume a
candidate position; deleted/missing fields do not participate. Locks protect each
graph's existing mutable search scratch; the captured root owns the runs throughout.

This follows the existing read-run ownership and Qdrant's per-segment HNSW owner
(`reference/qdrant/lib/segment/src/index/hnsw_index/hnsw.rs` in the parent checkout).
Do not add a global cache or a second root-graph fallback. Default retained HNSW,
other field artifacts, durable bytes, and public signatures stay unchanged.

First prove reuse with a failing regression, then cover old/new snapshots,
payload changes, vector replacement/removal, deletes/reinsert, filters, missing
fields, global rerank budget, run merges and concurrent first queries. Run narrow
Mojo tests before broader affected tests and full Python/C ABI/examples. Compile
and measure the same diagnostic from isolated source, preserving the baseline and
all failures. Add a multi-run named recall check against exact authority because
per-run graph topology is different. Benchmark/build/test/compression stay serial.

This is an independently usable part of M5. Initial/reopened run construction
still needs a separate durable/prebuilt lifecycle step; do not claim M5 or M6 is
complete after this change. The original strict Qdrant matrix remains unchanged.
