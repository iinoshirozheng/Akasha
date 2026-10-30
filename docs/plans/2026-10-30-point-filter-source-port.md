# Point and path condition source port

Continue D03/Q04 from Qdrant v1.19.0 after polygon containment. Preserve the
full feature-first product plan and all outstanding acceptance gates.

Port query_checker.rs HasId/HasVector/Slice and nested identity isolation,
common/utils.rs whole-path IsEmpty/IsNull, types.rs Slice validation and
canonical hashing, and the pinned siphasher 1.0.3 SipHash-2-4 implementation.
Expected results come from original Rust functions and the actual dependency.

Implement owned point predicates and explicit per-point evaluation context.
Context includes the current point ID, vector field presence and retained
catalog; it is absent in nested object scopes as in Qdrant. Identity predicates
can use existing metadata IDs. Vector-aware expressions use authoritative point
state without changing the persisted payload-only metadata cache. This retains
the source separation between payload indexes, ID tracker and vector storage.

Public adapters add has_id, has_vector, slice, is_empty and is_null kinds.
The existing field-level empty/null behavior remains distinct and unchanged.
Named vectors use catalog names; empty name selects the default dense vector.
An explicit native field_id selector covers Akasha's separate unnamed sparse
field. Existing signed point IDs remain supported; native slice hashing uses
their UInt64 two's-complement encoding. Full UInt64/UUID point storage and ID
protocol compatibility remain D02 work, not silently accepted unsupported IDs.

Reach every current search path (dense, sparse, HNSW, IVF, universal/formula),
scanner, condition-selected update, metadata count, snapshot, Python/Arrow and
existing HTTP. Validate requests before candidates or writes, retain bounded
filter trees, clone current predicate state and test nested negation semantics.

Verify original-source fixtures, native direct/indexed context equivalence,
empty/removed vector presence, snapshot/reopen/cache paths, batch/formula/HTTP
integration, build and full Python regressions. Record source/license hashes,
public contracts and remaining scope. No format migration or optimization.
