# Paired authoritative HNSW reranking

Authoritative candidate reranking now reuses the existing checked two-row F32
kernel. Saved-graph high-dimensional ANN median QPS improves **7.3–12.6%**,
with improved median p95 in all six high-dimensional ANN cells. Fresh native
Qdrant acceptance remains **FAILED**: warm quality 36/36,
speed 7/36; mixed quality 33/36,
speed 14/36; write+flush 5/9.
No threshold, ef grid, planner rule or dataset was changed.

The [native profile](2026-10-16-hnsw-heap-profile.md) placed 26–29% of real
filtered main-thread top-of-stack observations in checked authority scoring.
This change targets that measured work. Earlier prepared-only reranking was
rejected; this version additionally shares query loads through the already
validated paired exact kernel used by gathered exact scans.

Both filtered and unfiltered candidate loops validate each ID against the
current MemTable and HNSW source membership, then score authoritative vectors
in pairs. Filter eligibility remains checked for every candidate. An odd tail
uses the existing prepared single-row kernel; exact-exhaustion loops keep their
original path. All candidates still receive full finite/dimension validation
and authoritative scores. There is no graph-score shortcut, additional retained
cache, allocation owner, durable change or dependency. Pairing can inspect the
second candidate's ID before scoring the first; any error aborts the operation
without a partial result. Valid-result arithmetic, ordering and counters match.

## Saved-graph comparison

Three serial alternating before/after pairs per corpus use the original graph
bytes, workload, oracle and frozen ef. Each worker performs 31 query passes.
Both versions include the same thread CPU clocks. All **36 paired cells**
preserve result digests, recall arrays and every recorded search statistic.
No builds, tests or archive compression overlap timed workers.

Ratios are after/before medians. All raw individual samples remain in the
archive; repeated passes are timing observations, not independent recall data.

| Corpus | Filter | QPS | p95 | Thread CPU |
| --- | --- | ---: | ---: | ---: |
| uniform-128 | all | 1.015 | 0.974 | 0.985 |
| uniform-128 | correlated | 1.014 | 0.994 | 0.986 |
| uniform-128 | independent | 1.023 | 0.930 | 0.978 |
| uniform-128 | selective | 1.017 | 0.990 | 0.984 |
| uniform-1536 | all | 1.073 | 0.936 | 0.931 |
| uniform-1536 | correlated | 1.093 | 0.902 | 0.915 |
| uniform-1536 | independent | 1.126 | 0.882 | 0.888 |
| uniform-1536 | selective | 1.013 | 0.984 | 0.987 |
| real-1536 | all | 1.084 | 0.888 | 0.923 |
| real-1536 | correlated | 1.102 | 0.875 | 0.908 |
| real-1536 | independent | 1.086 | 0.911 | 0.921 |
| real-1536 | selective | 0.995 | 1.024 | 1.005 |

All nine ANN cells improve median QPS and p95. This does not mean every trial
improves: uniform-128 independent trial 0 has QPS .979 and p95 1.085; real-1536
independent trial 1 has QPS .985 and p95 1.053. Real selective p95 rises in all
three trials (1.016–1.076), on the unchanged planned-exact path. These results
are retained and not offset against another cell. The bounded implementation
is retained for repeated high-dimensional gains without claiming universal
tail improvement or Qdrant speed parity.

## Paired mixed-write diagnostic

A separate 18-worker before/after matrix clones the fresh trial-0 Akasha graphs
and uses the same frozen mixed plans. Three alternating pairs per corpus
preserve every query's IDs, recall, oracle, execution decision and statistics:
5,184 audited query responses, 18 reopen checks and 18 retained leases pass.
These reports do not store score bits; the warm digest and numeric contract
matrix cover score equivalence separately. All 72 individual quality cells pass.

| Corpus | Filter | QPS after/before | p95 after/before |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.005 | 1.044 |
| uniform-128 | correlated | 1.009 | 0.995 |
| uniform-128 | independent | 0.997 | 1.031 |
| uniform-128 | selective | 1.017 | 0.845 |
| uniform-1536 | all | 1.065 | 0.885 |
| uniform-1536 | correlated | 1.088 | 0.953 |
| uniform-1536 | independent | 1.097 | 0.892 |
| uniform-1536 | selective | 1.088 | 0.652 |
| real-1536 | all | 1.031 | 0.951 |
| real-1536 | correlated | 1.107 | 0.945 |
| real-1536 | independent | 1.106 | 0.881 |
| real-1536 | selective | 0.996 | 1.027 |

All 18 high-dimensional ANN QPS pairs improve, and all 18 corresponding p95
pairs improve. Low-dimensional independent p95 regresses in all three pairs
(1.024–1.169), with median QPS .997. Low-dimensional all median p95 also rises
4.4%. These regressions remain open; the change is not described as a universal
mixed-workload improvement. Unchanged exact controls vary, including uniform
1536 selective trial 1 p95 1.725. Write/flush timing is retained in raw reports
but no write optimization is claimed.

## Validation

**70 targeted Mojo tests pass**, including four new rerank cases. Their matrix
compares 2,400 filtered/unfiltered results and counter sets against independent
checked single-row scores across three metrics, ten dimensions, zero through
nine candidates and four K values. Graph vectors intentionally differ from
authority. Tests also reject deleted, missing and filter-ineligible second
candidates; existing pair-kernel tests cover finite extremes, signed zero,
zero cosine, every candidate's checks and scalar tails. Existing segmented,
incremental, native/compact delta and widening suites pass.

Fresh public validation passes **387 Python/distributed tests**, one skip and
three existing warnings, rebuilt C client, all three rebuilt examples and both
quality smokes. The Python binary matches the measured candidate hash. The
previous full 152-file / 1,036-case CPU run remains prior applicable evidence,
not a new full-suite run. The fixed L2 228/240 gate from `3dafe2a` remains
applicable: this patch changes final segmented reranking, not graph search.
No new crash, GPU or native Linux result is claimed.

The first new test draft required an explicit `MetricKind.copy()`; its next
draft incorrectly constructed a zero-capacity oracle heap. Both test-only
failures are retained, followed by the corrected four-case parent and candidate
passes. A runner also named nonexistent `test_hnsw_delta_backends.mojo`; the
actual `test_hnsw_delta_scan.mojo` and remaining checks completed on resume.

Before Python SHA-256: `358cb6212d9caa347fd6ef055aea45fc4f0052cde1f393c9bcfa92dcb3d339b1`.
After Python SHA-256: `0fc4b7268fd9f5ddc1df2dffed64f2c867b6b552806ba4850eb0db23ecb8ddb3`.

## Fresh native acceptance

Each of three corpora has three new build/reopen pairs, with N=8192, Dot F32,
K=10, 64 measured queries and the unchanged symmetric ef grid
10/16/24/32/40/48/64/96/128/256/512/1024. Each engine selects its smallest
recall-passing ef independently of timing. Every worker completes, and every
Akasha build/reopen/mixed report matches the candidate binary hash.

The mixed run interleaves nine queries with an eight-point replacement batch
and flush for each of 32 blocks. It is serial foreground interleaving, not
concurrent-client load. All 5,184 query audits,
18 exact-oracle reopen checks and 9
retained Arrow leases pass. Update-only timing has different durability
boundaries in the engines; combined update+flush uses each block's own sum.

The table gives median Akasha/Qdrant QPS / p95 ratios and individual passed
pairs. Each cell requires QPS >= Qdrant and p95 <= Qdrant with no tolerance.
Previous acceptance snapshots are not paired causal baselines for this run.

Akasha passes recall in all 36 mixed cells. Qdrant's real correlated cell has
recall .9458333333 in all three trials at its frozen warm-selected ef; Akasha
has .9805555556. Those three paired cells fail quality and receive no speed
comparison. Their failures are retained, without retuning or a claimed Akasha
speed win. The initial summary script assumed all cells had speed ratios and
raised a KeyError; the corrected parser explicitly keeps these ratios absent.

| Corpus | Filter | Warm QPS / p95 | Pass | Mixed QPS / p95 | Pass |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.557 / 1.965 | 0/3 | 1.115 / 0.553 | 2/3 |
| uniform-128 | correlated | 0.510 / 2.061 | 0/3 | 0.935 / 0.733 | 1/3 |
| uniform-128 | independent | 0.495 / 2.106 | 0/3 | 0.949 / 0.808 | 0/3 |
| uniform-128 | selective | 1.008 / 0.901 | 2/3 | 1.244 / 1.658 | 1/3 |
| uniform-1536 | all | 1.097 / 0.928 | 3/3 | 1.162 / 0.819 | 3/3 |
| uniform-1536 | correlated | 0.743 / 1.246 | 0/3 | 0.763 / 1.334 | 0/3 |
| uniform-1536 | independent | 0.815 / 1.119 | 0/3 | 0.781 / 1.250 | 0/3 |
| uniform-1536 | selective | 0.965 / 0.956 | 1/3 | 1.007 / 0.882 | 1/3 |
| real-1536 | all | 0.977 / 1.002 | 0/3 | 1.278 / 0.663 | 3/3 |
| real-1536 | correlated | 0.488 / 1.798 | 0/3 | N/A (quality failed) | 0/3 |
| real-1536 | independent | 0.788 / 1.192 | 0/3 | 0.969 / 0.936 | 0/3 |
| real-1536 | selective | 0.976 / 0.956 | 1/3 | 1.451 / 0.574 | 3/3 |

The fixed quality repair is complete, but every failed speed cell remains open.
Native Linux, concurrent-client, sustained nonresident and full type/capacity
matrices remain separate requirements. This resident macOS ARM64 run does not
substitute for them.

## Frozen evidence

The [archive](results/2026-10-16-hnsw-paired-rerank.json.gz) contains
255 files, 7,717,531 bytes, including source snapshots,
patches, all test/driver failures, validation logs, complete saved pairs and
fresh warm/mixed reports. Large mixed vector plans are represented by hashes,
sizes, specs, efs, initial workload hashes and deterministic regeneration
instructions. Graphs, datasets and binaries are not embedded. All embedded
file hashes verify. Archive SHA-256:
`044846d9182974bed0327df7476046513f018ec4a54a57fbaea213b04e371c36`.
