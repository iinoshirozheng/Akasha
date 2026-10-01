# HNSW dictionary lookup probes — rejected

Replacing `contains` followed by indexing with `Dict.get` is supported by the
installed Mojo 1.0 standard library and already used in the point table and
sparse index. We tested it for the source map, ID-to-ordinal map and metadata
eligibility. The missing-source sentinel is 0; missing ordinal is -1. Neither
sentinel constrains public IDs. Arc ownership and result ordering were unchanged.

**No production lookup replacement was retained.** All production Mojo source
bytes and the Python native binary were restored to the saved, validated baseline.
The additional regression for negative IDs, missing IDs and ordinal zero passes
on that baseline. The C library was rebuilt from the restored source.

The initial native diagnostic used the filtered HNSW API with all, half or a
tenth of ordinals admitted. Its 27 alternating pairs showed roughly 1–3% lower
full-search medians. All candidate IDs, distance counts and public score bits
matched. These calls bypass the collection planner; separate collection/rerank/
full-search timers are not additive because the earlier stages warm memory.

The first public Python comparison used the fixed, lowest passing Akasha ef from
the [preceding refined curve](2026-10-02-refined-ef-warm.md). Nine alternating
pairs checked loaded binary hashes and used identical closed database clones.
All 72 cells passed recall, 4,608 timed query audits and 4,824 exact checks passed,
and final IDs, F32 score bits and stats matched. Real-data QPS ratios were:

| Three-method prototype, after/before | Median | Full trial range |
|---|---:|---:|
| All | .982 | .949–.987 |
| Correlated | 1.016 | 1.008–1.025 |
| Independent | 1.033 | 1.020–1.071 |
| Selective exact control | 1.029 | .984–1.042 |

The unfiltered regression prompted a separate native experiment with four
variants: baseline, all three methods, ordinal/eligibility only, and source only.
Each variant occupied each order position once across four trials per corpus.
All 48 runs matched candidate/result audit bytes. At real ef16, the median full
query time ratios were 1.051, 1.002 and 1.052 respectively. That isolates a
regression from the source replacement in this compiled workload; it does not
establish a general dictionary implementation or instruction-level explanation.

We then restored the original source lookup and rebuilt the ordinal/eligibility
variant. Another nine public pairs passed all result, stats and recall checks,
again 4,608 timed audits and 4,824 exact checks. Real QPS ratios were:

| Ordinal/eligibility-only prototype, after/before | Median | Full trial range |
|---|---:|---:|
| All | .990 | .967–1.199 |
| Correlated | .938 | .934–.978 |
| Independent | .957 | .928–.966 |
| Selective exact control | .975 | .848–.985 |

This second variant also failed the public performance gate. Exact controls
show substantial variation, particularly at 128D, so their apparent gains cannot
be attributed to the changed lookup paths. All samples, including slow trials,
remain in the archive. No benchmark overlapped builds, tests or compression;
OS cache remained present, and no cold/non-resident result is claimed.

The first candidate passed 108 affected Mojo tests, 9 crash tests, all 339 Python
tests and the rebuilt C client. The second passed 43 targeted Mojo tests, 339
Python tests and C again. These successful correctness checks did not justify
adopting a performance regression. The restored production baseline retains its
previous complete integration and 339-test Python evidence.

[Full sources, rejected patches, raw results and validation logs](results/2026-10-02-hnsw-lookup-probes.json.gz)
(2,533,808 bytes; SHA-256
`28b1c1e51ceaec85c1f5ae105279632526634c366c616e2cb39390e134422912`).
