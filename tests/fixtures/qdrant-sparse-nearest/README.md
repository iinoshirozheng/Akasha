# Sparse nearest search reference

Generate with `rtk proxy python3 scripts/qdrant_sparse_recommendation_reference.py --nearest`.

`search.json` contains 214 cases produced by eight unedited Qdrant functions
and the original TopK at `74f3e85b9473c62560006c043e13737ce6b48412`.
The original recommendation search fixture is retained separately and unchanged.
Additional cases exercise overflow, the initial f32::MIN threshold, multiply
rounding before addition, bounded TopK, and fractional F32 inputs.

Representation adapters provide owned posting iterators, no-op hardware counters,
and deterministic native ID ties. The source non-pruning branch is used.
No complete Qdrant service, IDF or cardinality-estimation equivalence is claimed.
Expected scores are exact Float32 bit patterns, including infinity and signed zero.
