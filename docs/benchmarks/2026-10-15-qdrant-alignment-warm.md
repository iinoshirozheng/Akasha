# Warm acceptance after Qdrant algorithm integration

The unchanged three-corpus warm matrix passes matched Recall@10 >= .95 in
36/36 comparisons, but only **3/36** comparisons pass both speed requirements:
Akasha QPS >= Qdrant and p95 <= Qdrant. Overall acceptance is **FAILED**.
Failed recall cells and failed speed comparisons are retained; none are waived.

This is the initial algorithm-integration snapshot. The later
[four-row scorer report](2026-10-16-qdrant-score-batch.md) records the subsequent
fresh matrix (matched recall 36/36, speed 6/36, still FAILED).

Run directory: `.build/qdrant-alignment/warm-matrix/`. Each corpus has three
fresh, serial trials, alternating engine order. Configuration remains 8,192
points, 64 queries, k=10, seed=12345, Dot/F32 and the symmetric ef grid
`10,16,24,32,40,48,64,96,128,256,512,1024`. Each engine selects its smallest
passing ef; timing does not influence that selection. The service boundary,
filters and real DBpedia 1536D dataset use the existing `qdrant_compare.py`
runner. Reports retain source/binary identities, raw timings, build/reopen phases
and exact-oracle checks. No builds or tests ran concurrently with timed workers.

| Corpus | Filter | Median QPS A/Q | Median p95 A/Q | Passing trials |
| --- | --- | ---: | ---: | ---: |
| uniform-128 | all | 0.250 | 4.200 | 0/3 |
| uniform-128 | correlated | 0.355 | 2.452 | 0/3 |
| uniform-128 | independent | 0.431 | 2.091 | 0/3 |
| uniform-128 | selective | 1.131 | 0.946 | 2/3 |
| uniform-1536 | all | 0.748 | 1.324 | 0/3 |
| uniform-1536 | correlated | 0.489 | 1.985 | 0/3 |
| uniform-1536 | independent | 0.511 | 1.747 | 0/3 |
| uniform-1536 | selective | 0.881 | 1.152 | 1/3 |
| real-1536 | all | 0.678 | 1.436 | 0/3 |
| real-1536 | correlated | 0.283 | 3.127 | 0/3 |
| real-1536 | independent | 0.414 | 2.414 | 0/3 |
| real-1536 | selective | 0.793 | 1.271 | 0/3 |

Medians do not override individual trial failures. Source-aligned construction,
traversal and cardinality routing have not removed Akasha's execution-cost gap.
The measurements alone do not isolate the cost of traversal, authoritative
reranking, filtering or Python result conversion; those require profiling.
This is not a controlled before/after comparison with older archived results.

The separate fixed L2 quality gate still reports `0.9458333333 < .95` at ef64;
the warm matrix's successful ef selection does not waive that gate. OS page
cache was not evicted and no memory limit was imposed. This macOS ARM64 run
does not establish Linux, non-resident, concurrent-maintenance or full M5/M6
acceptance. Subsequent PQ-only work is outside this recorded binary/source
snapshot and does not constitute a new performance measurement.

Reproduction: run `benchmarks/qdrant_compare.py` under the project pixi Python
with `PYTHONPATH=python:.:<pinned-qdrant-edge-0.8.0-directory>`, the ef grid above,
`--trials 3`, and a fresh output path. Use `--dimension 128`, `--dimension 1536`,
or `--real-parquet <dbpedia-1536.parquet>` respectively. The runner exits 1 for
each of these failed corpus results. Consolidated cell medians are recorded in
`warm-matrix/acceptance-summary.json` alongside the complete corpus reports.
