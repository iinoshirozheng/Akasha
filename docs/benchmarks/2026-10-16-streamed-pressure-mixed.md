# Streamed mixed lifecycle under constrained memory

The [mapped-cache fix](2026-10-16-cache-map.md) resolves short open/read failures,
but **high-dimensional mixed writes and flushes still exceed 128–256 MiB**.
All three 6144 MiB controls complete. Uniform-128 completes at all three caps;
both 1536-dimensional corpora OOM at every tested cap. The two 256 MiB failures
also occur with the pre-cache-map binary at the same fifth flush, so this is
not a newly introduced failure demonstrated only by the cache-reader change.

## Scope and controls

Current source is `12391b5`, engine `ae2fc7e`; no source change is made for this
probe. The same N=8192 Dot/F32 fixtures, fixed ef values and frozen mixed plans
are reused. A preprocessing process emits one operation per JSONL line: three
warmups, then 32 blocks of nine queries, one eight-point upsert and flush, then
close/reopen with an exact query against the final-state oracle. The constrained
worker loads one operation at a time and uses the public Python batch API. It
does not import NumPy or load the full corpus or full mixed plan. Responses and
small stage records are retained; their memory and logging overhead remain
part of the worker. This harness change is explicit, not an engine-only heap
measurement or a direct speed comparison with the prior NumPy-based harness.

Preparation uses a separate 6144 MiB container, fresh Linux-volume inodes,
fsync/FADV_DONTNEED and zero initial `.bin` residency verified by both workers.
Every measurement has one CPU, zero swap and its stated memory cap. Jobs run
serially without compilation/tests/compression overlap. The runtime remains
**emulated Linux x86-64 on the ARM Mac**, using image
`sha256:540414f50b96439a6ba1475b79b2e2dd2208e86ebef33e2fbf2a176a8f037d31`.
Current binary: `789005c77a9aa053e885437efdf484848cecb86cf4bd218693fe70717d5e0076`.
Pre-cache-map control: `2a11d86596c637aaafd52b41c96a3cbf7a9bf4697684d710c8719f22a35b7e28`.

This first diagnostic uses one worker per cell, not repeated trials or a
long-duration steady-state test. There is no concurrent-client or Arrow-lease
workload in this bounded worker. Its purpose is to expose the next lifecycle
failure before expanding those gates.

## Results

| Corpus | Cap MiB | Completed | Last operation on failure | Acknowledged batches / flushes |
| --- | ---: | --- | --- | ---: |
| uniform-128 | 6144 | yes | — | 32 / 32 |
| uniform-1536 | 6144 | yes | — | 32 / 32 |
| real-1536 | 6144 | yes | — | 32 / 32 |
| uniform-128 | 256 | yes | — | 32 / 32 |
| uniform-1536 | 256 | OOM | before_flush (block 4) | 5 / 4 |
| real-1536 | 256 | OOM | before_flush (block 4) | 5 / 4 |
| uniform-128 | 192 | yes | — | 32 / 32 |
| uniform-1536 | 192 | OOM | before_query (block 3) | 3 / 3 |
| real-1536 | 192 | OOM | before_flush (block 3) | 4 / 3 |
| uniform-128 | 128 | yes | — | 32 / 32 |
| uniform-1536 | 128 | OOM | before_flush (block 0) | 1 / 0 |
| real-1536 | 128 | OOM | before_flush (block 0) | 1 / 0 |

Blocks are zero-based. All six completed workers preserve their 6144 MiB
control's IDs/F32 bits, search statistics and execution paths for all 1,728
queries. All four mode-level mean recalls exceed 0.95; selective exact recall
is 1.0. All six final reopen exact-oracle checks pass. Partial failed workers
are not treated as recall/latency passes. All six current failures are
Docker-confirmed OOM kills (exit 137), with no preparation failure or timeout.

Both pre-cache-map 256 MiB controls also OOM at `before_flush`, block 4, after
five acknowledged batches and four completed flushes. This small baseline
check establishes that particular failure existed before the cache-reader fix;
it is not a full before/after lifecycle matrix.

In the real-1536 6144 MiB control, observed RssAnon rises from 129,704 KiB after
open to 159,324 KiB after the first flush and 235,916 KiB after the fifth.
The maximum sampled RssAnon is 340,672 KiB after block 13. Cgroup peak reaches
about 499.8 MiB, including charged file cache. These observations do not identify
live allocation owners, prove a leak, or allocate the entire peak to a single
checkpoint stage.

## OOM recovery

The same six killed databases are reopened in separate 6144 MiB recovery
workers. All six recover successfully. Every acknowledged updated point is
checked against the streamed batch's exact F32 bits and complete payload:
**152 rows across 19 acknowledged batches**. Each recovery also runs an exact
query against the next-block oracle for that precise acknowledged state; all
six match. These tests establish preservation of those acknowledged updates
through these OOM boundaries, not exhaustive verification of every database row
or all crash windows. Recovery logs and the original killed-worker traces are
both retained.

## Next implementation boundary

The open path is no longer the only capacity bottleneck. The first flush at
128 MiB and later checkpoint/compaction at higher caps need native phase
localization. Source inspection identifies two relevant whole-buffer paths:
`PointStore._checkpoint` encodes an entire segment before writing it, and
`_build_point_compaction` loads a separate owned checkpoint table and encodes
the entire output. Derived cache publication also builds a whole envelope
around an already owned payload. These are candidates, not yet a measured
assignment of the killed allocation. A bounded writer/compaction change must
preserve output bytes, fsync/publication order, CRC and failure recovery.

## Evidence

[Archive](results/2026-10-16-streamed-pressure-mixed.json.gz): 124 files,
390,655 bytes; SHA-256 `4577ea18dd7ec80a2f0423e0878759ba9121bcfe3f466d8d308d6c6170d4082e`. It includes all current and
pre-cache-map jobs, preparations, container inspections, partial/completed
responses, stage traces, recovery checks, conversion/worker drivers and input
identities. The frozen original plans and database inventories are in the
preceding cache-map archive; the included converter reproduces the hash-identified
operation streams. All embedded hashes verify. Native Linux, sustained pressure,
full types/lifecycle, concurrency and strict Qdrant speed gates remain open.
