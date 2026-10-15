# Qdrant source baseline before further optimization

The previous work cited individual Qdrant routines without completing the
comparison of construction, entry selection, filtering, traversal and result
processing. That left material algorithm differences underneath the SIMD and
layout experiments. The user's direction is now to reproduce the established
implementation before optimizing it.

## Version and executed configuration

The existing checkout is `74f3e85b9473c62560006c043e13737ce6b48412`.
The Edge 0.8.0 package version commit is
[`21db2f3ff95d50de3a2b88a741312c056fd1762d`](https://github.com/qdrant/qdrant/commit/21db2f3ff95d50de3a2b88a741312c056fd1762d),
now checked out separately at `reference/qdrant-edge-0.8.0`.
Comparing these commits under `lib/segment/src/index/hnsw_index`,
`lib/segment/src/vector_storage`, `lib/edge/python` and `lib/edge/src`
finds only the Python Cargo package version change. Thus the relevant local
search source was not made obsolete by this version difference. The missing
work was full-path analysis. No wheel build attestation was found or claimed.

The fixed benchmark adapter in `benchmarks/qdrant_compare.py` sets `hnsw_ef`
and `exact`, but does not enable ACORN. In the pinned source ACORN is used only
when explicitly enabled. Frozen real-1536 segment configuration records no
quantization. Consequently the source routes to ordinary filtered HNSW and
does not perform quantization rescoring. The earlier ACORN-inspired two-hop
candidate was not a reproduction of this comparator's configured algorithm.

## Material differences

| Responsibility | Qdrant source | Current Akasha |
| --- | --- | --- |
| Entry selection | First eligible primary; highest eligible extra if necessary | Single index entry; unfiltered upper descent |
| Neighbor scoring | Reject deleted/filter-ineligible nodes before scoring | Score first-seen nodes; eligibility controls result admission |
| Search context | One bounded nearest queue plus expansion frontier | Separate traversal-radius and eligible-result queues |
| Graph construction | Heuristic neighbor selection with independently pruned backlinks; optional payload-block graphs merged in | Bounded symmetric links and symmetric eviction repair |
| Additional graph links | Merged payload links may exceed ordinary per-level `m`; filtering precedes the per-expansion score limit | Snapshot validator enforces bounded `m`/`m0` adjacency |
| Results without quantization | Segment top-k; no additional vector rescoring | Collect per-source `ef` breadth, merge IDs, rerank authoritative vectors |

Source locations under the pinned checkout:

- `lib/segment/src/index/hnsw_index/graph_layers.rs`: ordinary search, upper descent and eligible entry selection.
- `lib/segment/src/index/hnsw_index/point_scorer.rs`: filter-before-score.
- `lib/segment/src/index/hnsw_index/entry_points.rs`: primary/extra entry pool.
- `lib/segment/src/index/hnsw_index/graph_layers_builder.rs`: independent backlink pruning and payload-link merge.
- `lib/segment/src/index/hnsw_index/hnsw/build.rs`: payload graph selection/construction and entry pool sizing.
- `lib/segment/src/index/vector_index_search_common.rs`: rescore only when quantization is enabled and rescoring is requested/defaulted.

The frozen three Qdrant corpora each contain a graph with `m=24`, `m0=48`,
`ef_construct=192`, **two primary entries and 80 extra entries**. These counts
were decoded read-only from each `graph.bin` using the pinned bincode field
order, including full-byte-consumption checks. The main entries are respectively
`(1896,3)`, `(5964,4)`, `(4985,4)`; each also contains `(30,0)`.
This verifies that entry coverage is present in the measured data. It does not
identify which payload block generated every extra edge or measure its latency
benefit. Payload construction has cardinality and connectivity skip rules;
the existence of an indexed field alone does not prove its graph was built.

## Executable first layer

[`qdrant_search_reference.mojo`](../../benchmarks/mojo/qdrant_search_reference.mojo)
now reproduces eligible entry selection, filter-before-score, filtered upper
descent, bounded nearest/frontier processing, the termination bound and top-k.
It uses Akasha's existing metric/graph APIs and preserves Akasha's stable tie
ordering explicitly. It introduces no production option, format or fallback.

The initial boundary test against the existing core failed as intended: three
distance calls versus one newly scored eligible neighbor (the reference receives
an already-scored entry). After the port, all nine boundary tests pass with
Mojo 1.0.0. An additional 96-fixture differential compares result slots and
distance-call counts against three **unedited methods extracted from upstream
Rust**, compiled with a small storage/scorer adapter. All fixtures match.
The complete scope, commands and limitations are documented
[next to the reference](../../benchmarks/mojo/qdrant_search_reference.md).
The [validation record](2026-10-14-qdrant-source-baseline.json) retains source
identities and compiler versions. Local generated fixtures, extracted Rust and
logs are in `.build/qdrant-source-reference/run-3`; the earlier failed fixture
driver compilation (`case` is a reserved Mojo token) remains in `run-1`.

These are algorithm-reference tests, not recall or speed acceptance. Production
source and binaries remain unchanged. In particular, the bridge fixture shows
that substituting this search into an arbitrary existing graph can lose access
to eligible nodes. The production bridge tests remain valid and unchanged.

## Integration order

1. Reproduce construction and search as one coherent index: heuristic pruning,
   eligible entry pool, and applicable payload connectivity. First verify
   directed links and score counts against upstream on fixed construction data.
2. Define the versioned derived-index representation for entry pools and
   supplementary adjacency. Existing snapshot fixtures require symmetric bounded
   links; disabling their validator is not a format migration. Rebuild/recovery
   and mixed updates must preserve current-source authority and historical reads.
3. Integrate the resulting query-ready index with base/delta ownership and the
   existing public tie/score contracts. Qdrant's lack of F32 rescoring is not by
   itself permission to return prepared-index scores in place of authoritative
   scores. Test this boundary explicitly.
4. Run the unchanged quality and performance matrices on that complete baseline.
   Only then specialize metrics, batching, layout, or instruction scheduling.

This replaces the earlier sequence of isolated micro-optimizations as the next
implementation direction. It does not claim that copying one search loop closes
M5/M6, or that any measured failed cell can be discarded.
