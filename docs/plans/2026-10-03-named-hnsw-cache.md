# Persist completed single-run named HNSW graphs

The current read publisher starts with one complete immutable run after open.
Its named graph is built lazily and discarded on close. Reuse the existing
bounded, CRC-protected derived-cache envelope and HNSW snapshot codec to save a
ready graph on flush/close and load it on the next first query. This is an
independently usable M5 step; multi-run update/reopen and the strict M6 matrix
remain open.

Only a complete current single run is published. Do not build a graph to save
it, combine graphs, change topology, or store run-local ordinals. Bind the cache
to field ID/name/native scalar/metric/dimension/exact graph configuration and
sorted live field IDs plus their F32 projections (the supported F32/F16/BF16/I8/U8
authority scalars project without loss). On load rebuild ordinal/ID mappings
against the current immutable table and reject missing/extra/inactive graph rows.
Metadata and layout changes alone may reuse the graph; native rerank still reads
the current authority. Existing snapshot validation checks the complete graph.

Each field has one fixed optional file, atomically replaced only while holding
the collection writer/file lock. Queries only read it; old snapshots cannot
write after close or race a replacement writer. Cache errors are misses, never
authority errors. Flush/close publication is best effort; a failed publication
remains retryable. Backup continues copying authoritative manifest files only.
No new package or public API is needed. The existing per-run artifact and query
locks protect build/load and serialization respectively.

Review found that waiting on those locks during flush/close could hold the writer
behind a long build. Save caches only after a single successful acquisition of
each lock; busy artifacts remain eligible for a later attempt. The pinned
[Mojo 1.0 lock source](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/utils/lock.mojo)
exposes an atomic owner counter but no try-lock method. A single compare-exchange
uses that same owner/unlock protocol without adding another lock implementation.
Regressions hold the artifact/search lock on the same thread: publication must
skip it and subsequently retry, while close must leave held snapshots usable.

First demonstrate the missing persistent artifact with a failing test. Cover
reopen hits with identical result/score bits, ordinal reorder, native/config/ID
mismatch, corrupt/truncated/wrong-kind snapshots, publication failure/retry,
WAL-only changes, held snapshots/close, and multi-run nonpublication. Compile
with the installed Mojo 1.0.0, then run affected storage/query/lease tests and
isolated binding validation. Measure first-query and flush/close costs against
the unchanged baseline, retaining every sample. No full M5/M6 completion claim.
