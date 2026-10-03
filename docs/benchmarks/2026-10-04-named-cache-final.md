# Named cache lifecycle after the filtered-radius fix

The cache reconciliation candidate remains **unadopted**. After the independent
`cc15f37` search correctness fix, a fresh complete lifecycle cohort has no fixed-ef
recall regression and retains a 6–7× first-query benefit. However, **30/36 selected
warmed cells regress in QPS or p95**. Profiles and counters identify the added
inactive-node traversal cost. This is a named resident diagnostic, not a Qdrant
performance pass; M5/M6 remain unfinished.

## Versions and validation reuse

Baseline is current production `cc15f37`, Python SHA-256
`609aeb2b0d721cbc1d84f6aec1bd325a360484cfa72d207600313b342c5cd8d9`.
The candidate is the exact previously tested cache-plus-radius binary,
`d439f24396e3e9a6b6963ae4c361e80820d6a37fadf62c0c348cd6d1df2dc5df`.
Both copied source trees and packages are independently hashed. No implementation,
compiler, tests or production artifacts changed during this follow-up.

Reuse is explicit in `reused-validation.json`: baseline 119 targeted Mojo / 388
full Python / C ABI / three examples, and candidate 128 targeted Mojo / 388 full
Python. Earlier 115 Mojo / 11 crash / C ABI / examples covered the initial cache
candidate without the later radius change; they are not recast as a new combined
run. See [cache evidence](2026-10-04-named-cache-reconcile.md) and
[adopted search fix](2026-10-04-live-filtered-radius.md) for precise scope.
No new full Mojo/crash, HTTP, distributed, Linux, GPU, ASan or nonresident gate ran.

## Complete lifecycle cohort

All 18 serial workers completed: three corpora × three trials × two versions,
AB/BA/AB, fresh databases, 8,192 initial rows, 819 updates, 205 deletions, original
seeds/filters/K=10 and six ef values, all 67 queries per curve. The complete initial
build, updates, flush/close, reopen/first query, full curves and second reopen are
retained. No slow samples or failed recall cells were removed.

Both versions together pass 28,944 ANN live-ID/filter/recall/F64 score audits and
4,824 exact ID checks. Initial and pre-close updated IDs/bits/stats match. After
reconciliation the graph topology differs: 9,816/14,472 paired ID lists match,
none of the stats match, and all 132,399 common-ID F64 score-bit comparisons agree.
Cache CRC/header/slot/live-count checks prove actual reuse; each second reopen
preserves its variant's IDs, bits and stats.

Fixed-ef quality passes **132/216 → 135/216**, with zero pass→fail. All 36 selected
mode/trial cells reach Recall@10 ≥ .95 somewhere on the original grid. The original
84 and candidate 81 below-target cells remain archived. `TARGET_REACHED` means
this diagnostic's recall condition only. At each version's first passing original
ef, **30/36 timing cells** regress in QPS or p95. The archive also retains all
216 same-ef cells and the first common passing ef for every mode/trial.

First query after updates/reopen, milliseconds, all trials:

| Corpus | Trial 0 baseline → candidate | Trial 1 | Trial 2 |
| --- | ---: | ---: | ---: |
| uniform-128 | 6,863.69 → 967.46 | 6,870.09 → 970.58 | 6,873.07 → 964.37 |
| uniform-1536 | 33,104.48 → 4,965.93 | 33,543.79 → 4,966.15 | 33,124.85 → 4,978.55 |
| real-1536 | 17,574.70 → 2,838.78 | 17,492.02 → 2,831.09 | 17,479.56 → 2,837.48 |

Flush, second-reopen and all other phase costs are retained separately; the first
query saving does not offset a failed warmed or maintenance gate.

## Cost diagnosis

At the first **common passing original ef**, all 36 mode/trial pairs show
**1.0986–1.1274×** distance evaluations with reconciliation. Rerank counts are
identical except for a small selective candidate-count difference. Historical
inactive slots still serve navigation; they no longer consume the live retained
radius after `cc15f37`, but scoring/traversing them costs time.

Eight serial native sampling workers cover before/after for four cells, using
clones of the completed cohort's saved graphs. Every repeated query matches its
variant's IDs, F64 bits and complete stats: **53,312 audits**. Each worker runs for
seven seconds with a five-second `/usr/bin/sample` attachment. These instrumented
numbers are diagnostic, not acceptance latency. The profiler accounts for every
main-thread sample and assigns exclusive samples within the binding call, so
nested frames are not double-counted.

| Cell | Mean thread CPU µs before → after | HNSW samples before → after | Native F64 metric samples before → after |
| --- | ---: | ---: | ---: |
| uniform-128 all | 279.50 → 297.51 | 67.19% → 68.63% | 9.09% → 8.83% |
| uniform-1536 all | 3,476.56 → 3,794.15 | 58.10% → 61.59% | 24.95% → 23.29% |
| uniform-1536 selective | 6,702.47 → 7,485.36 | 84.93% → 86.26% | 6.96% → 6.43% |
| real-1536 selective | 3,256.41 → 3,614.43 | 77.39% → 79.26% | 6.96% → 6.85% |

HNSW columns sum the disjoint four-candidate distance, single-candidate distance
and other graph-work categories. Python runtime and other query work account for
the remaining samples. Full raw stacks, per-query wall/thread CPU samples and
category accounting are preserved. This points toward graph mutation/traversal
cost for the cache lifecycle rather than native rerank as the main selective cost.

For a possible next design, upstream hnswlib updates an existing slot, repairs
one/two-hop neighborhoods and reconnects the updated point instead of appending
another slot for the same label. Its implementation is a reference to evaluate,
not an Akasha change or a performance guarantee.
[Upstream updatePoint/repairConnectionsForUpdate](https://raw.githubusercontent.com/nmslib/hnswlib/master/hnswlib/hnswalg.h).
A new design must preserve Akasha's existing public mutation/lifecycle contracts,
owned snapshots, checked metrics, query controls and fixed recall/performance
inputs. The cost of neighborhood repair itself must be measured before adoption.

## Immutable evidence and reproduction

[Archive](results/2026-10-04-named-cache-final.json.gz): **366 text entries,
6,150,032 bytes**, SHA-256
`6d02ac803f9e81b99e44325a044eea38e5bb3a7f1816c462808a63741c603c01`.
Gzip readback and all embedded hashes pass. It contains both complete source/package
trees, artifact/input identities, reused validation records, all lifecycle workers,
all profiles and summaries, and drivers. Corpus/database/binary payloads are
identified by hashes rather than embedded. Previous archives are unchanged.

Temporary workspace: `.build/2026-10-04-named-cache-final`. Read `lifecycle.py` and
`profile.py` before reproducing in new output directories; writing drivers refuse
existing outputs. They use the original `cost-plan-*` workloads and import/hash
guards for saved Python packages. Builds/tests/compression never overlapped these
benchmarks. The compiler/binaries remain Mojo 1.0.0 (`ed45d567`), Apple M4/Metal:4.
Read-only summaries of the completed local reports:

```sh
rtk proxy python3 .build/2026-10-04-named-cache-final/summarize-lifecycle.py
rtk proxy python3 .build/2026-10-04-named-cache-final/summarize-profiles.py
```

There are no active workers. Production stays at `cc15f37`; the larger cache
candidate is isolated. The next concrete investigation is reducing measured
historical-slot traversal cost while preserving current graph/mutation contracts.
