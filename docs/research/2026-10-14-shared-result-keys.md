# Reusing Python result keys — not adopted

The isolated candidate reuses the Python `id` and `score` keys within each search
result batch. Both row builders use the public Mojo 1.0.0
`Python.dict(Span[Tuple[PythonObject, PythonObject]])` constructor; each output
dictionary owns independent values. There is no global cache, engine change,
public API change or durable-format change. The parent is the adopted
[result ownership fix](2026-10-14-production-result-ownership.md), binary
`96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c`.
Candidate binary is
`e0d969521ff4dd3bd0e9a8539b6b8293ebfc8d24013760d2f03710fc6d90d9a0`.

The microprobe validates sizes 0/1/10/100, key order, values, independent mutable
rows and release of every attached weakref sentinel. Both builders retain only
32 traced bytes after 512 discarded calls. Fifteen serial alternating diagnostic
rounds, including result destruction, give these median times:

| Rows | Existing keyword builder | Shared keys | Median paired time ratio |
| --- | ---: | ---: | ---: |
| 1 | 356 ns | 270 ns | .761 |
| 10 | 2,445 ns | 719 ns | .295 |
| 100 | 22,919 ns | 5,339 ns | .235 |

This local allocation saving does not establish whole-query performance.
The current complete Python suite passes **369 tests**. Thirty additional
actual-binding cases cover empty/single/ten-row results across dot/L2/cosine,
exact/approximate, ordinary/filtered batch, named-field and fusion paths.
Their IDs, Float64 score bits and key order match the parent; independent-row
mutation and complete sentinel release pass. Fifteen compiler invocations are
audited: fourteen use candidate source, one is the standalone stdlib-only
generic-target probe. Only the binding source differs. Existing engine/C
validation remains applicable; no Linux build or capacity gate was run for this
rejected optimization.

All **54 native workers** in the unchanged fixed warm/mixed matrices complete.
Each phase rotates three parent/candidate/Qdrant triples for each of the existing
8,192-point uniform-128, uniform-1536 and real-1536 fixtures. Efs, K=10, filters,
oracles, plans and timing boundaries are unchanged. IDs, F32 score bits, stats
and execution choices match throughout; mixed reopen and Arrow lease checks pass.

| Phase | Quality, each version | Parent strict speed | Candidate strict speed | Pass→fail | Fail→pass |
| --- | ---: | ---: | ---: | ---: | ---: |
| Warm | 36/36 | 22/36 | 22/36 | 1 | 1 |
| Mixed | 36/36 | 25/36 | 24/36 | 1 | 0 |

Both pass→fail cells are uniform-1536 selective, trial 2 in their respective
phases. The warm fail→pass cell is real-1536 all, trial 2; it does not offset
either failure. Mixed write+flush remains 4/9 for each version. The complete
paired latency samples and every failed gate are retained. Mixed's driver exit
1 records failed speed acceptance, not a missing worker.

**Do not adopt this candidate.** Production source and binary remain at the
ownership fix. This experiment establishes cheaper dictionary construction but
does not clear the query regression or any remaining M5/M6 gate.

Before investigating candidate cosine norms again, consult the already rejected
[four candidate-summary prototypes](../benchmarks/2026-10-13-candidate-summary-probes.md).
The next distinct diagnostic samples the actual real-data filtered ANN paths on
production and the frozen mapped ownership candidate. HNSW already normalizes
its graph/query vectors; its hot metric path does not recalculate their norms.

[Full source, tests, microprobe, 54 workers and raw failures](2026-10-14-shared-result-keys.json.gz):
768 files, 3,859,834 bytes, SHA-256
`7fa9459a02ffe90a588fd63a06cc2d26c24a9ab10f7e2f8dd735be9801710974`.
The archive and every embedded file hash were verified.
