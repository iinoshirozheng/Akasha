# Native filtered ANN sampling

Four serial ten-second native `sample` captures locate remaining real-1536
filtered ANN work. Production is the ownership-fixed `96e05e2c`; the frozen
mapped ownership candidate is `f500e869`. Each uses its own database copy,
correlated ef32 or independent ef40, and the unchanged 67 query vectors.
Request construction and search are sampled; Python vector lists are prepared
before the active loop. No source change or Qdrant measurement accompanies this
diagnostic.

All samplers and workers exit successfully. All 67 pre/postflight IDs, F32 score
bits, recall and execution statistics match within each capture and between
versions for each mode. The 64-query measured-set recall is .953125 correlated
and .965625 independent; all execute ANN. Repeated queries used for profiling
are not additional independent quality or acceptance observations.

The following are collapsed top-of-stack observations divided by main-thread
samples. Other threads' semaphore waits are excluded from the denominator.

| Mode / version | Main samples | Mapped four-row score | Mapped single-row score | Owned single-row score | Checked authority score |
| --- | ---: | ---: | ---: | ---: | ---: |
| Correlated / production | 7,559 | 33.95% | 6.19% | 7.54% | 10.52% |
| Correlated / mapped | 7,610 | 33.34% | 6.52% | 7.19% | 12.02% |
| Independent / production | 7,572 | 34.59% | 6.63% | 7.22% | 11.28% |
| Independent / mapped | 7,681 | 33.94% | 6.22% | 7.23% | 13.12% |

These percentages localize sampled execution, not exact elapsed-time attribution
or cross-version speed. Sampling perturbs execution and includes bookkeeping.
Merged PCs cannot be counted independently or attributed to one instruction.

The mapped four-row cosine kernel has the same 2,068-byte symbol size in both
binaries. Its merged hot offsets +1512/+1552 identify a fourth-row vector load
and the loop-end comparison. The retained disassembly also shows four separate
range guards in each 16-component iteration. There are no calls in that hot
iteration; this is a concrete reason to investigate grouped range validation,
not evidence that it will improve complete queries.

The next isolated experiment groups four copied mapped chunks under one full
min/max bound check. It must retain closed-owner checks, subtraction-based
bounds, unaligned reads, independent accumulators, original arithmetic and tail
order, slot validation, IDs and statistics. No raw pointer may escape the mapping
operation. Existing checked-MappedBytes/SIMD32/eight-accumulator and immutable
candidate-norm experiments remain rejected; this does not reopen them.

[The raw artifact](2026-10-14-filtered-ann-native-sample.json.gz) retains all four complete traces and audits, worker/sampler
commands, source identities, relevant original source and symbol/disassembly
excerpts. No M5/M6 speed or capacity gate is closed by these captures.

46 files, 331,295 bytes; SHA-256
`642d6d4d3988d97e08284dd63fac9167c9b2c257c872ce899b94337a0390cb3c`.
Archive and all embedded file hashes were verified.
