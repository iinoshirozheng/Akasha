# Mapped cache decoding and rejected streamed metadata writers

Baseline is `9fb5adb`. The retained change decodes a validated AKIC payload
from a bounded read-only mapping. Its inode stays owned until decoding finishes;
the resulting graph and metadata index own their values independently. The
common HNSW decoder retains v1/v2/v3 checks, scalar validation and lifecycle
restoration. Subrange readers cannot consume surrounding envelope bytes.
No public API, durable format, query algorithm or acceptance threshold changes.

Two metadata-output optimizations were also implemented, measured and rejected.
Their source, tests and all measurements are archived, not retained in production.

## Source evidence

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d` exposes bounded
read-only vector ranges via `Cow` in
`lib/segment/src/vector_storage/chunked_vectors/read_only/read_ops.rs:88–117`,
and writes supplied rows directly into their destination in
`chunked_vectors/write_ops.rs:70–98`. Its immutable dense reader keeps storage
borrowed until an API explicitly needs owned data. These ownership patterns
inform this adaptation; Akasha's point authority still owns decoded vectors.
Qdrant's `lib/segment/src/segment/entry.rs:402` also makes flush ordering explicit;
Akasha retains its existing authority-first, derived-cache publication protocol.

The rejected bounded output buffer was an Akasha implementation detail, not a
verbatim Qdrant port. It batches small metadata headers and payloads. Every
retained build uses the project compiler, Mojo 1.0.0 (ed45d567).

## Retained memory and capacity evidence

The unconstrained Linux-emulated controls measure anonymous KiB immediately
after collection open:

| Corpus | Baseline | Mapped decoder |
| --- | ---: | ---: |
| uniform-128 | 64,048 | 61,344 |
| uniform-1536 | 123,652 | 115,532 |
| real-1536 | 123,496 | 115,496 |

These are process phase measurements, not exact allocator ownership. All runs
retain the original frozen 32-block mixed plans, query vectors, filters, ef,
write batches and thresholds. Each worker starts with new volume inodes;
separate preparation fsyncs and evicts them, and preparation and execution both
verify zero initial binary-file residency. Workers use one CPU with no swap,
and no concurrent build, test or benchmark workload. Linux x86-64 is emulated
on macOS ARM64: these are correctness and cgroup diagnostics, not native Linux
performance or sustained-duration acceptance.

The retained mapped-input-only candidate passes all three 6 GiB controls, all
four high-dimensional 192/256 MiB cells and all three uniform-128 trials at
128 MiB. Uniform-1536 passes three of three 128 MiB trials. **Real-1536 passes
only two of three**; the third is OOM-killed during block 8 flush after
acknowledging 72 rows. All 4,320 completed-worker responses and 15 reopens match
baseline IDs, F32 score bits, recall, oracle and execution stats. Recovery verifies
all 72 acknowledged rows' bits and complete payloads, plus the next-state exact
oracle. The failed trial remains part of the result.

## Rejected metadata publication candidates

The first writer preflights encoded size, emits one row at a time through a
64 KiB buffer, appends the CRC footer, and preserves file sync, atomic replacement
and directory sync. It avoids the complete metadata payload allocation. A second
writer reuses the row-header allocation and checksums buffered output chunks
instead of each small row header/payload. Both preserve byte-level results.

A 64 MiB payload regression measures additional peak RSS after index construction.
The exact old publication path adds 51,396,608 bytes on macOS and fails the
unchanged 16 MiB ceiling; the first streamed writer adds zero above the existing
construction high-water mark and passes. Zero does not mean no allocation.
An independent frozen 139-byte fixture covers all payload types, UTF-8, signed
zero, negative IDs and a tombstone. Tests also cover retained old mappings,
invalid-input preflight, failed publication and buffered output boundaries.

Both candidates are rejected on unchanged native mixed plans, using six
alternating before/after pairs per corpus. Median candidate/baseline flush time:

| Corpus | First buffered writer | Reused header / chunk CRC |
| --- | ---: | ---: |
| uniform-128 | 1.135x | 1.030x |
| uniform-1536 | 1.081x | 1.028x |
| real-1536 | 1.076x | 1.048x |

All 20,736 response audits, 72 exact reopens and 72 Arrow leases agree across
these two comparisons. Correctness and memory savings do not erase the measured
flush regressions. The rejected writers also have query regressions; every mode
and trial is retained in the archive rather than presented as a speed win.

The first writer's additional capacity matrix passes all controls and 192/256 MiB
cells, uniform-128 three of three, real-1536 three of three, but uniform-1536 only
one of three at 128 MiB. Both failures occur after the reopen marker and before
completion of its exact query/final close; the trace cannot distinguish those
last two phases. All 32 write batches and flushes completed before each OOM.
All 4,608 saved responses match the baseline, including the failed workers' saved
288-query results; 14 completed workers also match their exact reopens.
Unconstrained recovery verifies all 512 acknowledged rows and final exact oracles
from both failed volumes. The original recovery helper rejected this new failure
phase before opening the collection; the extended helper then passed. That
harness failure is preserved. The second writer was rejected after native
measurement, without another Linux capacity matrix.

## Retained validation and acceptance limits

The retained source exactly matches the mapped-input-only source inventory and
Linux Python binary `3660ff30c681071644de971d4cb192bcd23161bc2aa91ddcb3140dbfd5516aa8`.
Its 71 native Mojo cases cover owned/mapped HNSW readers, v1/v2/v3 formats, cache
corruption and publication, mapped subrange bounds, metadata recovery, all scalar
kinds, both ANN metrics and lifecycle flags. Sixteen Linux-emulated cases also
pass the bounded reader, unaligned HNSW decode and mapped-cache ownership checks.
The rejected writers add five distinct native test cases, not claimed as retained
feature coverage.

Six retained native alternating pairs per corpus audit another 10,368 responses,
36 exact reopens and 36 Arrow leases, all matching the same frozen plans. Median
ratios against baseline (lower flush/p95 and higher QPS are better):

| Corpus | Flush time | Selective QPS | Selective p95 |
| --- | ---: | ---: | ---: |
| uniform-128 | 1.001x | 0.978x | 1.017x |
| uniform-1536 | 0.989x | 0.986x | 1.034x |
| real-1536 | 0.996x | 1.020x | 0.932x |

This retained change is a cache-input memory improvement, not a general speed
win. Regressions remain: uniform-128 independent p95 is 1.056x, uniform-1536
all p95 1.024x, and real-1536 all p95 1.155x. No tolerance or cross-cell offset
turns them into passes. All per-mode and per-trial measurements are archived.

The installed native Python binary is
`f4d7736f453e8e0187860f6dd15eb998b586083bcf9a4ef6dd0a84cf98a55067`.
Python/distributed validation passes 388 tests. One optional Qdrant-adapter case
remains skipped because the pinned Edge wheel is absent from the previously
recorded dependency path; the separate targeted retry confirms that reason and
passes the Akasha counterpart. This is not a fresh Qdrant runtime parity result.
No formal Qdrant gate is closed. The last formal checkpoint remains `45e04d2`;
full type/lifecycle coverage, sustained maintenance/lease capacity, concurrency
scaling and native Linux performance remain required. Point recovery still
materializes owned vectors and remains the largest measured open-time increase.
Metadata output still materializes its complete encoded payload; replacing it
requires a design that also avoids the measured write-path regression.

## Evidence

[Complete evidence archive](results/2026-10-19-mapped-cache-stream.json.gz):
1,231 text artifacts, 6,830,431 bytes, SHA-256
`14b74e0e92f985860f1712e8b277e3e602291b6442019c45cebf3afdd81c9d00`. It retains immutable source inventories and full candidate
source, binary identities, all native pairs, successful/failed capacity workers,
recovery audits, test logs and the rejected streaming implementations.
