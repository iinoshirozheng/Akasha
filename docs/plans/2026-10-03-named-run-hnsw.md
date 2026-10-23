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

The first full-corpus diagnostic confirms that distinction: 1,608 exact oracle
checks and 9,648 ANN samples pass ID/filter/native-score audits, but 128D
independent needs ef=256 instead of 128 and most warm cells slow down. After the
original update/delete stream, first-query time falls from 6.82/32.69/17.39 s to
0.53/1.12/0.92 s. All low-recall cells remain in the reports. For unfiltered 128D
at ef=128, average distance work rises from 3,957 to 4,839; no widening occurs.

Before adoption, compare the existing `HnswSearchAdmission` slot adapter against
the per-run ID adapter. These graphs are append-only, built in sorted row order,
and never mutated after publication except for locked search scratch. Validate
each graph slot's public ID against that row during construction, then use owned
slot flags for visibility/filter admission through the existing generic widening
method. Keep candidate public-ID checks and the global native rerank bound. This
must reproduce IDs, F64 score bits and traversal counters for every fixed sample;
it does not change ef, graph topology, float arithmetic or candidate checks.

Outcome: adopt the run ownership and checked slot admission as the M5 lifecycle
step. The slot comparison preserves all 4,824 paired ID/score/stat samples; the
final direct production comparison retains substantial warm regressions and all
low-recall cells. No M5/M6 completion or Qdrant parity claim.
[Implementation, validation and frozen evidence](../benchmarks/2026-10-03-named-run-hnsw.md).

Final review also bounds merge-heap reservation by visible population. Legal
UInt32.MAX ef/rerank requests on an empty/tiny named collection must not reserve
an ef-sized heap. A new regression covers empty, filtered and unfiltered views.
The allocation-bound version has separate frozen test/source evidence; its timing
was not rerun and is not substituted for the measured slot binary.
