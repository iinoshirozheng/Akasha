# Immutable owned F32 summary — rejected experiment (2026-10-03)

The candidate passed correctness checks but did not demonstrate an acceptable
public latency improvement. It was **not adopted**. Production source remains
identical to `a710aa5`, and production `_kernel.so` was never replaced.
M5/M6 remains incomplete.

## Change and evidence

[Design](../plans/2026-10-03-owned-f32-summary.md): derive finite status and the
existing SIMD-ordered squared norm when an immutable F32 value takes ownership.
Exact collection scoring reads that summary. Query checks, candidate dimensions,
zero-norm error ordering, raw legacy nonfinite bits and Float32 score arithmetic
remain intact. HNSW traversal/reranking and FlatIndex are unchanged controls.
No durable format, planner, ef, dependency or public API changed.

The prototype changed only `compute/simd.mojo`, `document/vector_value.mojo` and
`api/collection.mojo` in a copied source tree. It adds derived fields to numeric
owners; replacement creates new summaries and recovery rebuilds them from raw
bytes. Local Qdrant ingestion preprocessing informed the experiment, but raw
Akasha values were neither normalized nor replaced.

## Correctness and performance

Three rotating BAQ/AQB/QBA trials per frozen corpus; serial independent
processes, original fixed ef/seeds/filters/K/binding boundaries. No builds,
tests or archive compression overlapped measurement. All samples remain.
The gate is Recall@10 ≥ .95, QPS ≥ Qdrant and p95 ≤ Qdrant in every cell.

| Workload | Baseline strict pass | Candidate strict pass | Audits |
|---|---:|---:|---|
| Warm | 21/36 | 20/36 | 108 quality cells; 6,912 timed queries; 7,236 exact checks |
| Mixed | 25/36 | 25/36 | 108 quality cells; 7,776 timed queries; 27 reopen checks; 18 leases |

All quality cells passed. Baseline/candidate warm results, Float32 score bits,
first queries, warmups and stats matched. Mixed result IDs and bits matched.
Both speed assessments failed; mixed exit 1 represents that failed gate.
Warm uniform-1536 selective trials 0 and 2 moved from pass to fail; mixed
uniform-128 selective trial 2 moved from pass to fail. Aggregate counts and
medians do not offset those cells.

Warm candidate/baseline ratios (all trials 0 / 1 / 2):

| Corpus | Filter | QPS ratios (higher better) | p95 ratios (lower better) |
|---|---|---|---|
| uniform-128 | all | 0.952 / 1.028 / 1.039 | 1.173 / 0.975 / 0.954 |
| uniform-128 | correlated | 0.815 / 1.146 / 1.658 | 1.818 / 1.056 / 0.574 |
| uniform-128 | independent | 0.848 / 0.825 / 1.525 | 1.452 / 1.054 / 0.675 |
| uniform-128 | selective | 1.053 / 1.079 / 1.397 | 0.890 / 0.742 / 0.685 |
| uniform-1536 | all | 1.071 / 1.056 / 1.172 | 1.001 / 1.026 / 0.851 |
| uniform-1536 | correlated | 1.050 / 1.052 / 1.047 | 0.938 / 0.996 / 0.949 |
| uniform-1536 | independent | 1.013 / 1.091 / 1.020 | 0.922 / 0.924 / 0.974 |
| uniform-1536 | selective | 0.773 / 1.275 / 0.985 | 1.485 / 0.749 / 1.085 |
| real-1536 | all | 1.072 / 0.975 / 0.943 | 0.960 / 1.056 / 1.043 |
| real-1536 | correlated | 1.109 / 1.025 / 0.875 | 0.919 / 0.986 / 1.204 |
| real-1536 | independent | 0.967 / 1.013 / 1.052 | 1.047 / 0.983 / 0.933 |
| real-1536 | selective | 1.092 / 1.103 / 0.899 | 0.860 / 0.877 / 1.192 |

Uniform-1536 broad scans show modest QPS gains, but selective tails and 128D
cases regress in individual trials. ANN controls also vary; the experiment
cannot attribute those changes to a specific source-level cause. The data do
not justify retaining the extra owner state.

Mixed write+flush p95 ratios for all three trials are 1.021 / 0.974 / 1.038
(uniform-128), 0.999 / 1.013 / 1.020 (uniform-1536), and 1.184 / 1.043 / 0.998
(real-1536). Reopen-after-writes ratios are 0.984 / 1.007 / 1.003,
1.045 / 1.000 / 1.027, and 0.989 / 1.004 / 1.001 respectively. Peak RSS and
all individual write/flush/open samples are retained. A separate full ingest
comparison was not run after rejection; no ingest or memory improvement is
claimed. No nonresident, memory-limit or concurrency gate was completed.

## Validation scope

Mojo 1.0.0 (ed45d567), Apple M4 / Metal:4:

- 90 existing targeted Mojo tests across 11 files plus 4 new candidate tests.
  These cover vector ownership, query/score bit parity, finite extremes, every
  invalid SIMD lane/tail, zero-norm precedence, dimensions, point state/codec,
  snapshots, named search, MemTable, FlatIndex and persistent collection.
- Isolated Python suite: 354 passed, 1 optional-Qdrant-dependency skip. With the
  pinned dependency added, that test file passed all 16 tests, including the
  skipped case. These are separate invocations, not 370 unique tests.
- The first Python invocation omitted pixi activation: 342 passed, 12 child
  compiler tests failed because `std` was unavailable, 1 skipped. Its log is
  retained. Correcting the environment resolved those failures.
- Baseline and candidate boundary probes passed after correcting two test-only
  compilation errors (definite assignment and List literal syntax); those are
  not semantic regressions. Compiler diagnostics are retained where captured.
- No new complete Mojo/crash/C ABI/examples run is claimed. The prototype was
  isolated throughout; previously applicable production evidence remains valid.

## Reproduction and immutable evidence

Local work: `.build/2026-10-03-vector-summary`, plus the `-warm` and `-mixed`
directories. Drivers are in the archive and must use fresh output directories
for a rerun. Compile the copied binding entry with its own source include:

```bash
rtk proxy pixi run mojo build --target-accelerator=metal:4 --target-cpu=apple-m4 --emit shared-lib -I .build/2026-10-03-vector-summary/after-src .build/2026-10-03-vector-summary/after-src/bindings/python_module.mojo -o .build/2026-10-03-vector-summary/after-python/akashadb/_kernel.so
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD/.build/2026-10-03-vector-summary/after-python:$PWD:$PWD/.build/qdrant-compare/deps" python -m pytest tests/python -q -o pythonpath=
```

Production binary SHA-256:
`3ccdc28c64b16c26277649c1d890c552b437ad357fde30b02067f03a115b3401`.
Rejected candidate binary SHA-256:
`dd6363301e84fde0ae5a4c6f6f2882671bc82a887c32f1728bdabeb3189a4b22`.

[Evidence archive](results/2026-10-03-owned-f32-summary.json.gz): 189 files,
18,670,834 bytes; SHA-256
`55bbe6bb855ec4263b3ce13a22e45a1607089990ab9f5d67a95d02ae3625c047`.
It contains changed baseline/candidate sources, drivers, raw reports, tests,
logs, workload/oracle hashes and final production identity. Source hashes in
benchmark reports describe the production checkout; `source-identity.json`
and `final-identity.json` identify the isolated candidate explicitly.
