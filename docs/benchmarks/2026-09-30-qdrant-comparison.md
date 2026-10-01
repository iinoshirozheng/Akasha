# Matched-recall native Python binding baseline

Status: #59 is implemented and verified in the worktree, including the
128D/1536D synthetic, real-embedding and F16 diagnostic results. Changes remain
uncommitted. This completes the baseline; M6 performance parity is not achieved.

The completed 128D cells show a substantial query-speed gap. At mean Recall@10
>= 0.95, Akasha's no-filter QPS is 0.170–0.183 times Qdrant Edge's across three
fresh trials. No failed-recall cell contributes a speed ratio.

## Contract and provenance

Both engines run natively on the same macOS ARM64 host, through public Python
bindings. Akasha's base commit is `31f27e5` plus the worktree changes recorded by
source SHA-256 in the raw results. Qdrant Edge Python 0.8.0 was downloaded from
official PyPI and its wheel SHA-256 verified before isolated installation. Its
official release workflow used commit
`21db2f3ff95d50de3a2b88a741312c056fd1762d`. The report records the SHA-256 of each
loaded native library, the pinned Mojo version, lockfile, benchmark sources and
data. Native library hashes in this run:

- Akasha: `b18a97e790dc2311bfd9c838503043ae65c7ba5dd1ad2c52480dc874c3c93cda`.
- Qdrant Edge: `746ce4acdbb56db68aaba805bddf52961a083c5ed5da19f16b5ba500114c788d`.

Inputs, installation, commands and exact measurement boundaries are in the
[dataset/runner instructions](../../benchmarks/datasets/README.md). The paired
baseline uses F32, 8,192 initial points, seed 12345, M=24/M0=48,
efConstruction=192, 10% replacements and 205 deletes. Each filter/ef has 64
measured queries after three warmups. The independent Float64 oracle uses the
final live state; both exact APIs must agree. Each engine gets one search thread
and one indexing thread; trials execute sequentially, alternating engine order.
This is an interactive host with OS scheduling, no fixed CPU affinity/frequency
and no imposed process memory cap. The timing spread remains visible.

The six ef values are 32/64/128/256/512/1024. The smallest ef meeting the recall
threshold is selected separately for each engine/filter/trial. Request
construction is timed: excluding Qdrant's native query constructor would omit
its Python-to-Rust conversion cost. Returned-result creation is included;
telemetry, ID validation and the shared NumPy-to-list preparation are excluded.
QPS is reciprocal mean request time at concurrency one, not HTTP throughput.

Qdrant's exact-scan cutoff is set before building to one eighth of initial dense
bytes, in KiB (512 KiB for 128D). This corresponds to Akasha's 1/8 eligible-point
policy for the widely separated filter buckets here. Akasha reports its actual
planner/candidate/fallback counters. Edge 0.8.0 exposes indexed-vector counts
and persisted configuration but no public per-query candidate/fallback counters;
the report does not invent those counters or claim all Edge queries use HNSW.

Both engines flush before queries. Akasha's batch acceptance includes WAL fsync;
Edge's `update` applies the WAL operation and its separate `flush` synchronizes
WAL/segments. Ingest/build and replace/delete/flush stages are retained separately.
The update stage alone is not a durability-equivalent throughput comparison.
The source distinction is visible in Akasha `storage/wal.mojo` and the pinned
Qdrant [`update`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/edge/src/edge_shard/update.rs)
and [`flush`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/edge/src/edge_shard/mod.rs)
implementations.

## Completed 128D uniform dot baseline

Each range below spans the three trials; p50 is the per-trial nearest-rank
latency. Raw results also retain p95/p99 and every individual sample.

| Filter | Akasha / Edge selected ef | Akasha p50 µs | Edge p50 µs | Akasha / Edge QPS |
| --- | --- | ---: | ---: | ---: |
| All | 128 / 128 | 752–826 | 138–144 | 0.170–0.183 |
| ID bucket, about 25% | 128 / 256 | 673–784 | 194–327 | 0.228–0.396 |
| Mixed-ID bucket, about 25% | 128 / 256 | 652–831 | 194–225 | 0.282–0.299 |
| Selective, about 1/32 | 32 / 32 | 54–100 | 36–39 | 0.400–0.689 |

All 12 paired filter/trial cells pass the recall threshold. Akasha uses explicit
exact fallback for the selective filter. These measurements establish a baseline
for further work, not an accepted speed-parity claim.

An initial diagnostic set Edge's full-scan threshold to zero. Its selective
filter remained below the recall threshold even at larger ef, so those cells
are FAILED with no speed ratio. That unsuitable forced-graph configuration is
retained separately and was not silently replaced by the passing planner run.

## Completed 1536D uniform dot baseline

The three repeated trials also pass all 12 paired filter cells. The no-filter
QPS ratio is 0.339–0.397; the two approximately 25% filters have ratios of
0.142–0.166 and 0.152–0.182. The selective ratio is 0.297–0.440. These are
successful recall gates with remaining speed gaps.

| Filter | Akasha / Edge selected ef | Akasha p50 ms | Edge p50 ms |
| --- | --- | ---: | ---: |
| All | 512 / 512 | 6.598–6.817 | 2.328–2.569 |
| ID bucket, about 25% | 512 / 512 | 6.293–6.381 | 0.791–1.097 |
| Mixed-ID bucket, about 25% | 512 / 512 | 6.197–6.427 | 0.873–1.187 |
| Selective, about 1/32 | 32 / 32 | 0.341–0.354 | 0.099–0.135 |

Akasha's F32 recall curve is identical across all three fresh builds:

| ef | All | ID bucket | Mixed-ID bucket |
| ---: | ---: | ---: | ---: |
| 32 | 0.342188 | 0.325000 | 0.370313 |
| 64 | 0.528125 | 0.475000 | 0.534375 |
| 128 | 0.715625 | 0.692188 | 0.746875 |
| 256 | 0.906250 | 0.895313 | 0.915625 |
| 512 | 0.993750 | 0.985938 | 0.982813 |
| 1024 | 1.000000 | 1.000000 | 1.000000 |

The dedicated fresh F16 run exactly reproduces all three historical ef=128
recalls, including the 0.684375 minimum. It uses the same shared workload and
public Python boundary; it is a single-engine diagnostic with no Edge speed
ratio. Graph storage is F16 and authoritative vectors/reranking remain F32.

| ef | F16 all | F16 ID bucket | F16 mixed-ID bucket |
| ---: | ---: | ---: | ---: |
| 128 | 0.715625 | 0.684375 | 0.740625 |
| 256 | 0.909375 | 0.892188 | 0.918750 |
| 512 | 0.993750 | 0.982813 | 0.982813 |
| 1024 | 1.000000 | 1.000000 | 1.000000 |

The near-matching F32 control and improvement with ef support the existing
candidate-coverage explanation: full-precision reranking cannot recover
neighbors absent from the candidate set. The F16 ID-bucket p50 rises from
3.737 ms at ef=128 to 6.537 ms at ef=512 in this diagnostic, showing the cost of
raising recall. All ANN-only diagnostic queries report no exact fallback;
the selective mode explicitly takes exact fallback and remains at recall 1.
No failed-recall ef=128/256 cell contributes a comparative speed claim.

## Historical reopen finding and subsequent fix

The measurements below describe the original baseline. The v5 retained-base
checkpoint/recovery change now preserves an immutable HNSW base plus its bounded
overlay, including background-build catch-up and v3 filename migration. The same
1536D workload subsequently reopened in 2.108 seconds in a single fresh trial;
that is a process-cold result without OS page-cache eviction. See the
[recovery report](2026-10-01-hnsw-base-reopen.md) and
[later SIMD trial](2026-10-01-hnsw-accumulators.md). Repeated final performance
acceptance remains outstanding; the earlier numbers remain as baseline evidence.

Fresh-process open after the shared replacement/delete workload takes
75.367–76.231 seconds for Akasha at 1536D, versus 0.107–0.147 seconds for Edge.
The 128D Akasha first trial takes 8.894 seconds. These costs are recorded
separately from first-query and warm-query latency.

The files and current call path explain the Akasha behavior. The post-mutation
manifest has no HNSW name and no sidecar remains. `SegmentedHnsw.checkpoint_ready`
accepts only an owned base with no delta; the 10% replacements remain below the
configured rebuild threshold. The checkpoint therefore commits authoritative
segments without a complete graph sidecar, and `_load_or_rebuild_hnsw` rebuilds
the graph during open. Query telemetry changes from base plus 819 delta
candidates before close to a rebuilt base with no delta after open. This is an
unresolved cold/open lifecycle performance gap for M5/M6, not a passing speed
gate. The benchmark retains this behavior rather than adding unmeasured
maintenance that would hide its cost.

## Real embeddings and lifecycle costs

All 12 selected real-embedding filter/trial pairs pass the recall threshold.
The workload uses the fixed DBpedia/OpenAI source described in the dataset
instructions: 8,192 initial corpus rows, 819 disjoint replacement rows and 268
disjoint query rows, all cast once to the shared Float32 input. Cosine is used.
Disjoint source-row ranges do not imply semantic deduplication of the corpus.

The no-filter case selects ef=32 for both engines: Akasha recall is 0.990625 and
Edge recall is 0.968750–0.971875. Akasha/Edge QPS is 0.417–0.419. The two 25%
filters select ef=32/128 and ef=64/128 respectively, with QPS ratios
0.344–0.381 and 0.239–0.271. The selective filter has ratio 0.269–0.495.
The different recall curves confirm that the uniform synthetic result does not
describe this real-embedding distribution.

No-filter timing summaries below are medians of the three per-trial statistics,
not percentiles of a pooled distribution. With only 64 measured queries in each
cell, nearest-rank p99 is that trial's maximum; it is a diagnostic tail sample.

| Dataset | Engine | Selected ef | QPS | p50 µs | p95 µs | p99 µs |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Uniform 128D dot | Akasha | 128 | 1,193.3 | 825.1 | 911.1 | 1,073.5 |
| Uniform 128D dot | Edge | 128 | 6,787.8 | 143.8 | 162.1 | 185.8 |
| Uniform 1536D dot | Akasha | 512 | 145.3 | 6,776.4 | 7,359.5 | 8,025.5 |
| Uniform 1536D dot | Edge | 512 | 425.3 | 2,350.5 | 2,509.4 | 2,614.7 |
| Real 1536D cosine | Akasha | 32 | 1,135.8 | 875.4 | 1,022.0 | 1,088.8 |
| Real 1536D cosine | Edge | 32 | 2,714.7 | 365.4 | 418.9 | 456.5 |

Lifecycle medians across the same three trials (seconds):

| Dataset | Engine | Ingest | Build/checkpoint | Replace | Delete | Mutation flush | Fresh-process open |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Uniform 128D | Akasha | 9.450 | 0.215 | 0.677 | 0.009 | 0.033 | 9.038 |
| Uniform 128D | Edge | 0.120 | 2.036 | 0.016 | 0.001 | 0.037 | 0.102 |
| Uniform 1536D | Akasha | 78.482 | 0.631 | 3.232 | 0.009 | 0.142 | 75.761 |
| Uniform 1536D | Edge | 0.318 | 15.196 | 0.037 | 0.001 | 0.045 | 0.121 |
| Real 1536D | Akasha | 39.390 | 0.640 | 2.292 | 0.009 | 0.137 | 37.993 |
| Real 1536D | Edge | 0.308 | 6.925 | 0.035 | 0.001 | 0.044 | 0.109 |

Akasha maintains its mutable HNSW during ingestion and can promote the first
delta graph on flush; Edge constructs its HNSW in the explicit optimize stage.
Compare the combined ingestion/build pipeline with that distinction intact.
Replacement timing also retains the WAL-fsync distinction described above.

Median final process peak RSS / logical disk length in MiB is 141.72 / 10.12
for Akasha versus 222.77 / 199.67 for Edge at uniform 128D; 462.20 / 58.52 versus
549.03 / 307.69 at uniform 1536D; and 528.78 / 58.52 versus 553.17 / 307.55 for
real 1536D. Setup establishes much of the RSS peak. The large Edge file lengths
include preallocated WAL/mapping files; these figures do not measure physical
disk blocks or isolated index allocations.

## Artifacts and verification so far

- [128D planner baseline, full raw data](results/2026-09-30-qdrant-uniform-128.json.gz).
- [128D forced-HNSW diagnostic, including failures](results/2026-09-30-qdrant-forced-hnsw-128.json.gz).
- [1536D planner baseline, full raw data](results/2026-09-30-qdrant-uniform-1536.json.gz).
- [Real DBpedia 1536D cosine baseline, full raw data](results/2026-09-30-qdrant-real-1536.json.gz).
- [F16 recall diagnostic, full raw data](results/2026-09-30-qdrant-f16-diagnostic.json.gz).
- [Machine-readable summary, archive checksums and validation](results/2026-09-30-qdrant-comparison.json).

The deterministic gzip archives retain query IDs, recalls, timings, telemetry,
stage costs, fresh-process reopen results, peak RSS, logical file lengths,
oracle IDs, reproduction commands and the exact as-run benchmark source text.
Each archived source was checked against the recorded benchmark SHA-256;
decompression was checked byte-for-byte. Peak RSS includes the interpreter,
libraries and input arrays. Logical disk bytes use file lengths, including
preallocated WAL/mapping files, rather than filesystem allocated-block counts.
Reopen first-query timing uses a fresh process with the OS page cache intact;
it is not a disk-cold benchmark.

The complete Python suite passes **118 tests** with the optional pinned Edge
dependency available:

```sh
pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps pytest tests/python -q
pixi run env PYTHONPATH=. mojo run -I src -I benchmarks/mojo benchmarks/mojo/qdrant_workload_parity.mojo
```

Seven focused comparison tests pass, including both real native adapters, exact
filter/mutation/reopen checks, deterministic data and corruption rejection,
duplicate/deleted/wrong-filter result rejection, failed recall and failed reopen
gating. The compiled Mojo parity probe passes six cases (two seeds, 8/128/1536D),
comparing shuffled IDs and every initial/replacement/query coordinate against
the existing native generator, plus deletion order. `git diff --check` passes.
The two existing binding `__module__` warnings and Starlette warning remain.
All three paired workloads complete three fresh trials, totaling 36 selected
filter/trial pairs above the recall threshold. The forced-HNSW and single-engine
diagnostic commands intentionally exit nonzero for failed/missing pairs; their
engine operations complete and their raw results remain explicit. No core-engine
changes were made for this runner; previously applicable CPU,
crash, C ABI and quality-gate results remain unchanged.
