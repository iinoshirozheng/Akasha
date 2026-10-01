# Single-pass checked F32 scores

The authoritative F32 SIMD functions now validate finite values while computing
their score. Cosine computes the dot product and both norms in the same pass.
The four-register/narrow accumulator widths and component reduction order remain
unchanged, as do empty/dimension/nonfinite/zero-norm errors. Prevalidated graph
distance functions are unchanged; legacy input validation remains required.

Seven SIMD tests pass, including bitwise comparison against the established
unchecked accumulators across 14 dimensions, tails, cancellation-prone signed
values and widely varying magnitudes. NaN and both infinities are rejected at
every tested lane/tail on both sides; zero norms and empty inputs are rejected.
The 13 dispatcher, 22 metric, four HNSW quality, eight SQ8, ten PQ and three IVF
tests pass. The rebuilt extension passes all 264 Python tests. These results
supplement the previous complete CPU/crash/C ABI integration; persistence was
not changed by this kernel optimization.

The initial isolated prototype and all its seven paired samples are preserved
in [the kernel report](results/2026-10-01-checked-distance.json). The adoption
measurement uses `benchmarks/checked_distance.py`: separately loaded before/after
extensions, the same unchanged 8,192-row post-mutation databases, three trials
with alternating process order, 64 queries per cell after three warmups. Both
extensions use explicit Apple M4/Metal 4 build targets. Stats and result checks
are outside timing. Every returned ID and score has an identical checksum.
The fixed ANN ef values come from the previous matched-recall report, not from
selecting the fastest timing in this experiment.

Median QPS ratios after/before (all three individual ratios remain in the raw
report):

| Workload | Exact all | Selected approximate all | Exact selective | Selected approximate selective |
| --- | ---: | ---: | ---: | ---: |
| Uniform 128D dot | 1.165 | 1.217 | 0.858 | 1.013 |
| Uniform 1536D dot | 1.281 | 1.318 | 1.006 | 1.040 |
| Real 1536D cosine | 1.646 | 1.082 | 1.299 | 1.297 |

Approximate requests retain the existing planner: uniform selected cells use
exact plans, while real all/correlated/independent cells traverse HNSW. Real ANN
correlated/independent median ratios are 1.039/0.969, with substantial variation
and a slower first after-trial in all three ANN modes. The small selective 128D
exact path also regressed in two trials. Preserve these observations; this is
evidence of faster large exact scans, not a uniform speedup or new Qdrant parity
measurement. The real-data all exact scan still runs slower than ANN, so the
planner's low-ef graph choice remains appropriate.

[Raw paired results](results/2026-10-01-checked-distance-paired.json.gz) contain
binary/workload hashes, raw timings, all result rows and search counters for all
72 paired cells. The saved baseline package is an untracked measurement artifact.
