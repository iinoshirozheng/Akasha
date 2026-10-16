# Streaming point compaction: preserve bytes without a second table

Point compaction now merges validated immutable segment cursors and writes one
record at a time. It no longer loads a separate complete `PointTable` or retains
a whole encoded output. The public checkpoint and publication contracts remain
unchanged. Capacity results are recorded below; isolated memory savings alone
are not a completed lifecycle gate.

## Implementation and references

The pinned Qdrant revision `21db2f3ff95d50de3a2b88a741312c056fd1762d` uses
`for_each_unique_point` in `lib/segment/src/id_tracker/mod.rs`: sorted ID
iterators are merged, the highest version wins, and a winning tombstone removes
the point. `segment_constructor/segment_builder.rs` gathers source descriptors
and `batched_reader.rs` transfers native vector types through storage iterators.
The local RocksDB `table/compaction_merging_iterator` is another reference for
heap-ordered child iterators. Akasha uses the existing Mojo BinaryHeap with
reversed ordering and manifest-order ties, preserving its stricter committed
sequence validation rather than accepting corrupt historical versions.

A complete first pass validates all records, including overwritten/deleted
ones, and counts live output before claiming a file. Rewinding the same mapped
inodes then emits canonical v5 bytes and incremental CRC. This deliberately
trades another decoding pass for bounded decoded storage and an unchanged
header containing the final record count. File fsync, directory fsync,
publication rebase, conflict discard, read-generation pins and retirement remain
on the existing path. Memory depends on fan-in and maximum record size: one
head per input plus the current record/encoding buffer, not a fixed global
constant. The unchanged record cap is 256 MiB.

The cursors release backing file descriptors after header/CRC verification
while retaining the mappings. [POSIX mapping semantics documented by Linux](https://man7.org/linux/man-pages/man2/mmap.2.html)
permit reads after descriptor close. A legal 64-run merge under a descriptor
limit of 32 failed with `Too many open files` before this fix and now matches
the owned recovery/encoding oracle on both supported runtimes. Mapping tests
also check repeated release, empty files, closed-owner rejection and that
closing the mapping never closes an unrelated reused descriptor.

## Isolated memory and compatibility

A streamed fixture contains 4,096 points with a 4,096-component F32 vector
(64 MiB vector data) and one replacement delta. Native macOS compaction peak
RSS growth falls from 112,672,768 bytes to 1,654,784 bytes in the initial
implementation run; final validation observes no increase above the prior
process high-water mark. Emulated Linux final validation observes 67,268,608
bytes, including input mapping residency. These are high-water differences,
not total process footprints or zero-allocation claims. A 96 MiB assertion
fails on the original path and passes on the streamed path.

Exact-byte comparisons cover frozen v4 base/delta and native typed fixtures,
maximum sequence, signed ID extremes, replacement/deletion/rebirth and empty
output. Tests reject overwritten CRC-correct invalid records and nonincreasing
versions before claiming output. A cursor continues reading the original inode
after path replacement. A truncated unpublished output is discarded on reopen
without changing manifest or native F16 values. Existing rebase, pin/reclaim,
backup, point authority and crash-order tests remain required.

## Rejected I/O probe

An isolated 64 KiB FileByteSink syscall-chunk probe was built and tested, but
all six high-dimensional 128/192/256 MiB lifecycle workers still OOM. All six
completed workers preserve 1,728 query audits and all killed databases recover.
No gate improvement was established; the patch was not adopted. It does not
prove the allocator, runtime or kernel allocation owner of the remaining OOMs.
The complete probe is retained with the compaction evidence.

## Uninstrumented capacity and timing

The unchanged streamed workload uses N=8192 Dot/F32, 32 query/write/flush blocks,
frozen plans/ef, one CPU, zero swap, a separate 6144 MiB preparation process and
verified zero initial `.bin` residency. No compilation, tests or compression
overlap the workers. Linux is x86-64 emulation on an ARM Mac, not native Linux.

| Corpus | Cap MiB | Previous result | Current result |
| --- | ---: | --- | --- |
| all three | 6144 | complete | complete |
| uniform-128 | 256 / 192 / 128 | complete | complete |
| uniform-1536 | 256 | OOM before flush block 4 | complete, 3/3 trials |
| real-1536 | 256 | OOM before flush block 4 | complete, 3/3 trials |
| uniform-1536 | 192 | OOM before query block 3 | complete, 3/3 trials |
| real-1536 | 192 | OOM before query block 4 | complete, 3/3 trials |
| uniform-1536 | 128 | OOM before flush block 0 | OOM before flush block 0 |
| real-1536 | 128 | OOM before flush block 0 | OOM before flush block 0 |

The initial matrix improves from 6/12 to **10/12 completed workers**. Its 2,880
completed query responses match the earlier unlimited controls in IDs, F32
bits, statistics and execution paths; all per-mode means meet recall 0.95.
Two additional trials of each newly passing cell add 2,304 matching responses
and eight exact-state reopens. Every completed worker performs 32 writes and
32 flushes. Both remaining kills are Docker-confirmed OOMs. Separate uncapped
workers reopen those same killed databases and verify all 16 acknowledged
updated rows across two batches, including native vector bits, complete
payloads and exact oracles. The partial JSON reports precede query snapshots;
no query-response audit is claimed for those killed workers.

Three alternating native macOS pairs per corpus preserve all 5,184 response
and statistic audits, 18 exact reopens and 18 Arrow leases. Median query QPS
ratios range 1.014–1.127 and p95 ratios 0.530–0.987. These diagnostics are not a
new Qdrant acceptance run. The memory improvement has a material write-path
cost, retained rather than hidden:

| Corpus | Median process peak RSS ratio | Median total flush-time ratio | Median total write-time ratio |
| --- | ---: | ---: | ---: |
| uniform-128 | 0.853 | 1.006 | 0.988 |
| uniform-1536 | 0.607 | 1.539 | 0.985 |
| real-1536 | 0.571 | 1.417 | 0.988 |

Ratios are after/before across three paired trials. Flush totals include the
existing background compaction schedule. The new full decoding preflight and
per-record emission need profiling before attributing this cost to a single
operation. This change closes the observed 192/256 MiB failures for this
32-block workload; **128 MiB pressure, flush speed, full sustained/type/lifecycle
coverage, concurrency, native Linux and strict Qdrant speed remain open**.

## Validation and evidence

Final validation passes 64 relevant Mojo/compaction/recovery/crash cases,
388 Python/distributed cases (one skip, three existing warnings), rebuilt C
bindings, and 27 Mojo cases plus the constrained-descriptor process under Linux
emulation. The first descriptor-limit fixture used a sequence preceding its
catalog's migration cutover and failed for that reason; that invalid attempt
is retained, corrected, and excluded from the descriptor regression claim.
The corrected pre-fix binary fails specifically with descriptor exhaustion.
Initial compiler and fixture-construction errors are also retained alongside
the successful final runs.

- Parent: `55707fa`.
- Native before: `d3a5120ccc489a3b13e7dbf53be29d5d3bebc2705d8c6e2a6c00d7c2d4fcd96b`.
- Native after: `8ac64e14a7ddd3a0ba895de95b0c6588b1b8891e3c84dbc618608ea11cc38d5d`.
- Linux after: `af7fcf22fb06d443a0596827818d005f13c21b4a7dbe03305de6e9b6e47962aa`.

[Evidence archive](results/2026-10-16-point-merge.json.gz): 451 text artifacts,
2,112,425 bytes, SHA-256
`73c7388a3ffe1061d3af28db3a7125a75508f7f2f600a8e477773cb193feed15`. It includes source identities, reference excerpts,
all validation attempts, paired measurements, capacity controls/repetitions,
OOM recovery and the rejected I/O probe. Every embedded hash verifies.
