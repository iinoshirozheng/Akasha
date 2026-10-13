# Retain read-run indexes at legacy flush — 2026-10-14

**Unadopted.** This candidate removes the full indexed-base rebuild after an
ordinary legacy flush, but its fixed mixed gate still falls **25/36→12/36**
against same-batch production, with fifteen pass→fail and two fail→pass cells.
Warm speed is **24/36→21/36**, with three pass→fail cells. Quality is 36/36
before and after in both phases; all IDs, Float32 score bits, traversal
statistics and execution decisions match. Write plus flush remains 3/9.
Production engine `6d01819` is unchanged and M5/M6 remain unfinished.

The isolated candidate starts from the
[legacy live-compaction implementation](2026-10-14-mapped-live-compaction.md).
Two engine files change. Before manifest commit, the read publisher prepares
same-version dense-owner replacements in touched run tables and the mutable
head. Immutable metadata/sparse indexes are shared through ArcPointer because
their input fields and slot order do not change. Existing roots keep their old
tables; shadow masks, accepted sequence and head bounds remain unchanged.
Only changed run tables copy descriptors, and a touched head invalidates its
frozen copy. Background merge publication still checks captured run identities.
Compaction continues to detach the full cache and release its old owners outside
the writer lock. Typed live compaction remains incomplete.

Both initial regression tests fail on the parent: after flush, base_builds
increases from one to two. They pass with the new implementation. The final
three cases cover mutable head, a sealed 1,024-point run, shared index identity,
snapshot lifetime, and failed manifest publication followed by retry. The latter
keeps the original root on failure and shares its index after successful owner
replacement. Four failed compiler attempts are retained; Mojo 1.0 requires
reinitializing the moved aggregate field, as in the existing detach method.

Current-source validation passes **103 distinct Mojo cases, 359 Python tests
and C ABI**. Coverage includes actual Metal, Arrow exports, generation delta,
snapshot/batch/named collection behavior, corrupt compaction output and retry,
background publication, outside-lock reclamation, and HNSW publication/cache.
Every counted run matches the built source hashes. The child compiler wrapper
is explicitly bound to this candidate. No fresh crash, full CPU, Linux or
capacity gate is claimed; parent results are not added to these counts.

Candidate: `.build/m5-resume/mapped-flush-runs`.
Python binary SHA-256:
`d0845b87078ed1337caaa3b03f5ea6fd76840995dc606164355dee760cf4e838`.
C binary SHA-256:
`b35fefbfa8a79d1690372bea5e19275c672d8573efb93291618dbadadc54d977`.

Each performance phase retains all 27 serial workers: three rotating
production/candidate/Qdrant triples per corpus, with unchanged work, oracle,
filters, ef and timing. Acceptance requires Recall@10 ≥ .95, QPS ≥ Qdrant
and p95 ≤ Qdrant in every cell. Mixed exit 1 is a failed gate, with all workers
successful. Warm driver completion does not mean its strict gate passed.
Full-exact warm QPS after/before is .784/.771/.788 at uniform-128 and
.920/.981/.939 at uniform-1536. No cross-batch total is used as an improvement.

The mixed uniform-128 selective trial 1 remains in the evidence despite its
QPS ratio .062 and p95 ratio 117.762 against production. No sample is discarded.
Removing ordinary flush resets alone is insufficient. Background compaction
still decodes persisted output and replaces live owners under writer exclusion,
then detaches read runs; the next capture rebuilds an indexed base. Next measure
these phases in a separate instrumented diagnostic before changing their
publication boundaries. Existing warm and typed/capacity gaps remain open.

[Complete sources, tests, raw samples and per-cell summary](2026-10-14-mapped-flush-runs.json.gz)
contain 3,921 files, 25,189,969 compressed bytes, SHA-256
`10a576203bdcbdab45f7014f253cbbf43bd7a064d043b79d653a15b4af149b09`.
Archive integrity and every embedded hash were verified. Binaries and copied
databases are excluded and identified by hashes. All transitions and failing
cells are retained in `performance-summary.json` with the original phase reports.
