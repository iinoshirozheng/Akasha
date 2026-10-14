# Four-row center/member scoring during pruning — not adopted

An isolated prototype batches the F32 center/member distances required before
adjacency overflow pruning. It passes **127 Mojo / 369 Python cases** and all
54 fixed native workers preserve query IDs, Float32 bits, stats and execution.
It is **not adopted**: warm strict speed changes 25→23/36, mixed 18→19/36, and
write+flush remains 3/9. Four warm pass→fail cells remain. Production is unchanged;
M5/M6 remain incomplete.

## Design and verification

The [write-phase diagnostic](2026-10-14-legacy-write-geometry.md) locates
75–84% of high-dimensional connection time in planning/pruning. Its pair cache
saves few distances and slows writes. This new candidate starts from frozen
production, without that cache or diagnostic clocks.

Production already has a [four-row F32 query kernel](../benchmarks/2026-10-13-four-neighbor-port.md)
that shares query loads and preserves each row's accumulator/reduction order.
The candidate reuses its loop for member/member scoring:

- `_distance_between_four_f32` validates the center slot and complete center
  row, creates an immediate `Span` of owned storage, and returns four copied
  SIMD scores. The view never escapes the immutable storage borrow.
- The shared private width kernel takes `Span[Float32, _]`; the existing
  query entry still takes List and passes its immediate Span. SIMD
  widths, per-row accumulators, reductions, tails and finish operations stay
  identical. No row copy, allocation, stored pointer or new dependency is added.
- `_adjacency_with_candidate` groups complete sets of four only for specialized
  F32 tags 0–2. Every center/member score is already required before selection.
  Candidate insertion order and actual distance counters remain unchanged.
  Remainders and other backends retain individual scoring. Early-exit diversity
  comparisons remain individual and gain no speculative calculations.

Only `hnsw_core.mojo` and `hnsw_storage.mojo` change. Reciprocal publication,
historical bridges, invalid-graph quarantine, query settings and durable formats
are unchanged. Current [official Span documentation](https://mojolang.org/docs/std/collections/span/Span/)
describes the view; the live index serves 1.1.0, so the existing project syntax
and installed **Mojo 1.0.0 (`ed45d567`)** compiler determine compatibility.

Seven new cases cover three metrics' member/member Float32 bits across 14
dimensions including SIMD boundaries/tails and 1536, distinct/repeated/self
slots, every invalid candidate lane and invalid center. Pruning is compared
with the frozen original serial loop at five dimensions, seven capacities,
two levels and equal/non-equal vectors; selection order, actual counts,
historical candidates and unchanged input adjacency are checked. A truncated
center row is rejected before creating its Span.

The original production compilation fails because the new member kernel is
absent; the compiler output is retained. The candidate passes these seven plus
existing four-row, accumulator, links, selection, invariants, mutation,
quantized, segmented, store, filtered and overlay cases: **127 tests in twelve
Mojo files**. Full Python is **369 passed**, no skips, three existing warnings.
The shared library builds without warnings. A harness omission initially
prevented creating `runs/build-first` before invoking the compiler; after
creating the parent directory, only build/Python resumed. Successful Mojo
results were retained instead of repeated.

## Fixed native matrix

All builds, tests, workers and compression run serially on the native Mac.
Each phase has three rotating production/candidate/Qdrant triples per corpus.
Corpora, fixed ef, K, filters, oracle, mixed plans and timing boundaries are
unchanged. Warm completes in 46.01 seconds and mixed in 70.44 seconds. The
mixed driver exits 1 after all nine triples complete because strict gates fail.
All paired results/stats match; mixed retained Arrow leases and exact reopen
oracles pass. No sample is discarded.

| Phase | Quality before / after | Strict speed before / after | Pass→fail / fail→pass |
| --- | ---: | ---: | ---: |
| Warm | 36/36 / 36/36 | 25/36 / 23/36 | 4 / 2 |
| Mixed | 36/36 / 36/36 | 18/36 / 19/36 | 0 / 1 |

Strict speed means QPS ≥ Qdrant and p95 ≤ Qdrant after Recall@10 ≥ .95, without
tolerance. Warm pass→fail cells, using zero-based trials, are uniform-128
selective 1; real-1536 all 1 and 2; real-1536 selective 2. Mixed improvements
do not offset them. Changes in exact paths cannot be attributed to the new
HNSW kernel; causes of the measured variations are unestablished.

All write-only candidate/production QPS ratios:

| Corpus | Trial 0 | Trial 1 | Trial 2 |
| --- | ---: | ---: | ---: |
| Uniform 128 | .9996 | .9925 | 1.0230 |
| Uniform 1536 | 1.0483 | 1.0287 | .9733 |
| Real 1536 | 1.0176 | 1.0454 | 1.0362 |

Real write p95 ratios are .9120/.9392/1.0087. Combined write+flush QPS ratios
are 1.0057/.9928/1.0202 for uniform-128, 1.0291/1.0025/.9792 for uniform-1536,
and .9965/1.0267/1.0212 for real-1536. Both versions pass only uniform-128's
three combined gates. Individual writes have different sync boundaries across
engines and do not establish matched durability parity.

All real filtered query candidate/production ratios:

| Phase / mode | QPS ratios | p95 ratios |
| --- | --- | --- |
| Warm / correlated | 1.0249 / .9931 / .9926 | .9462 / 1.0286 / 1.0064 |
| Warm / independent | 1.0175 / 1.0144 / 1.0272 | .9618 / .9625 / .8840 |
| Mixed / correlated | .9541 / 1.0084 / .9598 | 1.1197 / 1.0167 / 1.1942 |
| Mixed / independent | .9609 / 1.0103 / .9992 | 1.1266 / 1.0217 / .9252 |

These limited gains do not close the write/flush gap or establish acceptance.
Keep production unchanged. Before another pruning variant, inspect the
remaining flush cost and existing overlay-cache contracts/experiments.

## Frozen evidence

The [archive](2026-10-14-hnsw-four-pruning.json.gz) contains **792 files,
19,040,393 bytes**, with all embedded hashes verified: full candidate sources,
production originals, patch, seven new cases, used tests, build identities,
compiler routing audit, harness failure, all 54 workers, full plans and raw
latencies. Candidate source/binary still match their build identity; production
source and Python binary still match the frozen parent.

- Candidate Python SHA-256: `a88d68a39ad0fe19e2b7f2e4bdcd8645a1479d14b40b59a43d168d237458cc30`.
- Production Python SHA-256: `96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c`.
- Archive SHA-256: `f7c278bb90bff0fec8aecc4eb2423d08905fccab9925c067de1196702d1f2987`.

No fresh Linux, capacity/nonresident, C ABI, crash or GPU gate was run for this
unadopted prototype. All outstanding M5/M6 requirements remain active.
