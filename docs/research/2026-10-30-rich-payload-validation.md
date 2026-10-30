# Source-backed rich payload values and durable migration

Date: 2026-10-30. Mojo 1.0.0 (ed45d567), macOS ARM64.
Qdrant v1.19.0 revision: `74f3e85b9473c62560006c043e13737ce6b48412`.

## Delivered behavior

Mojo `PayloadValue` now owns objects, arrays, null and UInt64 alongside its
existing inline string/Int64/Float64/bool values. Container children use a bounded
preorder arena because the installed compiler rejects recursive `List[Self]`
ownership. This is a representation adaptation, not a new query algorithm.
Keys preserve insertion order; duplicate native object construction replaces
the previous value in its original slot. Missing and present null differ.

`payload_path.mojo` ports Qdrant's original value get/set/remove and map merge.
Indexed updates never extend arrays; direct index deletion is a no-op; terminal
wildcard deletion empties an array. Shallow merge removes source-null members,
while storing an ordinary JSON document preserves null. Object deletion follows
serde_json's `preserve_order` swap-removal. Edits publish an owned replacement
only after all validation and construction succeed.

The Python and existing HTTP APIs own rich input/output values. WAL-only reopen,
checkpoint/segment reads, physical backups and NDJSON v2 retain them. Explicit
scalar Python fields preserve existing conversion protocols; nested values use
strict JSON kinds. Unsupported rich Arrow projections fail explicitly.

Existing field conditions apply the source's one-array-level `any` behavior.
Null never matches a field condition, including MatchExcept. Nested arrays are
passed to the leaf check without flattening. Exact signed/unsigned equality
does not wrap UInt64 values. Rich rows are checked by the same native predicate
alongside existing scalar metadata indexes, including after cache restore.
This adds correct unindexed evaluation, not dedicated array/nested indexes.

## Durable format and limits

[Payload v2](../formats/payload-format.md) has an impossible legacy field-count
marker, independent version/reserved fields, and recursive typed values. New
writes use v2, including scalar-only/empty payloads. Existing v1 readers remain;
mutation/checkpoint/compaction rewrites old values in the new inner format.
The enclosing WAL, point and segment layouts are unchanged and already carry
payload length and checksums. Old binaries reject the new marker, so in-place
downgrade is unsupported.

Existing frozen point/WAL/segment fixtures remain byte-for-byte unchanged.
Their compatibility writers explicitly select payload v1; production writers
default to v2. Tests independently construct the expected v2 point upgrade by
inserting the eight-byte inner header and adjusting only its framing lengths.
New standalone v1/v2 fixtures were assembled with Python `struct`, independently
of the native codec. The v2 fixture includes null, negative zero, bool and the
largest UInt64 inside an object/array.

Limits are 16 MiB encoded payload, 1,024 top-level fields, 65,536 total value nodes
and 64 container levels. Tests cover cycles, excessive resources, unknown
versions/tags/flags, duplicate encoded object keys, malformed/truncated payloads,
trailing bytes, and corrupted/torn WAL batches. A recomputed valid outer CRC
ensures unsupported inner versions fail independently of checksum validation.

NDJSON retains v1 reads and exports v2. JSON does not distinguish a positive
Int64 from a same-valued UInt64: nested small UInt64 values retain their numeric
value but not an internal unsigned label. The explicit top-level `uint` tag and
the full UInt64 range survive. Binary v2 retains all value tags.

## Independent source comparison

`scripts/qdrant_payload_reference.py` extracts original source from the pinned
checkout and compiles it with nom 8.0.0 and serde_json 1.0.151, including Qdrant's
`preserve_order` feature. Source, extracted-unit, scaffold and Cargo.lock hashes
are retained in `tests/fixtures/qdrant-payload-values/values.json` and the port
registry. Twelve extracted units cover path structures, value operations, merge
and `ValueChecker`/`Match`. The full original parser is included unchanged.

The oracle supplies **2,088 value operation cases and 110 filter cases**.
Python generates inputs; Rust produces expected results. Native tests compare
ordered typed representations and signed-zero bits, then codec and Python
transport round trips. Direct filtering, metadata indexing, cache decoding,
replacement and deletion all use the source filter fixtures. The filter
scaffold adapts IndexSet to HashSet only for exercised single-literal membership.
These are function-level differentials, not full Qdrant server compatibility.

## Verification

- Reference generator: passed, 2,088 value and 110 filter fixtures.
- **27 native modules / 171 tests passed**: value/codec/source oracle, metadata,
  legacy WAL/segment compatibility, streams, point migration/recovery, mapped
  segments, compaction, merge, backup, batches, snapshots and search.
- Targeted Python formula/path/rich-value modules: **945 passed** after rebuilding
  the extension. Includes explicit scalar conversion compatibility, owner-close
  re-entry checks and rich Arrow rejection.
- `rtk proxy pixi run build-python` and `build-native-worker`: passed.
- `rtk proxy pixi run env PYTHONPATH=python:. pytest tests/python -q --tb=short`:
  **3,060 passed, 1 skipped**, with three existing deprecation warnings.
  The skip is the optional Qdrant Edge integration. The suite includes 26 new
  rich payload tests; targeted tests above overlap and are not added to this total.
- `rtk proxy pixi run test-crash`: **9 modules / 24 tests passed**, covering
  publication, compaction, leases, migration, sparse state and torn batch/tail
  recovery. The lease wrapper displayed a historical worktree source label;
  its Python helper resolves the current project and builds the actual fault
  probe into a new temporary directory on every run.
- `rtk proxy pixi run python tests/crash/run_lease_reclaim_fence.py`: passed,
  independently rebuilding and running the current durability-fence fault probe.
- `rtk proxy pixi run test-c`: passed after rebuilding the native worker and
  C shared library. Existing ABI behavior remains valid; new rich C APIs are
  still outside this slice.
- Current port artifact and pinned upstream source hashes verified;
  `rtk proxy git diff --check` passed.

Validation found and corrected two compatibility issues. Frozen fixture writers
initially used the new default payload header; they now explicitly encode their
historical version, with a separate v2 upgrade assertion. The first full Python
run had 573 setup errors and two failures because strict JSON conversion was
incorrectly applied to explicitly typed scalar values and callback conversions.
The existing scalar conversion contract was restored; nested JSON remains strict.
An earlier test setup used unsupported Collection context-manager syntax and
was corrected to `contextlib.closing`; the product API was unchanged.

## Remaining scope

D01 and D03 stay open. Collection partial path mutations, rich Arrow schemas
with missing/null distinction, arbitrary top-level JSON keys, nested filters,
dedicated indexes, nested/date/geo formula values and complete C/distributed/
Qdrant REST/gRPC boundaries are not delivered by this slice. C ABI regression
does not imply a rich-payload C API. Lance/version/schema/object storage,
SQL/transactions, UI/security/cluster and all other master-ledger rows remain.

No performance optimization or benchmark gate ran. M5/M6 and recommendation
recall failures remain; native Linux acceptance remains deferred by the user.
GPU behavior did not change and its device gate was not rerun.
