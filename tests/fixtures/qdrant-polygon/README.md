# Original-source polygon fixtures

Regenerate with `rtk proxy pixi run python scripts/qdrant_polygon_reference.py`.
Requires the pinned reference checkout and crates in the local Cargo cache.
The generator verifies each dependency archive against Qdrant's Cargo.lock and
the local source files against the archive before compiling.

`filters.json` executes the original Qdrant v1.19.0 plain FieldCondition and
GeoPolygon validation/conversion with actual geo 0.33.1 / geo-types 0.7.19 /
robust 1.2.0 dependencies. The existing payload-filter Rust scaffold is reused;
only fixture destination and generated inputs differ. Python does not calculate
expected containment. Serialized input values reflect the Rust JSON parser's
actual numbers. There are 17,060 cases: 3,081 matches, 13,960 nonmatches and
19 expected validation errors.

`orientation.json` executes the unmodified robust 1.2.0 crate on exact input
Float64 bit patterns; expected output bits include negative and signed-zero
representations. Inputs include the crate's original orient2d fixtures, seeded
near-collinear points, varied scales, underflow and exact/near collinearity with
nonzero subtraction tails. A separate original-source copy adds only adaptive
exit tracing (and removes crate-only attributes for module compilation). Every
traced result is checked bit-for-bit against the unmodified crate. All five
exit stages are exercised: 9,513 / 2,351 / 7,236 / 12,051 / 16 cases. Eight final
expansion cases have nonzero results. Total: 31,167 orientation cases.

The polygon cases cover exterior/hole edges and vertices, reversed winding,
degenerate/self-intersecting rings, overlapping/outside holes, repeated points,
EPSILON closure, one-ULP boundary neighbours, antimeridian planar behavior,
unchecked stored coordinates, invalid/wrong-shaped query data, serde struct
sequences, one-level arrays, nested scopes and combined field predicates.

`dependencies.json` records original files, function hashes, crate checksums,
source revisions and licenses. Cargo locks are separate for polygon and direct
orientation executables. `filters.json` additionally retains the Qdrant units
and scaffold hashes. These are plain-predicate correctness fixtures, not an
index, performance, complete protocol or whole-product acceptance claim.
