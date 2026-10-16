# F32 point codec: remove scalar packing from streamed compaction

The point codec now reuses the existing bounded F32 tape reader/writer for dense
and multivector fields. This targets the flush regression introduced by streamed
compaction while retaining its two-pass preflight, bounded record ownership and
unchanged persistence protocol. Other scalar kinds keep their existing native
encoders. No durable version, numerical conversion or acceptance threshold
changes.

## Attribution and implementation

An isolated native probe times open/header/CRC, preflight decoding, output-pass
decoding, record encoding, write/CRC and fsync for a 64 MiB F32 checkpoint. Four
separate source snapshots vary only F32 reading, writing, or both. All are built
before any timed worker starts. Five observations per variant produce the same
output CRC, but the sequential variant order is a diagnostic rather than a
paired performance acceptance.

| Variant | Preflight decode ms | Output-pass decode ms | Encode ms | Write/CRC ms | Total ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| original scalar loops | 84.833 | 84.325 | 29.398 | 25.443 | 235.666 |
| bulk reader | 9.141 | 10.323 | 29.339 | 53.898 | 112.166 |
| bulk writer | 85.439 | 83.845 | 6.467 | 74.671 | 260.262 |
| both | 8.808 | 10.361 | 6.547 | 23.854 | 59.889 |

These are independent medians, so columns do not sum to the median total.
The write-only total regresses in this diagnostic and is retained; variable
write/CRC wall time is not used to infer an exact I/O cause. Both reader variants
remove the dominant scalar decoding time, and both writer variants reduce
encoding time. Uninstrumented end-to-end comparisons below decide the change.

`BinaryWriter.write_f32s` and `BorrowedBinaryReader.read_f32s` already preserve
little-endian native bits, validate counts before allocation/copy, and support
unaligned byte sources. The point codec now calls them under an F32 specialization
instead of appending/assembling each scalar. Existing shape, finite-value,
record-size and catalog checks remain in place. The decoded tape remains owned;
there is no pointer into the input buffer. [Mojo 1.0's checked type refinement](https://mojolang.org/docs/std/builtin/rebind/rebind_var/)
moves the reader's list without adding a copy; the project compiler validates
all instantiated scalar paths.

This follows the pinned Qdrant `segment_constructor/batched_reader.rs` pattern of
moving native scalar representations through storage iterators. Akasha's
existing format and helpers supply the actual implementation; no package or
extra byte-buffer abstraction is added.

A new independent little-endian fixture test covers 4,097-component dense and
two-row multivectors with signed zero, subnormal, smallest normal, largest finite
and ordinary F32 bit patterns. It decodes an unaligned span, destroys the input
tape, and compares re-encoding with the oracle. NaN and both infinities at the
last component must still fail. Existing frozen typed records/envelopes,
truncation/shape tests, migration, recovery, backup and compaction checks remain
part of validation.

## Direct native comparisons

Three alternating before/after pairs per corpus compare the uninstrumented
candidate with `d073cec`, and another three compare it directly with `55707fa`
(the version before streamed point compaction). All 10,368 query/score-bit/statistic
audits, 36 exact reopens and 36 Arrow leases pass. Ratios below are after/before
medians across the three pairs; open and flush times are measured separately.

| Baseline | Corpus | Total flush-time ratio | Total write-time ratio | Open-time ratio | Process peak RSS ratio |
| --- | --- | ---: | ---: | ---: | ---: |
| streamed compaction, d073cec | uniform-128 | 1.012 | 0.996 | 0.943 | 0.996 |
| streamed compaction, d073cec | uniform-1536 | 0.648 | 1.019 | 0.716 | 0.998 |
| streamed compaction, d073cec | real-1536 | 0.515 | 0.997 | 0.691 | 1.001 |
| before streamed compaction, 55707fa | uniform-128 | 0.970 | 0.927 | 0.949 | 0.772 |
| before streamed compaction, 55707fa | uniform-1536 | 1.014 | 1.012 | 0.719 | 0.577 |
| before streamed compaction, 55707fa | real-1536 | 0.776 | 1.002 | 0.688 | 0.570 |

The large high-dimensional flush regression is reduced substantially, while
uniform-1536 remains 1.4% slower than the direct pre-stream baseline. This is
not a full write-speed acceptance. The extra decoded preflight remains; its
scalar unpacking cost has been removed without changing validation order.

**Mixed query timing regresses in several cells.** Against `d073cec`, median
QPS ratios range 0.925–1.015 and p95 ratios 0.853–1.590. Real-1536 selective is
0.925 QPS / 1.590 p95; uniform-1536 selective is 0.931 / 1.205, correlated
0.971 / 1.139 and independent 0.971 / 1.136. Against the direct pre-stream
baseline, median QPS ranges 0.971–1.080 and p95 0.794–1.125; real selective
remains 0.971 / 1.125. Complete trial rows are retained.

The codec callers are WAL, checkpoint/recovery and compaction paths; unchanged
query results/statistics do not prove unchanged latency. The exact cause of
these timing regressions is unresolved. A fixed-state query control and
per-thread background timing are the next discriminating checks. No claim of
GC, allocator, binary layout or I/O causation is made from these aggregate
ratios. These paired diagnostics do not replace the formal Qdrant M5/M6 gates.

## Capacity and recovery

The previous streamed workload remains unchanged: N=8192 Dot/F32, 32 blocks,
frozen plans/ef, one CPU, zero swap, separate 6144 MiB preparation containers,
and verified zero initial `.bin` residency. Workers run serially without build,
test or compression overlap. This is emulated Linux x86-64 on an ARM Mac.

All three 6144 MiB controls and all three uniform-128 capped cells complete.
Both high-dimensional corpora complete at 192/256 MiB in **3/3 trials each**,
preserving the preceding compaction improvement. The initial matrix completes
10/12 workers; eight additional repetitions pass. All 5,184 completed responses
match prior controls, all mode means meet recall 0.95, and all 18 exact reopens
pass. Both 128 MiB workers still OOM before flush at block zero. Same-volume
uncapped recovery verifies all 16 acknowledged updated rows from two batches,
including native bits, complete payloads and exact oracles. No response audit
is claimed for incomplete query snapshots in those killed workers.

The 64 MiB compaction memory test remains below its 96 MiB growth bound on both
runtimes. Recorded peak growth is 33,914,880 bytes on macOS and 2,383,872 bytes
under Linux emulation. High-water differences depend on setup peaks and mapping
residency, so these are not claims of a new retained-memory reduction versus
the previous writer. The direct paired process peaks above are the relevant
end-to-end comparison.

## Validation and evidence

94 relevant native Mojo/codec/compaction/recovery/crash cases, 388
Python/distributed cases (one skip, three existing warnings), rebuilt C bindings
and 27 targeted Linux Mojo cases pass. Initial generic type/ownership compiler
errors in the isolated probe and one test's missing explicit span are retained,
corrected and excluded from performance results. The final project compiler is
Mojo 1.0.0 (`ed45d567`). There is no GPU code change.

- Parent baseline native: `8ac64e14a7ddd3a0ba895de95b0c6588b1b8891e3c84dbc618608ea11cc38d5d`.
- Pre-stream native: `d3a5120ccc489a3b13e7dbf53be29d5d3bebc2705d8c6e2a6c00d7c2d4fcd96b`.
- Candidate native: `5caff7a35db0edca7b9ad94f919a5c892b4a3c0eb828d5ac1546ca5363f69d78`.
- Candidate Linux: `ec967d19fb003f1bfc0a029274abcc950e5d874daaf5969ce29309cbfb107c01`.

128 MiB pressure, mixed query tails, remaining flush-speed acceptance, full
sustained/type/lifecycle coverage, concurrency, native Linux and strict Qdrant
speed remain open. Thresholds and scope are unchanged.

[Evidence archive](results/2026-10-16-point-codec-tapes.json.gz): 375 text artifacts,
2,386,529 bytes, SHA-256
`92c57209242b7ca8749637cef41b7a4d44af48016f80c52172945afbe6049daa`. It retains probe sources and errors, final source identities,
validation, both direct native comparisons, capacity repetitions and OOM
recoveries. Every embedded hash verifies.
