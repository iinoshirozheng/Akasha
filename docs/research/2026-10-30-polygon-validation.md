# D03e polygon filter validation

Date: 2026-10-30. Parent `2b0c9b1`; Mojo `1.0.0 (ed45d567)`, macOS ARM64.
Plan: [polygon source port](../plans/2026-10-30-polygon-source-port.md).

## Implementation and source

`document/geo_polygon.mojo` ports Qdrant v1.19.0 GeoPolygon validation/conversion,
geo 0.33.1 polygon containment/coordinate position, and geo-types 0.7.19 exact
ring closure. `compute/robust_orientation.mojo` translates robust 1.2.0 adaptive
orient2d and reachable expansion arithmetic. No new geometric algorithm or
runtime Rust/Python geometry dependency is introduced. Qdrant/GeoRust revisions,
archive checksums, original functions and licenses are recorded in the fixture
metadata and port `D03e-geo-polygon`. Six Qdrant files / 68 units and nine
dependency files / 25 units were independently checked against pinned sources;
scaffold, lock and license checks are recorded in `provenance.json`.

Query rings require at least four points, validated geographic coordinates and
EPSILON-close endpoints. GeoRust then closes them exactly. Exterior boundaries,
hole boundaries and vertices are excluded. Winding reversal, repeated points,
self-intersections, degeneracy and overlapping/outside holes follow the original
planar winding-number implementation. Antimeridian polygons are not automatically
wrapped. Stored points retain Qdrant's unchecked numeric lon/lat object rule.
Map and serde struct-sequence forms are accepted with original required lengths;
unknown polygon/ring fields follow serde's ignore behavior. Field-condition
adapter keys remain strict as documented.

Owned polygons participate in native field cloning, JSON paths, one-level array
matching, nested scopes and existing count/empty/null override precedence.
Bounding-box/radius/polygon predicates retain OR behavior within one field node.
The shared evaluator reaches direct and metadata candidate selection, Python,
Arrow, named/universal/formula searches, condition-selected mutations and existing
HTTP routes. No persistent format, migration or write protocol changed.

## Differential evidence

The original Qdrant Rust checker scaffold is reused with separate fixtures and
Cargo.lock. It compiles the original GeoPolygon code and actual geo dependencies.
Python generates inputs, never expected containment. Archive checksums match the
pinned Qdrant lock; unpacked source files match archive contents. Geo-types' MIT
license at its pinned repository revision matches the retained GeoRust license.

- **17,060 polygon cases**: 3,081 matches, 13,960 nonmatches, 19 expected errors.
- **31,167 exact-bit orientation cases** from the real robust crate, including
  its upstream fixtures, seeded near-collinear inputs, exponent variations,
  underflow and subtraction-tail cancellation.
- A separately traced original-source copy is bit-checked against the unmodified
  crate for every input. Adaptive exit counts are **9,513 / 2,351 / 7,236 /
  12,051 / 16**; eight final expansion cases produce nonzero results.
- Polygon fixtures exercise all source shapes and validation, one-ULP boundary
  neighbours, exact-closure insertion, unchecked extreme stored numbers,
  antimeridian planar behavior, holes, arrays, field precedence and nested scopes.

## Validation

Heavy builds and tests run serially. Logs: `.build/polygon-validation/`.

| Command (prefixed with `rtk proxy`) | Result |
| --- | --- |
| `pixi run python scripts/qdrant_polygon_reference.py` | Passed; original-source fixtures and all adaptive exits verified |
| Seven native geometry/filter/index/mutation/formula modules | **33 passed**; `native.json` records exact commands and results |
| `pixi run build-python` | Passed |
| `pixi run env PYTHONPATH=python:. pytest tests/python/test_geo_polygon.py -q --tb=short` | **24 passed**, 3 existing warnings; 4.87 seconds |
| `pixi run env PYTHONPATH=python:. pytest tests/python -q --tb=short` | **3,212 passed, 1 skipped**, 3 existing warnings; 76.40 seconds |

The native polygon test checks every fixture directly, after cloning and through
metadata selection, then checks deleted IDs disappear. It also checks owned
geometry and a retargeted condition key. Public tests cover source cases via
Python/Arrow, scoped mutation selection, retained scan/result owners, WAL-only
and checkpoint reopen, named HNSW, prefetch/formula, parallel batches, malformed
query rejection before mutation and real HTTP search/update routes.

Implementation diagnostics: Rust's struct-sequence input requires two polygon
members even when the optional interior is null; the oracle revealed and fixed
the initial one-member acceptance. The test loader initially converted unsigned
Float64 bit patterns through signed Python Int; it now uses the existing native
UInt64 JSON converter. The source oracle initially lacked final adaptive-stage
coverage; explicit near-collinear subtraction-tail cases now cover both zero and
nonzero expansion results. These changes preserve source behavior rather than
relaxing validation or skipping difficult cases.

## Remaining scope

Plain polygon containment is implemented and verified through the paths above. Dedicated
geo/date/array/nested/text indexes, indexed tokenizer/BM25/phrase semantics,
remaining condition types, rich Arrow, complete Qdrant REST/gRPC and C ABI
exposure remain open. Lance/version/schema/object-store/Blob, SQL/transactions/
constraints, UI/security/cluster/operations and the complete product inventory
are still pending. M5/M6 and recommendation recall failures remain; no
optimization or new performance acceptance. Native Linux acceptance is deferred.
