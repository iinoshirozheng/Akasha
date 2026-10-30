# Q04e / D03b: GeoPoint and geographic formula queries

Continue the full [feature ledger](2026-10-30-feature-completion.md). No performance
work or reduction of the remaining Qdrant/Lance/general DB/product scope.

## Source contracts

Qdrant `74f3e85b9473c62560006c043e13737ce6b48412` uses GeoPointShadow serde
conversion and GeoPoint::validate/new in `lib/segment/src/types.rs`, formula
schema/parse branches, and `formula_scorer.rs::eval_expression`. Longitude is
within [-180,180], latitude within [-90,90], both finite JSON numbers. The serde
struct accepts maps (extra fields ignored) and exact two-element sequences in
lon/lat order; bool/string/missing/wrong lengths fail. JSON paths/defaults follow
the existing authoritative-payload retriever, including array flattening.

Distance calls `geo 0.33.1`, locked crate SHA256
`30eb1fdc57c1e5cfd11826fe0caec4b9dc7901f3758263bb506228d88c8d9e9a`,
repository `georust/geo` at `5ab50b072e34a915a33eaa46c80763d51d61295e`.
Port its HaversineMeasure distance body and radius 6,371,008.8 meters. Preserve
F64 operation order and no-clamp behavior; final formulas retain source F32
finite checks and lazy operand evaluation. No Python geometry calculation.

## Implementation and acceptance

1. Pin/hash the actual dependency source and retain the GeoRust MIT license.
   Extend the existing original-source retriever/scorer oracle with unchanged
   Qdrant GeoPoint methods and the actual pinned geo crate (not a stand-in).
   Generate validation, distance, formula/default/path/short-circuit fixtures.
2. Add native GeoPoint parsing/validation and Haversine distance. Integrate
   `{"geo_distance":{"origin":{"lon":...,"lat":...},"to":"path"}}`
   in FormulaNode, Python conversion and existing Arrow query output. Preserve
   request conversion/owner checks, candidate selection, snapshots and budgets.
3. Validate coordinates and source F64 distance/F32 formula results including
   poles/antimeridian/antipodes, random points, empty/null/multiple payloads,
   defaults, geo-decay combinations, errors and short circuits. Test persisted
   updates/reopen, native old snapshots and Arrow lifetime.
4. Run relevant native tests, rebuild Python, targeted then full Python tests
   serially. Record evidence/provenance, update API/report/ledger, commit locally.

## Remaining scope

This provides the shared native point/distance dependency and an actual usable
formula path. Full geo radius/bounding-box/polygon filtering and indexes remain
D03, and datetime requires the separately pinned chrono parser/calendar source.
Do not substitute Python datetime or a hand-written spherical/calendar algorithm.
Typed-index retrieval, full formula conditions, sampling/feedback, protocol
compatibility, rich Arrow and all remaining product rows stay open.
