# Polygon payload filter source port

Continue D03 after the verified plain payload predicate slice. The full feature
plan remains open; this is feature correctness work, not optimization.

Sources: Qdrant v1.19.0 `GeoPolygon`, `PolygonWrapper` and plain payload checker;
geo 0.33.1 polygon containment and winding-number coordinate position;
geo-types 0.7.19 ring closure; robust 1.2.0 adaptive `orient2d` and its expansion
arithmetic. Use the exact Cargo.lock dependencies, archived source checksums and
licenses. Preserve source floating-point operation order and separate products.

Deliverables and acceptance:

- Port original robust orientation and reachable helpers to Mojo, with exact
  result-bit differential tests, including cancellation and near-collinear cases.
- Port polygon validation, EPSILON closure acceptance followed by exact closure,
  exterior/hole containment and boundary exclusion. Preserve unchecked numeric
  stored coordinates and source one-level array/Boolean predicate behavior.
- Integrate the owned polygon into the shared native payload condition and its
  clone path, reaching existing search, Arrow, formulas, mutations and HTTP.
- Generate expected polygon results by executing original Qdrant source with
  real pinned geo/robust dependencies; cover degeneracy, self-intersection,
  overlapping/outside holes, winding reversal, boundaries and malformed input.
- Verify native differential tests, public API paths, retained snapshots,
  mutation/restart, invalid requests, build and the full Python suite.
- Update API documentation, source-port ledger, licenses, report and task list.

No persistent format change. Dedicated geo indexing, full protocol compatibility
and every other unfinished product capability remain separately open.
