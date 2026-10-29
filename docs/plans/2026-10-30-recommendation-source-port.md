# Q02b: all recommendation strategies from Qdrant

Continue the [full feature plan](2026-10-30-feature-completion.md) after the
[stored-point lookup prerequisite](2026-10-30-point-query-source-port.md).
This is required remaining work, not functionality already implemented.

## Sources already inspected

Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`:

- `lib/collection/src/recommendations.rs`: `avg_vectors`,
  `merge_positive_and_negative_avg`, `avg_vector_for_recommendation`,
  `recommend_into_core_search`, `recommend_by_avg_vector`,
  `recommend_by_custom_score` and batch validation.
- `lib/segment/src/vector_storage/query/reco_query.rs`: best-score and sum-score
  `score_by` implementations. Inspect/extract the referenced
  `lib/common/common/src/math.rs::scaled_fast_sigmoid` before porting.
- `lib/collection/src/common/fetch_vectors.rs` and universal-query conversion:
  IDs/raw vectors, missing vector errors, lookup source and ID exclusions.
- Before implementing target datatype preprocessing, inspect pinned
  `lib/segment/src/data_types/primitive.rs`, metric preprocessing and custom
  query scorers. Preserve explicit evidence for differences between native
  raw-vector storage and Qdrant's canonical stored values.

## Required behavior

1. `average_vector`: at least one positive example. Dense/sparse averages and
   the positive/negative combination must preserve original F32 arithmetic
   order. Qdrant's dense combination is `positive + positive - negative`.
   Multivector "averaging" concatenates positive rows; negative rows are
   concatenated with negated components. Do not invent per-row averaging.
2. `best_score`: at least one positive or negative example. Find the best
   similarity in each set, then use the source's signed scaled sigmoid and
   exact tie rule. Negative-only input is valid.
3. `sum_scores`: at least one positive or negative example. Accumulate positive
   and negative score lists separately in F32 and subtract them. Do not replace
   this with averaging or best-score behavior.
4. Resolve every ID against captured source roots; raw vectors remain direct
   inputs. Same-collection examples are excluded before candidate selection;
   external colliding IDs remain eligible. Repeated examples preserve their
   source-defined contribution while exclusion is set-based.
5. Distance metrics must enter custom scorers as higher-is-better similarity,
   following Qdrant's internal scorer/postprocessing rules, not by negating
   arbitrarily postprocessed public scores. Verify cosine, squared Euclid,
   sparse and multivector behavior explicitly.
6. Audit and implement cross-datatype and source-field preprocessing. Q02a's
   matching-kind/scalar/dimension native lookup is not proof of full Qdrant
   compatibility. Keep this as an explicit pending acceptance requirement.

## Implementation sequence and acceptance

- Extract unedited Rust transforms/scorers and freeze deterministic fixtures
  covering empty/singleton/duplicates/ties, negative-only sets, signed scores,
  sparse term unions, ragged multivectors and numeric boundaries.
- Reuse retained point lookup and exclusion sets from Q02a. Keep query transforms,
  scoring, exclusions and execution controls in Mojo; Python/Arrow are adapters.
- Expose working recommendation APIs for all three strategies, with actual
  datasets and raw/ID/mixed examples, filters, source lookup and ownership tests.
- Port Qdrant's custom query-scorer integration for ANN instead of approximating
  recommendations by ordinary nearest-vector search. Exact and indexed modes
  must identify their actual execution path; unsupported modes remain explicit
  work until implemented, never silently converted into a different strategy.
- Test source/candidate datatype and metric matrices, snapshots after mutation
  and close, reopen, candidate/example budgets, deadlines and callback reentry.
- Verify public pipeline behavior against independent upstream execution, not
  only the isolated helper or another Akasha API. Run affected regressions,
  update provenance/limitations and commit. REST/gRPC universal-query wiring,
  C ABI completion and Q03 follow under the master ledger.

No performance profiling, tuning or benchmark acceptance until all functional
rows in the master plan are verified.
