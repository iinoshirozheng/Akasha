# Q02d sparse recommendation execution

Continue the full feature plan after `2432335`. Q02 and all other unfinished
rows remain open; this is the next executable dependency, not a reduced goal.

## Source findings

Pinned Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`:

- `segment/src/index/sparse_index/sparse_vector_index/read_view/search.rs`
  dispatches nearest/average queries to sparse search and custom best/sum
  queries to full scored iteration. It does not use HNSW for sparse queries.
- Filtered nearest queries below `DEFAULT_SPARSE_FULL_SCAN_THRESHOLD=5000`
  use `SearchContext::plain_search`; unfiltered/larger queries use `search`.
- `sparse/src/index/search_context.rs` has distinct zero-score rules: batched
  indexed scoring skips zero; plain search and the remaining-last-posting path
  may return zero for overlapping terms. No-overlap rows are omitted by nearest
  search. Custom scorers include zero/nonoverlap rows.
- `sparse_vector_index/vector_index_impl.rs::search` ignores `SearchParams`.
  Sparse recommendation must use this same dispatch in exact and approx modes.

The earlier blanket statement that sparse nearest always excludes zero is
therefore insufficient for full source equivalence. Keep historical evidence;
verify and document the source-path distinctions rather than weakening tests.

## Implementation and acceptance

1. Compile unedited upstream sparse search methods with representation-only
   posting/counter shims. Freeze fixtures covering zero/cancellation/negative
   scores, no overlap, empty queries, filters, and the 10000-ID batch boundary.
2. Port the source's batched and last-posting execution over retained native
   postings. Reuse native Top-K (ascending public-ID ties) and query controls.
   Existing postings have no reliable suffix-max bounds: use the source's
   non-pruning path; performance optimizations remain deferred.
3. Expose sparse recommendation through existing Mojo/Python/Arrow APIs.
   Average uses sparse execution; best/sum use full scored iteration and report
   that path explicitly. Use the same sparse dispatch for exact and approx;
   remove the obsolete sparse average flat path. Reject HNSW-only `ef_search`.
4. Validate against source fixtures and existing transform/reducer fixtures,
   retained snapshots, updates/deletes, lookup/exclusions, reopen, filters,
   Arrow ownership, limits, nonfinite scores and cancellation/deadlines.
5. Record source/target hashes, contracts, limitations and passing evidence;
   commit without pushing. Sparse planner configuration/IDF, full protocol
   parity and migration of older native nearest contracts remain in the ledger.

Multivector HNSW requires real ragged-vector storage/build scoring; no averaged
or first-row surrogate graph is acceptable. Continue that dependency and the
datatype/storage/protocol work after this slice. No M5/M6 tuning resumes.

## Implemented and checked

The source-backed sparse execution is implemented. 138 Rust search fixtures,
6 native tests and 1094 distinct Python tests passed; the latter include 142 new
sparse recommendation cases. See [validation and remaining limits](../research/2026-10-30-sparse-recommendation-validation.md).
Q02 stays open for the dependencies and remaining contracts listed above.
