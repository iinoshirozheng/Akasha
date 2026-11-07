# Lance JSON Index Implementation Plan

**Goal:** Port the pinned Lance JSON index wrapper and its real scalar target
indexes, then expose durable collection indexes and index-backed queries.
This remains part of D01/D03/L03 in the 49-package product plan.

**Source:** `reference/lance/rust/lance-index/src/scalar/json.rs` at
`ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`, its actual JSON UDF and jsonb 0.5.6
Serde deserializer. Use the existing Mojo selector, binary value and numeric
ports. No replacement indexing algorithm or Python computation.

## Required stages

- [x] Port and independently verify batch input extraction, first-non-null
  type inference, whole-batch type validation and strict typed conversion.
  Preserve null masks, F64 bits, extension strings and raw array/object bytes.
  Inference does not widen: Int64 then Float64 rejects; the reverse accepts.
  The batch API returns no inferred type if all tags are null; stream-level
  Utf8 default and preserving the trained type remain in the next stage.
- [ ] Port actual scalar target index training/search/update/remap, with source
  ordering (converted values ascending, nulls first where required), stable row
  identity, null/NaN semantics and limits. Inspect the pinned target source
  before choosing its representation. Existing finite-only payload numeric
  indexes cannot silently substitute for the source's full F64 domain.
  Implement prefix-only inference buffering, all-null stream Utf8 default and
  fixed learned type for updates when connecting the actual training stream.
- [ ] Port exact function/path query matching and target query delegation;
  preserve residual predicates, snapshot identity, cancellation and errors.
  An index must not evaluate branches masked by per-row short circuiting.
  Native guarded typed-leaf matching is verified below; full expression binding,
  residual planning and snapshot-aware collection selection remain open.
- [ ] Add durable index definitions and learned type, following the existing
  collection writer lock and authoritative publication/recovery rules. Specify
  migrations before changing formats. Do not publish ad-hoc sidecar authority.
  Cover create/list/drop, incremental changes, rebuild, compaction, snapshots,
  backup/restore and corrupt/torn recovery.
- [ ] Expose the real native collection path through Python/Arrow/current
  service APIs, document usage, compare queries with source and non-index paths,
  and run relevant persistence/crash/full boundary tests.

Only the final stage with all earlier evidence closes this index capability.
A verified converter is a dependency, not a completed index. SQL, all target
variants, complete protocols and other master packages remain explicit work.
No performance tuning in this phase.

## First stage files and verification

Create `scripts/lance_json_index_reference.py/.rs` to execute unchanged upstream
inference/validation/conversion methods against actual Arrow and jsonb crates.
Record pinned file/method hashes, Cargo.lock and dependency archives. Reuse
existing raw JSONB corpus; add multi-row type-order/mask/error-precedence cases.
Adapters may transport arrays and errors, not duplicate expected algorithms.

Add `tests/mojo/test_lance_json_index_input.mojo`, observe missing-feature
failure, then port `src/akasha/index/lance_json_input.mojo`. Separate extraction,
inference and conversion so future stream training can buffer only its prefix
and retain the source batch validation boundary. Native converted results own
their values and preserve all Float64 bits. Bound rows/owned bytes and reuse
native cancellation/deadline controls; do not confuse JSON work with row count.

Run new native tests, then existing Lance JSON/number/formatting tests relevant
to reused dependencies. Reproduce the source fixture and provenance, retain
failure logs, update the port registry and ledger, and commit locally. Existing
application results can be reused while no application runtime imports this
new dependency. Later collection integration requires a rebuilt kernel and
new public/recovery tests.

## Verified batch input stage (2026-10-31)

6,481 original-source scenarios, 32,405 typed conversion outcomes and 6,481
inference outcomes pass. Five new native tests and three existing Lance JSON
tests pass. See [validation](../research/2026-10-31-lance-json-index-input-validation.md).
No persisted format or application execution path changes in this dependency.

## Next target source findings

### Materialized row sets and nullable search results

Verified dependency on 2026-10-31: native point-set operations and nullable mask
NOT/AND/OR plus set union_all match original source. **309 set scenarios,
1,236 set results, 112,021 inserts, 9,853 removals, 2,256 nullable results and
27,072 probe states; 10 native tests pass.**
[Evidence](../research/2026-10-31-lance-rowset-validation.md).
The materialized bitmap target is now verified below; JSON stream/planner/durable
integration and other target variants remain pending.

The target needs arbitrary UInt64 row IDs and separate true/unknown sets.
This dependency ports roaring 0.11.4's point-insert/remove paths, 16-bit array/bitmap
containers (threshold 4096), 32/64-bit partitioning, ordered iteration and
union/intersection/difference/XOR. Use Mojo's existing lower-bound helper and
standard containers; keep the source's two-level partition and container
dispatch. It ports Lance's actual nullable mask Boolean formulas and set union_all, including
allow/block complements without materializing a universe. Range insertion,
run optimization, full-fragment selections and portable serialized Roaring
formats remain separate requirements before claiming complete compatibility.

Verification executes actual original roaring crate operations and original Lance nullable
method bodies over materialized row sets. Include dense/sparse transitions,
duplicate insert/remove, UInt64 extrema, unknown rows outside selected rows,
all allow/block combinations, bounded mutation failure and owned results.
Failing native tests preceded implementation; provenance is preserved, and
this dependency remains distinct from a completed scalar index.

`scalar/bitmap.rs` requires value-sorted input even for bitmap training. Its
`streaming_build_and_write` accumulates one equal-value run at a time and
merge-joins old sorted keys, filtering old data before publishing new index
files. `search_with_options` has separate true and unknown/null row sets;
Equals(null), IsNull and IsIn containing null move those rows into true.
Ranges include/exclude endpoints and explicitly detect empty ranges.
`btree::OrderableScalarValue` supplies null-first ordering and typed scalar
comparison; actual Float64/NaN ordering must be ported from this source.

Akasha's current KeywordIndex only accepts persisted String/Bool and returns a
single match bitmap. MetadataIndex's float payloads reject nonfinite values.
Neither is a substitute for the source target's type/null contract. Reuse
existing bitmap operations where valid, but retain the source's target index
algorithm and its nullable result, streaming merge and lifecycle invariants.
Lance file storage and the existing Akasha authoritative catalog/WAL cannot be
treated as interchangeable; stage the documented durable migration before
collection publication. These are implementation requirements, not blockers.

## Verified materialized bitmap target (2026-10-31)

`lance_scalar.mojo` and `lance_bitmap.mojo` supply the actual native target for
Boolean/Int64/Float64/Utf8/LargeBinary: source null/NaN/zero ordering, value-run
training, equality/range/IN/IS NULL searches, true/unknown sets, retained old
row/fragment filtering, sorted old/new merge and row-ID remapping. Sorted owned
key arrays replace BTreeMap; source-ported Roaring sets retain postings. This
is a bounded materialized target; batch boundaries preserve equal-value runs.

**61 source scenarios, 183 exact states, 3,453 comparisons and 98,160 search
outcomes including 720 original errors** match. **15 native tests** pass,
including actual JSON conversion-to-index integration, resource/control and
ownership checks. Four source fixture files reproduce byte-for-byte.
[Evidence](../research/2026-10-31-lance-bitmap-validation.md).

The native JSON prefix-only inference/default Utf8, fixed learned type and actual
training stream are now connected and verified below. The second required stage
remains open for the file/streaming operations and other scalar targets.
Do not replace the final public/durable requirement with materialized tests.
Also retain these source target operations in the remaining index inventory:

- [ ] Lance shard k-way bitmap merge and incremental disk-backed publication.
- [ ] Lance bitmap file encoding, lazy loading/cache and all relevant options.
- [ ] Other supported scalar targets and their types/lifecycle contracts.

The JSON stream wrapper is now verified below. Next is exact query matching/
residuals and the shared durable index catalog migration/public collection path.
No application runtime/format change or optimization in this target slice.

## Verified native JSON stream wrapper (2026-10-31)

`lance_json_stream.mojo` now connects incremental JSON batches to the bitmap
index: only the inference prefix stays as extracted JSON, later batches convert
under the fixed learned type, and EOF alone defaults to Utf8. Source errors and
prefix stopping match **786 source scenarios (593 success / 193 errors)**.
The successful source streams contain 2,842 batches / 2,283 converted rows;
all rows reach the native index under their original UInt64 identities.

A native trainer retains the path/type for updates and rebuilds. Search/remap
use the verified target, failed/aborted/finished trainers cannot be reused,
and errors during conversion or final index merge preserve old indexes.
**15 native tests** pass; four source fixture files reproduce exactly.
[Evidence](../research/2026-10-31-lance-json-stream-validation.md).

The target still sorts bounded materialized keys. Original external sort/spill,
generic Arrow passthrough, disk-backed publication, shard/file/cache operations
and other scalar target variants remain open; the overall target/lifecycle stage
is therefore not relabeled fully complete. Next: source exact function/path
query matching and residual delegation, followed by authoritative catalog/index
migration and public collection integration. No durable format change or tuning.

## Verified guarded native leaf matching (2026-11-07)

`lance_json_matcher.mojo` preserves original typed function/path recognition and
adds a necessary indexed-value equivalence check. The source matcher accepts
some literal-key getters against different JSONPath values, serialized JSON text
against unquoted strings, getter coercions against another trained type, and
numeric keys whose array behavior differs. Original source executions retain
these counterexamples; native `try_search` leaves those predicates unhandled.
Utf8 also retains training provenance: extensions converted to strings cannot
substitute for a string getter that errors. Updates/remap preserve this marker;
only full rebuilds can establish string-only values again.

**1,344 source scenarios**, including actual consumer/index values, errors and
source panics, are audited. Native bounded errors replace source panics. The
original rule recognizes 1,120 references; 79 satisfy
the additional guard and execute on the real native index with equal values.
**14 native tests** pass and four fixture files reproduce exactly.
[Evidence](../research/2026-11-07-lance-json-matcher-validation.md).

Covered typed comparisons/ranges/IN/IS NULL delegate to the target; nullable
literals and unsupported queries retain their original predicate. Negation
preserves unknowns, and cancellation reaches matching and target search.
Sargable leaf rules were source-inspected; this fixture does not execute the
whole DataFusion planner. The raw bitmap query API remains separate.

The third required stage stays open. Next implement expression binding/coercion,
residual composition and snapshot-aware selection, retaining per-row short
circuit/error behavior. Broader function-aware index definitions must establish
value equivalence before replacing predicates. Then complete the authoritative
catalog migration and durable public collection lifecycle. No optimization.

## Canonical typed comparison binding (2026-11-07)

`try_compare` now maps the six canonical typed comparison operators to the
existing guarded execution path, following the pinned
`SargableQueryParser::visit_comparison`. `ne` applies the caller-side negation;
range endpoints preserve source inclusion/exclusion. Null/wrong-type literals
and unsupported operators remain unhandled. No implicit coercion or operand
reordering is introduced. Two native tests cover all six operators at lower,
equal, upper and null rows, rejection and cancellation. Full source planner
execution, literal coercion and expression/residual integration remain open;
this addition does not close the third required stage.

## Native expression/residual/snapshot integration (2026-11-07)

Completed the native typed expression binding, nullable ordered residual
execution and snapshot-owned index selection via `ReadSnapshot.prepare_json`.
Prepared queries retain the exact read root through writes, deletion, compaction
and close. Mixed masks/residuals preserve short circuit and unknowns.
Nine integration tests, 26 related Mojo tests, Python build and 109 targeted
Python boundary tests pass. [Evidence](../research/2026-11-07-json-expression-snapshot-validation.md).
This supersedes the earlier native-expression pending notes above. Full SQL/
DataFusion planning, broader function-aware index coverage, durable catalog and
public collection index management remain separate open capabilities.
