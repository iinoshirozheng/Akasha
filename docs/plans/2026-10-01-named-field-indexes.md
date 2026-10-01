# Named-field derived indexes

The point catalog already distinguishes authority scalar/kind from each dense
field's HNSW configuration. Public typed exact search is connected; named HNSW
configuration must now drive actual candidate search and native reranking.

Use the existing root-owned artifact lifecycle (ADR 0007, SQ8/PQ): the immutable
read root fixes coverage, visibility, schema and configuration; a registry keyed
by field ID owns each complete field graph. Different fields cannot share a graph
or reinterpret authority buffers. First build occurs outside the collection
writer lock; concurrent first requests share the artifact lock. Failed builds
publish no partial index. New roots receive fresh states; older snapshots keep
their graph and immutable native owners through writes, close and compaction.

Derived HNSW construction converts the selected dense field to the separately
configured graph representation through the existing backend. Native F32/F16/
BF16/I8/U8 authority stays untouched. Every returned candidate is reranked using
the field's Float64 exact kernel over that authority. Reject unrepresentable graph
values/configurations rather than relabeling them as a successful ANN search.

Build a deterministic ID-ordered graph and its independent ID-to-row domain.
Missing fields never enter the graph. Filters evaluate the captured point view
and create eligibility in that domain before graph result admission, with the
existing bounded widening policy. A field index query serializes access to its
reusable mutable HNSW scratch; it does not acquire the collection writer lock.

Keep `search_field` exact by default. Add an explicit approximate mode and
ef/rerank controls at Mojo, Python and Arrow boundaries. Report planner,
candidate/final work and fallback reasons through a field search execution
result. Flat binary and MaxSim use their native exact kernels; sparse requires
its own postings semantics, including present-empty/zero-score rows, rather
than being inserted into a dense HNSW graph.

Acceptance includes independent native-score oracles for all five authority
types, differing field dimensions/metrics/encodings, missing fields, filters,
negative IDs/ties, old/new snapshots after single-field writes/delete/reinsert,
reopen, build reuse/failure/concurrent first requests and binding/Arrow parity.
Do not claim persistent per-field graph files or final performance acceptance
from root-owned in-memory artifacts alone; record cold build and warm separately.

Sparse uses the established `SparseIndex` term-posting/Dict accumulation pattern,
with a separate immutable field artifact: no owned record duplication or mutable
delete bookkeeping, F32 posting weights and F64 scoring. It retains the row domain
including empty vectors, so zero scores remain eligible before negative scores.
The native field oracle has this behavior, unlike the legacy matching-term-only
sparse API. Field HNSW and sparse registries share the same typed artifact-state
registry; no other lifecycle abstraction is introduced.

RRF receives typed `FieldQuery` branches, executes them against one acquired root,
and accumulates Float64 rank contributions in branch order. Filters and presence
apply before each branch's Top-K. Python and Arrow share validation and dispatch;
raw metric scores are not added across incomparable metric scales. Empty, mixed
field, filtered, duplicate field and negative-ID cases preserve deterministic ties.
