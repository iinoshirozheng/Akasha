# Locate HNSW adjacency once per expanded node

The traversal core currently calls `neighbor_at(slot, level, index)` for every
edge. Each mapped call revalidates the level, reads the node/count metadata and
locates prior levels. Owned calls repeat level/count/base calculations too.
Qdrant's local `graph_layers.rs` instead obtains an iterator for a point's level
once (`GraphLayersBase::for_each_link`, lines 459–475).

Return a pair of edge-tape offset and occupied count from `neighbor_range`.
Validate the complete range before returning it, then traverse it through
`neighbor_at_offset`. Each individual access retains owner/open and tape bounds
checks. Keep target slot/level checks, adjacency order, admission, distance
arithmetic and all counters unchanged. No stored graph bytes or public binding
API changes. This applies to search-boundary validation, greedy descent and layer
search, including their use during graph construction.

Use the existing graph access trait and native tape representation. The range
contains integers; it neither owns nor exposes a pointer. The search holds an
immutable graph argument throughout iteration. Existing single-edge access remains
useful to construction and structural auditing.

A first isolated prototype returned standard `Span` values. Official
[Span](https://mojolang.org/docs/std/collections/span/Span/) and
[Pointer](https://mojolang.org/docs/std/memory/pointer/Pointer/) documentation
describes origins and unsafe origin conversion. The live docs are 1.1.0; the
installed 1.0.0 compiler is the authority. Compiler probes rejected escaping and
mutating the immutable view, but accepted explicit mapping close and backing-list
mutation before later span use. Those negative programs were not executed. The
direct-span design is rejected, including its raw pointer/origin casts. The final
offset design needs no new mapping API and checks the live owner on each read.

Acceptance: demonstrate missing range behavior, then verify every level against
existing owned/mapped access, invalid slot/level/count/offset, integer extremes,
and closed-owner reads. Run search-layer, view/storage, graph build/mutation,
filtered/widening, native scalar, segmented/persistent/named and recovery tests;
rebuild and test Python/C. Compare exact candidate IDs, distance counts and public
score bits in alternating native runs before measuring the public mixed workload.
Retain outliers, failed prototypes and the earlier inline-only probe. Benchmarks
must run serially without builds/tests/archive compression.
