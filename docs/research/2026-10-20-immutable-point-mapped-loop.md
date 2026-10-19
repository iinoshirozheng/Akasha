# Reject scoped mapped F32 scoring after the mixed screen

Do not carry this candidate forward. It removes repeated mapped-range checks
from the main SIMD loops, but does not improve the measured high-dimensional
filtered workload. Keep the [deferred-ID candidate](2026-10-20-immutable-point-deferred-id.md)
as the parent for subsequent work. Production remains `a6822c3`, and the last
retained strict mixed result remains **25/36**; this screen is not a new Qdrant
acceptance comparison.

## Evidence and implementation

The [corrected native profile](2026-10-20-immutable-point-deferred-profile.md)
identified mapped scoring as a substantial frame. Disassembling the exact
deferred-ID native confirms that its width-16 dot loops still perform mapped
range and optional-base checks on every chunk. The closed-state check is already
outside the SIMD loop. Pinned Qdrant
`21db2f3ff95d50de3a2b88a741312c056fd1762d` passes bounded vector slices from
dense storage to its prepared metric scorer. Its source and license are checked
against the pin and retained with this probe.

The isolated candidate adds `compute/mapped_f32.mojo` and changes only
`index/hnsw_view.mojo` among existing source files. The new private synchronous
kernels validate complete row extents with subtraction/division, then read local
unaligned numeric pointers until the copied score is returned. They follow the
existing `MappedFile.checksum` pattern: no callback, pointer, Span, reader or
owner factory escapes the operation. The implementation accesses mapping state
inside these internal kernels; it adds no public mapped-pointer API or shared
mapping abstraction.

Graph query-dimension and slot/readiness checks retain their order before the
new kernel call. The F32 accumulation width, row accumulators, reduction order,
scalar tails and distance conversion are retained. The obsolete mapped F32
loops are replaced, while packed-scalar paths continue through their existing
checked loads. Admission, heaps, traversal, authoritative rerank, ownership,
query locks and durable formats do not change.

This is a bounded synchronous computation, not the previously rejected factory
that allowed a raw borrow to survive explicit owner closure. Nevertheless,
correctness and a smaller loop alone do not justify adoption.

## Verification and generated code

The new direct-kernel test first fails because its implementation module is
absent. After implementation, it checks deliberately unaligned rows, a
17-component tail, exact dot/L2/cosine scores, every invalid lane, negative and
maximum signed offsets, and closed-owner errors. The focused matrix passes
**117 unique cases in 16 modules**, including mapped graph, traversal,
cancellation, source admission, quantized paths and construction invariants.
The existing four-row cases now also compare mapped scores directly with the
owned graph's scalar scorer, bit for bit, for all three metrics and 14 dimensions.

Two intermediate matrix compilation failures are retained: the initial command
omitted the benchmark test include root, then the graph wrapper required
explicit `Int64` offset conversions. Both are corrected before the successful
matrix and native build. The new direct cases are included in 117, not counted
again as additional coverage.

Exact native SHA-256 values:

- Prior: `64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`.
- Candidate: `8dbb4bb7e99d4a702312b6a7c440883b29c8e71417b560f1b513d9d3953ec622`.

Both new kernels are inlined into the graph wrappers in this native binary.
The selected width-16 dot main loops contain:

| Loop | Prior instructions | Candidate instructions | Prior branches | Candidate branches | Vector FMA instructions, both |
| --- | ---: | ---: | ---: | ---: | ---: |
| One row | 22 | 13 | 4 | 1 | 4 |
| Four rows | 61 | 31 | 10 | 1 | 16 |

The candidate's one remaining branch is the loop backedge. Neither selected
loop contains a function call. These are static counts of the main SIMD loop,
not complete-function costs or elapsed-time estimates. The raw disassembly,
exact function addresses, symbol tables and loop-count analyzer are archived.

## Fixed two-order mixed screen

One candidate build is followed by **12 serial workers**: prior/candidate and
candidate/prior on uniform-128, uniform-1536 and real-1536. Each starts from its
fresh copy of the frozen initial database and executes all 32 blocks of
interleaved reads, writes and flushes. Workload, ef, oracles, timing boundaries
and query modes remain unchanged. No build, test or profiling job overlaps the
timed workers.

All **3,456 timed responses** preserve the retained baseline's IDs, F32 bits,
stats, execution routes, recall and oracles. All **12 exact reopens** and
**12 Arrow leases** pass. The **36 warmup return values are not compared**.
Every order and individual latency remains in the archive.

Median paired candidate/prior ratios follow. QPS above one and p95 below one
are better; these summaries do not replace individual acceptance cells.

| Corpus | Mode | QPS ratio | p95 ratio |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.0230 | .9661 |
| uniform-128 | correlated | .9952 | .9972 |
| uniform-128 | independent | .9977 | 1.0482 |
| uniform-128 | selective | .9594 | 1.1021 |
| uniform-1536 | all | .9942 | 1.0170 |
| uniform-1536 | correlated | .9904 | 1.0295 |
| uniform-1536 | independent | .9957 | 1.0086 |
| uniform-1536 | selective | .9985 | 1.0553 |
| real-1536 | all | .9919 | 1.0188 |
| real-1536 | correlated | .9922 | 1.0208 |
| real-1536 | independent | .9915 | 1.0458 |
| real-1536 | selective | .9915 | 1.0318 |

Uniform-1536 correlated QPS is lower in both orders; independent p95 is higher
in both. The source-unchanged selective control is also retained, including
its regression; timing alone does not assign its cause. There is no consistent
target improvement to justify further acceptance runs for this candidate.

The evidence rules out retaining this particular scoped-loop implementation.
It does not prove that mapped checks are free, or that memory bandwidth is the
remaining bottleneck. Before another mapped arithmetic rewrite, inspect actual
memory-access and candidate working-set behavior from the retained parent.
Authoritative rerank remains required; this result does not authorize removing
it, changing scores, adjusting ef or relaxing any gate.

No fresh strict Qdrant quartets, full CPU/Python/crash/C suite, concurrent-client,
sustained-capacity or native Linux gate is run for this rejected candidate.
All original M5/M6 requirements and the retained candidate's remaining failures
remain open.

[Verified candidate, tests, assembly and screen evidence](2026-10-20-immutable-point-mapped-loop.json.gz):
**522 text artifacts, 1,397,273 bytes**, SHA-256
`e376a4442a7581201025fec5411a97220d9f1d05bde67189ef8b6ba6c9b00b5c`.
The archive contains the complete 133-file candidate source, Python package,
fixtures and logs, all worker reports, drivers, upstream source/license,
native identities, raw assembly, analysis and the rejected decision.
