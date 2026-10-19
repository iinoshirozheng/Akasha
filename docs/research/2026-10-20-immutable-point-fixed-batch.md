# Fixed optional-row buffers: rejected performance candidate

Replacing the borrowed-pair List with a fixed local Array does not resolve the
HNSW batch regression. All nine paired ANN rerank aggregates are slower, by
2.8–10.4%. The six 1536-dimensional groups regress in both trials; the three
128-dimensional groups reverse direction between trials. Fresh strict mixed
results are **18/36 production, 16/36 prior candidate and 15/36 fixed-buffer
candidate**, with five production and two prior pass-to-fail cells retained.
This candidate is rejected for further integration. Continue from the verified
[HNSW List-batch source](2026-10-20-immutable-point-hnsw-batch.md), not this
Array variant. Production remains `a6822c3`; M5/M6 remain open.

## Reference and implementation

The experiment tests the remaining buffer-allocation difference identified in
`812f06a`. Qdrant's pinned
[`for_each_in_batch`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/dense/immutable_dense_vectors.rs)
uses a local array with the
[`64` row limit](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/common.rs).
Akasha retains its original 32 score pairs to preserve arithmetic and order.

Exactly three files differ from the prior candidate. Both authoritative HNSW
rerank methods and the selective exact helper replace the List with
`Array[Optional[_DenseScorePair], 32]` and an initialized-prefix count. Each slot
is assigned before its count increases; scoring only reads that prefix. A short
final batch cannot read stale slots from an earlier batch. Slots retain borrowed
views of the same immutably borrowed table; no owner clones or numeric copies
are introduced. The existing source/filter checks, pending-error handling,
partial lookup counters and pair-scoring kernels are unchanged.

The pair record adds `Copyable` solely to support initialization with empty
Optionals. Its fields contain IDs and borrowed row descriptors. Filling empty
slots copies no vector or owner. The fixed buffer has no List allocation or
capacity growth, but still has Optional state and checked access.

The [current Array documentation](https://mojolang.org/docs/std/collections/array/Array/)
describes a default initializer that the installed **Mojo 1.0.0 (ed45d567)** does
not provide. The first compile rejection and its two source files are retained.
The compiled candidate uses the supported `fill=` initializer with empty
Optionals. It introduces no unsafe uninitialized reads or origin conversions.

## Validation and identities

- **113 unique CPU cases in 14 modules** pass: the inherited three-case frozen
  rerank comparison plus 110 cases in 13 query/HNSW/storage modules. They cover
  all metrics, several dimensions, multiple full batches and tails, exact bits,
  missing/wrong-scalar fields, source/filter rejection, score errors and partial
  counters. These are reruns against changed sources, not newly added coverage.
- **379 Python cases** pass, with the candidate native SHA-256 verified in four
  launcher processes. Source-probe tests still inspect repository source;
  candidate-library execution is separately identified.
- Candidate **C ABI** build, strict C11 compilation and execution pass.
- All product builds/tests use the frozen 132-file source inventory. Persistence,
  GPU, formats, query parameters and public owned getters are unchanged. No new
  crash, actual-GPU, sustained-capacity or native Linux result is claimed.

Python native SHA-256:
`06f1ce664c952d1debe24037d576653286901c399d333a062d68fa333d2ec91d`.
C native SHA-256:
`1f7c573580fb4cd2eb5c9126c8551ded414d99dbb23f1ed23f3175b38674b033`.

## Balanced phase diagnosis

The verified prior diagnostic binary is reused. Its reconstructed 132-file
source inventory exactly matches the parent diagnostic inventory. The candidate
is compiled with the same phase/rerank instrumentation. Twelve serial workers
run prior/candidate then candidate/prior for each corpus. All **3,456 timed
responses, 12 exact reopens and 12 Arrow leases** match the frozen reference,
including IDs, score bits, statistics, recall and execution route. All 36 warmups
are separately retained; no timed sample is dropped. The 2,592 ANN calls each
rerank once; the 864 planned-exact calls do not rerank.

Values below are medians of two trial medians, in microseconds:

| Corpus | Mode | List rerank | Array rerank | Slower | List core | Array core |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | all | 32.75 | 35.50 | 8.4% | 383.75 | 378.00 |
| uniform-128 | correlated | 63.25 | 65.00 | 2.8% | 428.75 | 423.50 |
| uniform-128 | independent | 61.25 | 63.25 | 3.3% | 425.00 | 417.75 |
| uniform-1536 | all | 358.00 | 388.00 | 8.4% | 2545.50 | 2577.75 |
| uniform-1536 | correlated | 258.75 | 270.25 | 4.4% | 1258.50 | 1263.75 |
| uniform-1536 | independent | 265.25 | 276.00 | 4.1% | 1272.50 | 1277.25 |
| real-1536 | all | 24.00 | 26.50 | 10.4% | 320.00 | 326.50 |
| real-1536 | correlated | 165.50 | 175.25 | 5.9% | 717.75 | 727.75 |
| real-1536 | independent | 92.50 | 96.25 | 4.1% | 451.25 | 461.25 |

For uniform-128, each first trial rerank is slower and each second trial faster,
so its aggregate regression is not a consistent per-trial result. Its full core
aggregate also decreases despite the higher rerank aggregate. The six high-
dimensional rerank regressions are directionally consistent across both trials.
Neither stage aggregates nor differing historical batches prove an end-to-end
benefit or a particular generated-code cause.

Selective exact core medians change 23.50→22.50, 73.50→72.75 and 79.00→78.50 µs.
Total selective writer waits across 144 timed queries per variant/corpus change
2959→657, 1134→1204 and 16→1896 µs. Waits remain separate from scoring cost.
Observed clock resolution is 1 µs; zero phase medians do not mean zero work.

## Fixed uninstrumented comparison

Thirty-six serial workers compare production, prior List batches, fixed Array
batches and native Qdrant Edge 0.8.0. Three corpora, three trials, frozen seeds,
plans, ef, oracle and mixed read/upsert/flush schedule are unchanged. Order uses
three of four rotations and is not fully balanced. Builds, validation, profiling
and compression do not overlap timed workers.

All **10,368 responses, 36 exact reopens and 27 Akasha Arrow leases** pass their
audits. Akasha IDs, F32 bits, statistics and routes match exactly, with all 36
Akasha recall cells passing. Matched quality remains 33/36: the three unchanged
real-correlated Qdrant cells have recall .945833 versus Akasha's .980556. These
failures remain; no pending ef-calibration decision is treated as approval.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 18/36 | 9/9 |
| Prior List batches | 33/36 | 16/36 | 9/9 |
| Fixed Array batches | 33/36 | 15/36 | 9/9 |

Median within-batch ratios; QPS improves above 1, p95 below 1. These summaries
do not replace individual trial requirements:

| Corpus | Mode | QPS / production | p95 / production | QPS / prior | p95 / prior |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.928 | 1.068 | 0.994 | 1.003 |
| uniform-128 | correlated | 0.948 | 0.979 | 0.980 | 1.034 |
| uniform-128 | independent | 0.977 | 0.915 | 1.001 | 0.978 |
| uniform-128 | selective | 0.780 | 0.995 | 0.880 | 0.963 |
| uniform-1536 | all | 1.017 | 0.999 | 0.985 | 1.023 |
| uniform-1536 | correlated | 0.989 | 0.987 | 0.988 | 0.948 |
| uniform-1536 | independent | 1.009 | 0.998 | 0.992 | 0.951 |
| uniform-1536 | selective | 0.919 | 0.882 | 0.944 | 0.954 |
| real-1536 | all | 1.033 | 0.789 | 1.002 | 1.028 |
| real-1536 | correlated | 0.996 | 0.963 | 0.998 | 0.954 |
| real-1536 | independent | 0.926 | 1.715 | 0.983 | 1.056 |
| real-1536 | selective | 1.044 | 0.988 | 1.008 | 0.994 |

Five production pass-to-fail cells remain: uniform-128 trial 1 selective and
trial 2 correlated, uniform-1536 trial 0 selective, and real-1536 trials 0 and 2
independent. The two prior pass-to-fail cells are uniform-128 trial 1 selective
and uniform-1536 trial 0 selective. The same-batch prior is 16/36; the previous
report's 22/36 is a separate historical batch. Combined write-plus-flush is the
durability-relevant comparison; raw update timings have different semantics.

## Decision and remaining work

Do not carry this Array-of-Optional variant forward. Removing the List allocation
did not yield the required improvement. Qdrant's
[`maybe_uninit_fill_from`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/common/common/src/maybe_uninit.rs)
tracks a fully initialized prefix of uninitialized storage; it does not use an
outer Optional for every row. That is a concrete remaining representation
difference, but these timings do not establish Optional checks or stack traffic
as the cause. Next inspect/test that prefix protocol using compiler-supported
APIs and explicit cleanup on all error paths, starting from the prior source.
Retain all lifetime, arithmetic, error-order and partial-counter tests.

Publication interference and the rest of ANN core time also remain open. Full
warm/concurrent performance, sustained nonresident capacity under equal limits,
integration/example and native Linux gates are still required. No production
adoption, relaxed threshold or M5/M6 completion is claimed.

The [evidence archive](2026-10-20-immutable-point-fixed-batch.json.gz) contains
complete product and both diagnostic sources, the implementation diff, inherited
test sources, the initial compiler rejection, all validation logs, 36 mixed and
12 diagnostic reports/logs, phase/rerank traces and seven pinned Qdrant files
including LICENSE. Parent source/archive, native identities and embedded text
hashes are verified; binaries and copied databases are excluded. It contains
**856 text artifacts, 3,236,760 compressed bytes**, SHA-256
`96165052bdc457835277ae7138cd3d9dca42d690ca5dbb3972a293a200d957d5`.
