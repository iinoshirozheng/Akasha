# Immutable point-owner prototype: memory improvement, speed still open

The isolated candidate lowers high-dimensional point-recovery anonymous residency,
but is **not adopted**. Both native mixed comparisons retain query regressions.
Production remains `a6822c3f1b82d69bb06c149e3bfcf15fcac63053`; no public contract,
durable format, search algorithm, ef, oracle or acceptance threshold changed.
The last formal Qdrant checkpoint remains `45e04d2`, not this prototype.

## Qdrant evidence and adaptation

Pinned Qdrant Edge 0.8.0 source
`21db2f3ff95d50de3a2b88a741312c056fd1762d` retains storage ownership and returns
borrowed `Cow` rows from
`lib/segment/src/vector_storage/dense/appendable_dense_vector_storage.rs:81–105`.
`chunked_vectors/read_only/read_ops.rs:88–117` resolves bounded chunk ranges and
selects an access pattern. This is the reference for separating durable row
ownership from explicit owned API access. Akasha adapts that boundary to its
immutable point records and exact-file leases; it does not copy Qdrant's mutable
chunk layout or claim the same runtime cost.

The earlier generic numeric reader allowed a caller-owned mutable List or an
explicitly closeable mapping. Mojo 1.0 permits clearing that List while the reader
is live, so its per-access source checks could not be removed based on origins.
This candidate has a narrower invariant: VectorValue consumes and privately owns
its List, or strongly retains an immutable leased mapping with no early-close API.
Only its private, bounded view can borrow those bytes. Public List access builds
one synchronized immutable cache. Synchronous query List wrappers do not retain
their private view across callbacks or mutation. Negative compile probes reject
owner replacement, escaping the reader and mutating borrowed public results.
This is not a general claim that Mojo origins prevent arbitrary List mutation.

The isolated implementation maps v4/v5 point records through the existing shared
CRC/catalog/field validator. It preserves v4 sparse-zero rejection, v5 sparse-zero
acceptance, current F16 cosine arithmetic and owned public decoder results.
F32/F16/BF16/I8/U8 dense and multivector arms retain native bits. Internal scoring,
fingerprints and encoding use borrowed rows; graph construction explicitly copies
the derived rows it owns. Default exact, snapshot, batch, parallel CPU and rerank
consumers use the private reader. Close detaches the PointStore and MemTable
owners under the writer lock, then drops them outside it; held roots keep their
own owners and remain readable.

## Native behavior and rejected performance candidates

Mojo 1.0.0 (`ed45d567`) builds both native Python libraries. The first candidate
inlines the nested numeric reader factories. The second additionally stores the
checked byte Span in its immutable owner and inlines MemTableEntry's reader.
Each uses three alternating before/after pairs per corpus on the frozen 32-block
mixed plans: 9 reads and 8 upserts plus flush per block, 288 queries per worker.
Builds, tests and timed workers run serially.

All **10,368 recorded responses**, **36 exact reopens** and **36 retained Arrow
leases** agree across the two comparisons. IDs, F32 score bits, recall, oracle,
execution choice and visit statistics match. Those are correctness diagnostics
against current Akasha, not a new Qdrant comparison.

Median candidate/baseline ratios across the three pairs are below. Higher QPS and
lower p95 are better; all other modes and every individual trial are archived.

| Corpus | First selective QPS | First selective p95 | Cached-range selective QPS | Cached-range selective p95 |
| --- | ---: | ---: | ---: | ---: |
| uniform-128 | 0.989 | 1.086 | 0.860 | 1.214 |
| uniform-1536 | 0.868 | 1.197 | 0.883 | 1.133 |
| real-1536 | 0.886 | 1.136 | 0.915 | 1.171 |

One cached-range uniform-128 selective trial has p95 **4.551x** baseline. It is
retained, without assigning an unsupported cause or excluding it. Other ANN modes
also regress. macOS peak RSS does not show a high-dimensional improvement; that
high-water measurement is not anonymous point-vector residency.

A separate 8,192-row scoring diagnostic localizes reader overhead. Explicit
factory inlining reduces the initial 128D mapped/List latency ratios from
1.43–1.96 to 1.04–1.08; a register-passable reader trial does not resolve it and
is reverted. A final five-mode diagnostic compares owned/List, owned/private view,
offset-1 mapped rows and aligned mapped rows. Across dot/L2/cosine, aligned versus
unaligned median latency is 0.977–1.011 at 128D and 0.993–1.000 at 1536D.
All cumulative checksums agree, individual mapped score bits match the List
baseline, and neither mapped owner populates its List cache. This narrow test
does not support attributing the whole-query regression to alignment or changing
the durable format for alignment. Its List baseline uses the candidate value
representation, so it is not a production ABI or formal speed comparison.

## Linux anonymous memory and short capacity results

The cached-range source is identical across native and Linux builds, verified by
all 130 source hashes. Linux x86-64 runs under emulation on the ARM64 host; these
are correctness/cgroup diagnostics, not native Linux performance acceptance.
The frozen input streams, ef, plans and oracles remain unchanged. Each worker
uses a newly copied database, fsync/FADV_DONTNEED preparation, zero initial
binary-file residency verified in both preparation and execution, one CPU and
no swap. The existing baseline controls are from the preceding mapped-cache batch;
no timing claim compares these separate emulated batches.

Anonymous KiB immediately after open, from `/proc` phase markers (whole-process
measurements, not exact allocator ownership):

| Corpus | Current production baseline | Mapped point candidate | Reduction |
| --- | ---: | ---: | ---: |
| uniform-128 | 61,344 | 61,184 | 160 |
| uniform-1536 | 115,532 | 64,136 | 51,396 |
| real-1536 | 115,496 | 64,084 | 51,412 |

All three 6 GiB controls and all **9/9 trials at 128 MiB** exit successfully with
no OOM. The previous production matrix passed only 2/3 real-1536 trials at that
cap. Each new worker completes 32 write batches, 32 flushes and its exact reopen.
All **3,456 query responses and 12 reopens** match the prior pinned controls in
IDs, F32 bits, recall, oracles and statistics. This is a short matrix, not the
sustained maintenance/lease or last-four-pass nonresident gate. Live flush does
not yet replace numeric authority with the newly published mapping, so long-run
ownership and residency remain open even though reopen now saves memory.

## Validation, limitations and next step

The archive contains **67 distinct passing Mojo cases** for SIMD/paired/native
metrics, all mapped scalar owners, cache publication, MemTable, point codec,
v4/v5 record validation, exact search, batch/parallel search, leases and close.
Six expected negative compilation cases fail with the intended diagnostics.
Fourteen directly relevant cases were rerun after caching the immutable range;
these are not counted twice. The new close/reopen case proves zero eager List
materialization, held-root query validity and exact-file reclamation after its
last owner drops. Its filename/test name does not establish separate scalar
report coverage. Eight additional recovery/store-search cases ran successfully
but lack archived logs and are excluded from the 67-case evidence count.

The restored test directory also contains older unported prototype tests; only
the explicit archived validation manifest is claimed. Full CPU/Python/C/crash
and GPU suites have not passed this candidate. Public Python owned conversion,
Arrow buffer access and GPU preparation still include materializing getters.
Legacy mapped recovery, live typed flush/compaction rebasing, all consumer/type
combinations and the last-owner cleanup/error-reporting paths need completion.
In particular, the recovery-only lease registry and destruction during updates
need an audit before adoption; close's lock discipline does not prove all other
destruction paths safe. No candidate is installed into the production package.

Next localize whole-query cost using the actual recovered MemTable and identical
frozen candidate IDs: compare reader acquisition, direct scoring and end-to-end
selective scans while retaining the same owner and bit-level audit. The packed
row microdiagnostic above cannot isolate record placement or object traversal.
Follow Qdrant's borrowed row/batch boundaries where evidence supports them;
do not introduce a second vector file or change durable layout on the unsupported
alignment assumption. Then finish live publication ownership and every consumer
before rerunning the full fixed acceptance matrix. The pinned Edge Python wheel
must be restored for new Qdrant runtime acceptance; its earlier absence is not a
waiver. Full type/lifecycle, sustained capacity, concurrency and native Linux
gates remain open.

## Reproducible evidence

Native baseline SHA-256:
`f4d7736f453e8e0187860f6dd15eb998b586083bcf9a4ef6dd0a84cf98a55067`.
First candidate:
`6e2722be4c716b594ce6544a708d94b962d772e4e68c6f17dbcab8b7e444c4bc`.
Cached-range candidate:
`90e46a00c8264a59e1619350df738d7fcc1d6324ce79b043ae9b3cb857f7c203`.
Linux cached-range candidate:
`6eae17de71a1b0b8137029b0cc48218b1f7d6c6f37160e493ae34c44750e494c`.

[Evidence archive](2026-10-20-immutable-point-owner.json.gz) retains the isolated
source, prior variant deltas, tests/probes, successful and failed build logs,
native pairs, Linux workers/preparations, input identities, source inventories,
microdiagnostics and the executable post-run audit. Binary/database bytes are
excluded. The archive is a prototype record, not production implementation.
It contains 512 text artifacts, 32,877,176 compressed bytes, SHA-256
`720d443ad1ecf812b393d24d0c1e415965b021fc099a3f347e700b19c75b83b1`;
every embedded artifact hash was verified after decompression. Large generated
assembly is represented by hashes and the extracted call evidence, not embedded.
