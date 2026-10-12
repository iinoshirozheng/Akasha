# Native mapped exact sampling — 2026-10-13

Two serial 10-second `sample` captures compare production (`45b24374`) and the frozen
kernel-inline candidate (`9aad206d`) on uniform-128 all-mode planned exact, ef128.
Each uses a private database copy and the same 67 query vectors repeatedly. All
samplers/workers exit successfully; all 67 pre/postflight IDs, F32 bits and stats
match within and across versions. No engine source changes accompany this diagnostic.

The worker includes request construction/search in the active loop; correctness and
stats audits are outside it. This is neither a speed gate nor a capacity gate.
Sampling includes startup/bookkeeping and perturbs execution. Completed query counts
(83,616 / 55,677) are diagnostic workload counts, not comparable benchmark QPS.
Sample merges PCs and counts recursive frames; a merged count cannot be assigned
to one instruction or treated as an independent sample for every displayed address.

Merged hot candidate PCs include `_search_candidates` +2492/+2576, respectively SIMD
loads and the multiply/accumulate loop. Nearby instructions still perform per-chunk
range comparisons and flag calculation (`ccmp`, `cset`, `cmp`, `cset`). Production's
merged checked-kernel +292/+296 PCs are in its simpler arithmetic loop. Raw traces,
matching native symbol ranges and short instruction excerpts are retained. This is
a lead about loop cost, not proof that any proposed rewrite is faster.

Next test a bounded SIMD prefix on the frozen kernel-inline source. Determine the
largest complete prefix that every captured source can read, use the existing
unaligned loads/arithmetic inside it, then execute checked reads at the first missing
chunk before finite reduction. Scalar tails retain per-access checks. This must
preserve shortened-source/closed-map and first-error order, including paired and
prevalidated kernels; no general-reader raw pointer cache or duplicate fallback
kernel is proposed. M5/M6, capacity/mixed gates and production adoption remain open.

[Drivers, audits, native traces and assembly excerpts](2026-10-13-mapped-native-sample.json.gz)
contain 41 files and 385,173 compressed bytes, SHA-256
`c6ecad4ae9ff6fbf496a184e2123f549bc36c7495806e80dc75f23f5b227de94`. Archive and embedded file hashes were verified.
The complete sampled candidate source/package is retained in the
[kernel-inline artifact](2026-10-13-mapped-kernel-inline.md).
