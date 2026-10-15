# Qdrant ordinary filtered-search reference

The benchmark facade now re-exports the production traversal in
`src/akasha/index/hnsw_search.mojo`. The Rust executable remains independent:
it runs extracted upstream methods over the same fixed fixtures. Neither
runner measures timings.

The source is Qdrant's Apache-2.0 implementation at
[`21db2f3ff95d50de3a2b88a741312c056fd1762d`](https://github.com/qdrant/qdrant/commit/21db2f3ff95d50de3a2b88a741312c056fd1762d),
the Edge package bump to 0.8.0. The upstream license is retained in
[`../licenses/qdrant-APACHE-2.0.txt`](../licenses/qdrant-APACHE-2.0.txt).
The Mojo code is a translation/adaptation, and the Rust adapter in
`benchmarks/qdrant_search_reference.py` extracts three traversal methods
verbatim from that commit. This does not establish the build commit of the
prebuilt PyPI wheel.

| Upstream responsibility | Source under `lib/segment/src/index/hnsw_index/` | Mojo reference |
| --- | --- | --- |
| First eligible primary, otherwise highest eligible extra entry | `entry_points.rs:get_entry_point` | `choose_entry` |
| Filter, truncate admitted neighbors, score | `point_scorer.rs:FilteredScorer::score_points` | `score_points` |
| Enqueue only candidates retained in the bounded nearest queue | `search_context.rs:process_candidate` | `_process_candidate` |
| Filtered beam and score-based termination | `graph_layers.rs:search_on_level` | `search_level` |
| Filtered upper descent, reuse its final score at level zero | `graph_layers.rs:search_entry`, `search_entry_on_level` | `search` |

The reference retains Akasha's checked graph access, metric arithmetic, and
deterministic `(distance, public ID, slot)` ties. Upstream compares scores only;
therefore the differential fixtures deliberately have distinct, exactly
representable L2 distances. A separate boundary test checks Akasha's tie rule.
This is control-flow equivalence on those fixtures, not bitwise equivalence of
the products' vector kernels or equal-score traversal order.

The Rust adapter supplies an in-memory graph, eligibility checks, scalar L2
scorer, queues and a no-op cancellation check. The extracted upper/level-zero
search methods are unedited. It does not run the complete Edge crate, payload
index, graph builder, persistence, bindings or concurrent searches.

The nine boundary tests cover rejection before scoring, filtering before the
neighbor limit, entry selection, missing eligible entries, filtered upper
descent, score reuse, traversal termination, stable ties and invalid limits.
The disconnected bridge fixture deliberately shows why this search cannot be
substituted into the current production graph by itself: filtered connectivity
and entry-point coverage must be established during construction. It must not
be hidden by a new exact-search fallback or a changed recall threshold.

`HnswSearchStats` is used only as a convenient counter container. Here rejection
counters count actual checks (including repeats), distances count calls, and
level-zero visits count scored nodes including the already-scored entry.
Production traversal uses these counter definitions; they are not a claim
of equivalence to Qdrant's production telemetry.

Run the boundary tests:

```sh
pixi run mojo run -I src benchmarks/mojo/test_qdrant_search_reference.mojo
```

Create the pinned source checkout if it is absent, without replacing the
existing reference checkout:

```sh
git -C reference/qdrant fetch --depth=1 origin 21db2f3ff95d50de3a2b88a741312c056fd1762d
git -C reference/qdrant worktree add --detach ../qdrant-edge-0.8.0 21db2f3ff95d50de3a2b88a741312c056fd1762d
```

Run the independent Rust/Mojo differential (requires `rustc`, no Cargo packages):

```sh
pixi run python -m benchmarks.qdrant_search_reference --output .build/qdrant-source-reference/new-run
```

It checks the upstream revision and source bytes, generates 98 deterministic
directed-graph fixtures (including entries below their point's top layer), and compares result slots plus distance-call counts.
Inputs, extracted Rust, compiler/run logs and source identities are retained in
the fresh output directory. No native performance acceptance follows from it.


Two additional source oracles cover construction:

```sh
pixi run python -m benchmarks.qdrant_connectivity_reference --output .build/qdrant-source-reference/new-connectivity
pixi run python -m benchmarks.qdrant_build_reference --output .build/qdrant-source-reference/new-build
```

The connectivity runner extracts `subgraph_connectivity` and
`get_random_entry_point` unchanged. Its 128 fixtures compare the exact Float32
connectivity and final random state. Both sides use the same explicit SplitMix64
adapter; this does not assert that Qdrant's default random generator is identical.

The build runner extracts the serial insertion, per-level linking, entry
promotion, and search methods, and includes upstream `LinksContainer` with only
module-import adapters. Its 24 fixtures contain 2,467 per-level adjacency lists.
It compares their exact order using fixed levels, integer L2 vectors with no
pair-distance ties, and the upstream optimized backlink heuristic. This proves
that Akasha's simple backlink implementation produces the same graph on these
fixtures; it does not claim equal build work, native floating-point reductions,
parallel build order, or recall/performance acceptance.
