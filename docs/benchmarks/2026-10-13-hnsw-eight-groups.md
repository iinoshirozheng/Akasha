# Eight HNSW accumulator groups: not adopted

An isolated prototype doubled the F32 HNSW accumulator groups from four to
eight for dimensions of at least 64, for owned query/member, owned member/member
and mapped query/member scoring. Packed types and public exact reranking were
unchanged. The existing numerical contract permits an internal reduction-order
change, subject to accuracy and owned/mapped consistency checks.

All 33 targeted Mojo cases passed: accumulator accuracy, mapped vectors,
distance dispatch, HNSW views and quality gates. A fresh extension was built
from the copied prototype binding entry point and source tree. Three alternating
fresh-process pairs per corpus then measured independent-filter queries with
the existing databases, frozen ef values and oracle.

| Corpus | Median single-pass QPS ratio | Median 32-pass diagnostic QPS ratio | Median diagnostic p95 ratio |
|---|---:|---:|---:|
| uniform-128 | .615 | .998 | .976 |
| uniform-1536 | .948 | .988 | 1.021 |
| real-1536 | 1.070 | 1.004 | .993 |

Ratios are prototype/baseline. All query IDs, Float32 score bits and execution
statistics matched the baseline; all quality checks passed. Repeated passes
provide timing diagnostics only, not additional recall samples. The short
samples were noisy, and the longer trials showed no useful consistent gain.
Keep the four-group production implementation. No full Qdrant matrix was run
for this rejected prototype.

[All pairs, raw timings, source diff, binary identity, test logs and drivers](results/2026-10-13-hnsw-eight-groups.json.gz).
SHA-256: `a0953b0a452256629ba2b4b0b0309bbdb867bf0741ef7977f22aa6a46bfbc7fb`.
