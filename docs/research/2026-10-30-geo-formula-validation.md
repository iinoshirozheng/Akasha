# Q04e / D03b geographic formula validation

Date: 2026-10-30. Parent `5075a5b`; Mojo `1.0.0 (ed45d567)` on macOS ARM64.
Plan: [source port](../plans/2026-10-30-geo-formula-source-port.md).

## Implemented behavior

Native/Python/Arrow formula queries accept `geo_distance` with a constant origin
and a payload JSON path. Native `GeoPoint` follows Qdrant's map/sequence serde
conversion: numeric longitude within [-180,180], latitude within [-90,90],
inclusive, with both finite. Extra object keys are ignored; an exact two-element
array is interpreted as `[lon, lat]`. Strings, bools, missing coordinates and
wrong lengths fail. Origins are checked during request construction even when
there are no candidates or the expression would short-circuit.

Payload conversion remains lazy and uses the existing source-backed retriever:
JSON paths, one-level flattening, wildcard suffixes and normalized defaults.
Only absent values use defaults; null or invalid values fail if evaluated.
Numeric formulas share the same retrieval helper and retain their prior rules.
Points are ordinary JSON payload values; there is no new durable payload tag.

The distance body ports `geo::HaversineMeasure::distance`, using its source
6,371,008.8-meter mean radius, F64 operation order and separate scalar products.
It does not clamp the intermediate value or substitute ellipsoidal distance.
The final formula retains Qdrant's finite-F32 rule and short-circuit semantics.
Python only converts inputs; coordinates and distances are evaluated in Mojo.

Formula ordering remains descending: negate distance to rank nearby points
first, or compose it with the existing decay expressions. The native Python
wrapper accepts only `origin` and `to`; it does not claim complete REST schema
compatibility. C ABI geographic query exposure is still pending.

## Independent source evidence

`scripts/qdrant_geo_reference.py` compiles the original Qdrant parser,
GeoPoint validation/conversion, payload retriever and formula scorer from
`74f3e85b9473c62560006c043e13737ce6b48412`. Its metadata records **9 source files
and 22 extracted units**. The scaffold adapts derives/transport, OrderedFloat,
the payload provider, counters and MultiValue; it does not replace the executed
geographic validation or scoring bodies. The unused date adapter is outside
this oracle. Decay transport uses fixed parameters; the existing 309 scalar
cases separately cover the numeric expression and decay parser.

The original evaluator calls the actual **geo 0.33.1** dependency pinned by
Qdrant's Cargo.lock, rather than a local stand-in. Its crate SHA256 is
`30eb1fdc57c1e5cfd11826fe0caec4b9dc7901f3758263bb506228d88c8d9e9a`, with
GeoRust revision `5ab50b072e34a915a33eaa46c80763d51d61295e`.
The crate archive, `.cargo_vcs_info.json`, Haversine source, both Cargo locks,
compiled scaffold/parser and all recorded Qdrant source/unit hashes were checked.
The retained [GeoRust MIT notice](../upstream/licenses/geo-MIT.txt) is recorded
in the source lock and port registry. Rust is used only for reference fixtures.

| Source fixture group | Cases and result |
| --- | --- |
| GeoPoint serde/coordinate validation | 30: 7 accepted, 23 expected errors |
| Original geo F64 distances | 796: exact F64 bits on this host |
| Original Qdrant formula results | 1,064: 886 exact F32 scores, 178 expected errors |

Distances cover poles, antimeridian, signed zero, small offsets, random pairs and
antipodes. **All 796 valid-coordinate distances in this fixture are finite**;
these cases do not demonstrate a valid-coordinate NaN. Native validation also
checks explicit NaN and positive/negative infinity inputs. Formula cases cover
object/sequence points, ignored keys, paths, flattening, defaults, null/wrong
types, short circuits and geographic decay. Expected values come exclusively
from the original Rust implementations, not a Python geometry calculation.

## Commands and results

Heavy builds/tests ran serially. The completed full Python suite was repeated
once because its prior terminal result was unavailable after context handoff;
the observed result below is saved at `.build/geo-formula-validation/python-full.log`.

| Command (all prefixed with `rtk proxy`) | Result |
| --- | --- |
| `python3 scripts/qdrant_geo_reference.py` | Release reference built; fixture groups above generated |
| `pixi run mojo run -I src tests/mojo/test_geo_formula.mojo` | 4 passed |
| `pixi run mojo run -I src tests/mojo/test_formula.mojo` | 4 passed |
| `pixi run mojo run -I src tests/mojo/test_formula_payload.mojo` | 3 passed |
| `pixi run mojo run -I src tests/mojo/test_universal_query.mojo` | 5 passed |
| `pixi run build-python` | Passed |
| `pixi run env PYTHONPATH=python:. pytest tests/python/test_geo_formula.py tests/python/test_formula_query.py tests/python/test_formula_paths.py tests/python/test_formula_payload.py -q --tb=short` | 979 passed, 2 existing warnings; 6.69 seconds |
| `pixi run env PYTHONPATH=python:. pytest tests/python -q --tb=short` | **3,138 passed, 1 skipped, 3 existing warnings**; 70.05 seconds |

The four native modules contain **16 tests**. The 46 new public Python cases
include every source formula through actual point writes, native queries and
Arrow output, plus eager origin validation, geo/default/path errors, negated
distance and decay ordering, filters, payload updates, deletion, WAL-only and
checkpoint reopen, nested query trees, cancellation/deadline checks and retained
Arrow output after close. Native tests also query an old snapshot after deletion
and writer close, and reject a manually mutated invalid origin.

## Failures retained

Initial native compilation exposed a literal-left comparison unsupported by
this Mojo compiler, followed by incorrect test spellings for infinity/NaN.
The implementation uses Float64-left comparisons and tests use the compiler's
generic `inf`/`nan` functions. Final native/binding/Python results above follow
those corrections; no source cases were removed to suppress failures.

The independent provenance check initially used the system Python, which lacks
`tomllib`, then matched a public `value_get` declaration when checking the private
function. Using project Python and the generator's newline-qualified signature
resolved those verification-script issues; source and fixture hashes matched.

## Remaining scope

Q04/D03 remain open for datetime types/expressions, full formula conditions,
typed-index retrieval, geographic radius/bounding-box/polygon filters and
indexes, sampling/feedback and complete REST/gRPC compatibility. Rich Arrow
payload columns and all other D/C/L/R/U/S/X/O rows remain open. The existing
Arrow query result here carries IDs/scores, not rich geographic payload columns.

No durable format, storage/recovery implementation, C ABI or GPU implementation
changed. Their separate suites were not rerun for this formula integration.
Native Linux remains deferred; host-specific exact floating-point comparisons
are not a cross-platform acceptance claim. M5/M6 and recommendation recall
failures remain recorded. No performance experiments or optimization resumed.
