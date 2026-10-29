# Qdrant discovery/context reference

Pin: `74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).
Regenerate with `rtk proxy python3 scripts/qdrant_discovery_reference.py`.

The generator compiles unedited upstream pair rank/loss, query score methods
and `GraphLayers::get_entry_point`, together with the existing portable scalar
metric/normalization/sparse/MaxSim methods. Source/function/scaffold hashes are
embedded in `discovery.json`; the recommendation fixture remains byte-identical.

- 120 reductions cover empty/multiple pairs, signed zero, infinities, NaNs and
  floating-point rounding. NaN results are compared by classification, not payload.
- 168 vector cases cover target-only, context-only and target+context across
  dense, sparse and directional MaxSim, Dot/L2/cosine. Expected rows are in
  candidate order so native scores can be compared independently of Top-K ties.
- 48 entry cases cover highest-level selection, last tie, filtered points,
  duplicate/reordered custom entries and empty-list fallback.

Transport, containers and graph levels/eligibility are adapters. The normal
entry fallback stub returns the first eligible supplied entry, matched by the
native fixture's explicit primary entries. This does not validate Qdrant graph
construction, default entries, full traversal, service dispatch, SIMD or storage
datatype conversion. Python ANN cases use complete tiny graphs only to validate
source scoring/stage integration; production recall gates stay open.
