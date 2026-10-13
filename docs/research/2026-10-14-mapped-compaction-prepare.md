# Prepare mapped compaction output outside writer — 2026-10-14

**Unadopted.** The fixed same-batch mixed speed gate is **24/36→18/36**,
with seven pass→fail and one fail→pass cells; warm is **23/36→17/36**, with
six pass→fail cells. Both phases retain 36/36 quality and identical IDs,
Float32 score bits, traversal statistics and execution decisions. Write plus
flush remains 3/9. Production engine `6d01819` is unchanged; M5/M6 are unfinished.

The [phase diagnostic](2026-10-14-mapped-compaction-phases.md) located
6.087–13.539 ms of persisted output mapping/CRC/decode inside the parent's
writer lock. This isolated follow-up moves that preparation before writer
acquisition in foreground and background compaction. The prepared file and
mapped rows remain strongly owned through commit and until the caller leaves
writer. The checked checksum and exact lease name bind preparation to output.
Current-version checks, dense-owner staging and manifest publication stay under
writer; newer accepted rows are preserved. Previous row/read owners are still
released outside writer. There is no public API or durable-format change.

Preparation failure discards job output and releases the input pin and source
lock. Cancellation and publication conflict retain the existing disk primitive.
The MappedVectorFile construction contract explicitly allows a compaction job's
exclusively owned, unpublished file outside source publication exclusion. Typed
jobs retain their previous disk-only path; typed live authority is not complete.

The new preparation test first fails because the API is absent. The final two
tests establish that preparation changes no live owner or manifest, leaves
numeric caches unmaterialized, preserves a newer WAL-only update through commit
and reopen, and rejects a changed prepared checksum with cleanup and retry.
Existing corrupted/missing/wrong-checksum output tests remain unchanged. The
direct live reclamation fixture now prepares before taking writer and releases
that owner afterward, preserving its file-existence assertions.

Current-source validation passes **64 selected Mojo cases, 23 crash cases,
359 Python tests and C ABI**. It covers preparation failure, publication conflict,
concurrent writes, background cancellation, close liveness, source ownership,
snapshot/backup, legacy/named collections and durable publication order. Source
hashes match every counted run and the rebuilt binaries; the child compiler
wrapper targets this candidate. No new full CPU, Metal, Linux or capacity gate
is claimed, and parent coverage is not added to these counts.

Candidate: `.build/m5-resume/mapped-compaction-prepare`.
Python binary SHA-256:
`db31be3a1034c84d0fe9deeac27fd3939c2a74344295be2c9a9497f6ca1ac63b`.
C binary SHA-256:
`8de75a765ea706633d3d6fdbea61e2ae8347bb819cd4cb0b35d6c6e74c236246`.

Each performance phase runs all 27 serial workers: three rotating
production/candidate/Qdrant triples for each unchanged corpus. Fixed plans,
oracle, filters, ef, timing and strict Recall@10 ≥ .95, QPS ≥ Qdrant and
p95 ≤ Qdrant requirements are retained. Mixed exit 1 means its gate failed;
every worker completed successfully. Warm driver completion likewise does not
certify the per-cell gate. Full-exact warm QPS after/before is
.755/.778/.779 at uniform-128 and .960/.952/.964 at uniform-1536.
The earlier candidate's totals are not subtracted to claim an improvement.

Next inspect the remaining whole-row cloning during dense-owner staging and
exchange. The parent diagnostic measured about 2.2 ms staging and 1.6 ms exchange;
those are parent observations, not fresh timings of this binary. A concrete
replacement list can retain old/new dense PointFields while leaving current
sparse/payload fields and slots intact. Do not swap a captured whole table based
only on dense row sequence: legacy sparse-only writes update collection sequence
without changing that row's dense sequence. Test this case and old-owner lifetime
before another unchanged gate. Warm, typed authority and capacity gaps remain.

[Complete sources, tests, raw trials and per-cell summary](2026-10-14-mapped-compaction-prepare.json.gz)
contain 3,945 files, 25,210,411 compressed bytes, SHA-256
`673a0b1f2931a4a1872d84e5eab99f85a17674c4099daa832d39f8f53cea3292`.
Archive integrity and every embedded hash were verified. All failed cells and
slow samples remain; binaries and copied databases are excluded and identified
by hashes.
