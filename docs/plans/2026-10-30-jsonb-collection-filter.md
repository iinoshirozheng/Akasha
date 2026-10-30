# JSONB conditions in existing collection queries

Continue from `093340a` under D01/D03/A03 and the full 49-package ledger.
This vertical slice plugs existing source-backed boolean JSONB operations into
all current FilterExpression consumers before adding collection projection.
Do not begin optimization or count dedicated JSONB indexes as completed.

Public shape: `kind="jsonb"`, a Qdrant payload `key`, and `function` chosen from
`predicate_match`, `json_exists`, `json_array_contains`, `json_get_bool`.
`argument` is a JSONB path except for get_bool, where it is an exact key/index;
contains additionally requires `needle`. Native limits use existing defaults.
No unknown properties or aliases. Configuration/path syntax is validated before
candidate iteration and writes, including empty collections. This eager filter
validation is separate from the value/Arrow functions' null-row short circuit.

The payload path may select nested JSONB carriers. Missing/storage-null values
are nonmatches. Present non-JSONB values are errors, not implicit text conversion.
A source nullable Boolean matches only true; existing Qdrant outer all/any/not/
nested semantics are unchanged. This is not SQL three-valued expression logic.

Use a native JsonbCondition with source JsonbSelector/LanceJson execution, a new
FilterExpression leaf, existing native direct and metadata-derived bitmap paths,
and the shared strict Python filter transport. No Python evaluator. Verify source
boolean fixtures, direct/bitmap equality, snapshot/WAL/checkpoint behavior,
exact/HNSW/IVF/sparse/hybrid/batch/formula/Arrow/HTTP queries and atomic conditional
mutation errors. Keep dedicated JSONB index structures, projection, SQL and
complete C/distributed contracts open for subsequent independently working layers.

## Verified outcome

- [x] Native condition, bounded filter AST ownership/cloning, eager validation.
- [x] Existing source selector/Lance execution and per-carrier limits.
- [x] Direct/metadata source outcomes and row-local Boolean error semantics.
- [x] Python, Arrow, current HTTP and shared search/scan/formula/update consumers.
- [x] Snapshot, WAL/checkpoint reopen, atomic mutation errors and strict inputs.
- [x] Final Python build; 59 native and 3,739 Python tests pass (1 existing skip).
- [x] Public documentation, provenance and retained validation evidence.

[Validation](../research/2026-10-30-jsonb-condition-validation.md).
This completes this integration slice, not D01/D03/A03 or the complete product.
Next: computed collection projections, dedicated indexes and the remaining
C/distributed/SQL interfaces. All master-package/platform/performance gates stay
open; no optimization.
