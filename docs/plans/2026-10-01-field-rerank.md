# Bounded native-field reranking

M5 requires appropriate Binary/MaxSim retrieval and rerank paths. Existing
field HNSW/IVF/sparse retrieval and same-root RRF provide the candidate stage;
existing native kernels provide Hamming/Jaccard/MaxSim scoring. Follow the local
Qdrant universal-query pattern of separate candidate retrieval and final scoring
(`lib/collection/src/operations/universal_query/collection_query.rs`), without
adding graph encodings for packed bits or ragged token matrices.

Extend `search_fields` with optional `rerank=FieldQuery(...)`, exact mode only.
Candidate branches each retrieve at most `fetch_k`; the existing deterministic
RRF selects at most `fetch_k` unique candidates. The final field scores those
IDs in the same captured root and returns k results in its metric direction.
Missing final fields and empty document multivectors do not participate. No
candidate expansion or global exact fallback occurs when fewer than k remain.
Filters already apply to every first-stage branch. Validate the final query
before building any candidate artifacts, even for empty inputs/results.

Use the existing root ID lookup and borrow authoritative owners. Keep original
native values, Float64 accumulation, ascending-ID ties, and zero-norm/error rules.
No new durable format, dependency, copied corpus or persistent index is needed.
The total candidate resource bound is `visible_rows * branches` plus
`min(fetch_k, visible_rows)` for the final stage, computed without overflow.
Check cancellation/deadline between final candidates.

Final stats label `field-rerank`, expose its metric/scalar, count the input
candidate set in `base_candidates`, final native scores in `reranked_candidates`
and returned hits in `retained_candidates`; distance evaluations remain aggregate.
Python and Arrow use the same binding operation. Tests cover independent
bitset/Float64 oracles, first-stage exact/HNSW/IVF, filters, missing/empty fields,
negative IDs/ties, budgets, mutation/old-root/close/reopen and rejection of ANN
controls on the final stage. Measure recall versus candidate budget separately
from full-oracle correctness of the final scoring.
