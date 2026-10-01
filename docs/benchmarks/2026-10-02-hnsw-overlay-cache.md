# Checkpointed HNSW overlay reuse

Reopen now reuses a validated, checkpointed delta graph instead of rebuilding it
after every update. On the fixed resident mixed workload, median reopen falls
from 688/1708/1401 ms to 127/357/366 ms. Persisting the graph adds work to flush:
paired p95 increases 45–56%, and combined write-plus-flush increases 33–37%.
This is a recovery improvement with a measured checkpoint cost.

## Design and evidence

The existing AKIC envelope gains derived kind 3. Its key is the retained base CRC,
latest authority sequence and a generation no newer than recovered authority.
The embedded unchanged HNSW snapshot binds configuration and base sequence. On
load, structural validation and exact delta ID/prepared-vector coverage must pass
before adoption. Corrupt, stale, missing or mismatched caches trigger authority
reconstruction. The cache is bounded to the existing 512 MiB payload limit before
allocation and is published best-effort after checkpoint, never during preflight.
See the [plan](../plans/2026-10-02-hnsw-overlay-cache.md) and
[format contract](../formats/hnsw-format.md).

Only successful publication is memoized by latest sequence/base sequence/base CRC.
An unchanged graph is reused through compaction; failed writes remain retryable.
Validated F32 snapshot vectors use an owned bulk byte copy on little-endian hosts,
with the prior scalar encoding on big-endian hosts. Compact encodings are unchanged.

Native phase timing initially attributed median 592/1465/1115 ms to overlay
reconstruction (including source bindings). A mapped-row loading prototype showed
small, inconsistent whole-open changes and was not adopted. The first cache
prototype used exact generation and the physical MemTable checksum; compaction
invalidated that key. Its failed mixed results and the failing regression are
retained. The final key permits physical reordering while verifying logical state.

An isolated encoding probe performed 126 timed encodes in three alternating pairs
per corpus. Every complete before/after snapshot was byte-identical. Per-trial
median encoding times were approximately 5.4 → 5.1 ms at 128D, 14.9 → 10.7 ms at
uniform 1536D and 16.1 → 11.4 ms at real 1536D. All graph/vector/checksum checks
remained enabled. The probe's additional compact-byte branch was not measured or
adopted. Snapshot file hashes and byte equality, not the constant CRC residue of
a file containing its own CRC, establish identity.

## Paired lifecycle measurement

`benchmarks/bounded_batch.py --phases mixed --trials 3` compares the saved
post-stream-fingerprint package with current production. Each of three corpora
runs 32 blocks of nine reads, eight replacements and flush, followed by compaction,
lease release and reopened exact checks. There is one foreground caller plus
background maintenance. Measurements run serially, without tests or builds.
OS cache is present; this is not a controlled non-resident measurement.

All 5,184 query audits, 72 recall cells, 18 reopen oracles and 18 Arrow leases pass.
The table reports medians of per-trial measurements. Ratios are computed within
each pair and summarized by median and full range.

| Corpus / operation | Before ms | After ms | After/before median (range) |
| --- | ---: | ---: | --- |
| Uniform 128D / reopen | 687.763 | 126.540 | .184 (.183–.184) |
| Uniform 1536D / reopen | 1707.990 | 356.610 | .209 (.207–.210) |
| Real 1536D / reopen | 1401.416 | 365.877 | .261 (.259–.262) |
| Uniform 128D / flush p95 | 15.791 | 23.816 | 1.448 (1.440–1.508) |
| Uniform 1536D / flush p95 | 35.815 | 54.603 | 1.507 (1.487–1.581) |
| Real 1536D / flush p95 | 35.277 | 55.160 | 1.558 (1.544–1.574) |
| Uniform 128D / write + flush p95 | 23.522 | 31.360 | 1.333 (1.312–1.335) |
| Uniform 1536D / write + flush p95 | 59.341 | 79.814 | 1.341 (1.300–1.345) |
| Real 1536D / write + flush p95 | 51.659 | 70.611 | 1.370 (1.347–1.385) |

Write-only paired median ratios are 1.032/1.025/.981. Whole-process peak RSS
medians are 158.0 → 169.4, 667.0 → 555.2 and 556.3 → 561.3 MiB. These high-water
marks include the entire lifecycle and are not isolated cache allocation costs.
Initial opens of baseline copies without caches remain essentially unchanged.

A separate nine-pair ordinary-open study, after explicitly preparing caches,
checks 32 exact oracles and 32 approximate queries per process. Every pair returns
identical query IDs and scores. Its medians fall 708 → 124, 1916 → 390 and
1575 → 399 ms. Preparation is excluded and recorded. This study predates only
the publication memo; its loading and query code are the same. Slow samples,
including a 483 ms after-open and earlier prototype tail regressions, remain in
the archive rather than being selected out.

## Validation

The final overlay tests cover 58 parameter cases across five functions: native
graph scalar/metric identities, legacy and typed authority, inactive traversal
slots, replacements/deletes/reinsertions, malformed and forged valid-CRC artifacts,
newer WAL, compaction, publication failure and same-state retry. The base recovery,
compaction-reuse and writer tests first exposed the missing behavior, then passed.
Independent byte tests include signed zeros, subnormals, infinities and NaN payloads;
graph validity checks continue rejecting invalid vector values.

Validation was staged as implementation changed. The archive retains commands and
logs for 73 Mojo/14 crash tests in the initial stage, 34 supplementary Mojo tests,
70 Mojo/14 crash after the compaction key fix, 48 Mojo/6 crash after F32 encoding,
and 22 Mojo/6 crash after publication reuse. These overlap and are not a unique
full-suite total. Final direct overlay tests pass; the rebuilt extension passes
all 317 Python tests, and the rebuilt C library passes its external C11 client.
The earlier [full CPU checkpoint](../research/2026-10-02-cpu-integration.md) is
separate. No distributed or actual-GPU gate is claimed for this change.

[Raw reports, immutable source copies, rejected prototypes, validation and hashes](results/2026-10-02-hnsw-overlay-cache.json.gz)
have SHA-256 `9858ed3a7b9f9ba20a3cc6cf8f2d27578b92ac882412996b9be899123f946351`.
Identical large workload plans reference the existing stream-fingerprint archive
by hash; equality was checked before deduplication. The
[fresh Qdrant comparison](2026-10-02-qdrant-mixed-overlay.md) still has unmet cells.
