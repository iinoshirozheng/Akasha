# Bounded binary and MaxSim reranking

`search_fields(..., rerank=FieldQuery(...))` now retrieves and fuses a bounded
candidate set, then scores its native field owners on the same immutable root.
It supports binary Hamming/Jaccard and all five native numeric dtypes with
multivector dot, squared L2 and cosine late interaction. Existing dense/sparse
fields can also be final scorers. The [API contract](../python-api.md) describes
candidate limits, filtering, missing/empty fields, metric direction and counters;
the [design](../plans/2026-10-01-field-rerank.md) records the reference and decision.

Fifty-two Python tests pass: exact/HNSW/IVF first stages, all five numeric final
dtypes and three multivector metrics, both binary metrics, independent bitset/
NumPy oracles, filters, Arrow results, updates/deletes/flush/reopen, invalid final
queries and total candidate limits. The expanded tests initially passed floating
values to integer schemas; the fixture now uses actual integers, preserving the
existing strict integer input contract. One Mojo lifecycle test verifies sparse
postings to native F16 MaxSim, fewer-than-k output, bounded final scores, changed
roots, cancellation/resource limits and old snapshots surviving collection close.
Two existing sparse/fusion tests still pass. The other 264 Python tests passed
in the full integration run and are unchanged by the fixture correction.

## Candidate recall experiment

`benchmarks/field_rerank.py` uses 2,048 rows with 64-bit binary or four 31D F32
tokens per document, three tokens per query, K=10, and seed 931. Its candidate
field is a dot HNSW graph over signed bit coordinates or mean-pooled document
tokens. The final field uses native exact scoring. Candidate budgets are
10/32/128/512/2048, with unfiltered and 25% filters. Each cell has three passes
of 16 queries after three warmups. Candidate retrieval used to inspect recall
is outside timings and warms the graph; exact/rerank timing order alternates.
All 50 cells preserve every raw sample and counter. Each final ranking equals
the independent oracle restricted to its actual candidate set. Candidate and
final recalls are reported separately; low-recall cells have no speed-ratio field.

Unfiltered final Recall@10:

| Native final metric | 10 | 32 | 128 | 512 | 2048 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Hamming | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |
| Jaccard | .681 | .913 | 1.000 | 1.000 | 1.000 |
| MaxSim dot | .181 | .312 | .581 | .906 | 1.000 |
| Late-interaction squared L2 | .044 | .125 | .319 | .650 | 1.000 |
| MaxSim cosine | .144 | .238 | .494 | .831 | 1.000 |

These results demonstrate the candidate-quality limit of mean pooling on
uncorrelated random tokens. Only full unfiltered MaxSim candidate coverage passes
.95 recall here; it costs more than direct exact search. Short packed bitsets
also favor direct scanning in most measured cells despite high Hamming recall.
The API enables independently chosen semantic first-stage embeddings; it does
not promise that arbitrary pooling preserves late-interaction neighbors.

First graph build plus query takes 0.798–2.200 seconds across the five cases.
Latency samples show substantial variation, including very slow individual
requests; they remain in the report. No blanket speedup or Qdrant parity is
claimed. Process peak RSS includes inputs, prior cells and training and is not
a retained-allocation measurement. [Raw report](results/2026-10-01-field-rerank.json.gz)
contains binary/source/workload hashes, timings, candidate/final recalls and stats.
