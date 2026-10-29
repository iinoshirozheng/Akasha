# Third-party source notices

Akasha contains adaptations of open-source database implementations. Port-specific
revisions, original source hashes, modified files and executable reference evidence
are recorded in [the source-port ledger](docs/upstream/ports.json).

## Qdrant

Project: <https://github.com/qdrant/qdrant>

The DBSF normalization in `src/akasha/query/score_fusion.mojo` and its integration
in `src/akasha/query/field_fusion.mojo` adapt Qdrant's
`lib/segment/src/common/score_fusion.rs` from commit
`74f3e85b9473c62560006c043e13737ce6b48412`. The code has been translated to Mojo,
uses typed score lists, and adds finite-range validation. Original behavior is
checked through an extracted Rust reference with representation-only shims.

Weighted RRF in `src/akasha/query/fusion.mojo` and its field-fusion integration
adapt `position_score` and `rrf_scoring` in
`lib/segment/src/common/reciprocal_rank_fusion.rs` at the same commit. Adaptations
include Mojo containers, finite-range validation and ascending point-ID ties.
The reference harness compiles both original functions without modifying them;
its container/type shims and output tie canonicalization are recorded with the
fixtures in `tests/fixtures/qdrant-rrf/`.

Stored-point queries in `src/akasha/query/field_lookup.mojo` adapt reference
resolution and same-collection exclusions from Qdrant's
`lib/collection/src/common/fetch_vectors.rs` and
`lib/collection/src/operations/universal_query/collection_query.rs` at that same
commit. The native dense/sparse/HNSW/IVF retrieval paths accept the resulting
exclusion set before selecting candidates. The reference harness also extracts
`VectorQuery::get_referenced_ids` from
`lib/collection/src/common/retrieve_request_trait.rs`. Akasha uses retained
native vector owners, collection directory identity and its existing typed
query/scoring contract; protocol/status and storage-preprocessing compatibility
remain separate work.

Qdrant distributes this source under the Apache License, Version 2.0; a copy of
the upstream license is included at [Qdrant license](docs/upstream/licenses/qdrant-Apache-2.0.txt).
No root NOTICE file is present at this pinned revision.

Earlier Qdrant-based ports and their reference paths are described in
[the existing alignment ledger](docs/research/2026-10-15-qdrant-alignment-evidence.md).
F00 in the full feature plan keeps the historical per-file attribution audit open;
the new port ledger does not claim that audit is already complete.
