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
