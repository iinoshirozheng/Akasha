# D03f point/path filter validation

Date: 2026-10-30. Parent `b03241d`; Mojo `1.0.0 (ed45d567)`, macOS ARM64.
Plan: [point filter source port](../plans/2026-10-30-point-filter-source-port.md).

## Source and implementation

Qdrant v1.19.0 `74f3e85b9473c62560006c043e13737ce6b48412` supplies
`query_checker.rs` point/path branches and nested identity isolation,
`common/utils.rs` whole-path null/empty checks, and `types.rs` Slice
validation, canonical ID encoding and hashing. SipHash-2-4 is translated from
the actual Qdrant-locked siphasher 1.0.3, commit
`451f67d73a772cba325728109bbfa247750ed076`; no replacement hash algorithm or
runtime Rust/Python evaluation is introduced.

`PointCondition` owns ID sets, vector selectors and validated slice parameters.
`PointFilterContext` provides the current ID, authoritative present vector IDs
and retained catalog. Nested objects deliberately start with absent identity
and vector context. Boolean nodes preserve the outer context. Standalone
`is_empty` uses all-path-value semantics; `is_null` tests explicit returned nulls
without implicit array flattening. Existing field-property semantics stay intact.

Payload-only metadata caches retain their format. IDs are available from their
existing slot map; vector-aware expressions use the authoritative aligned
MemTable/PointState and catalog independently, following Qdrant's separation of
payload index, ID tracker and vector storage. Search, scanners, formula scoring
and condition-selected mutations use the same point-aware evaluator. Snapshots
retain old vector presence; vector removal and replacement affect current views.
Empty sparse and multivector values remain present independently of searchability.

Native storage still uses signed Int64 IDs. Negative IDs retain their existing
contract and hash their UInt64 two's-complement encoding. Full UInt64/UUID point
storage remains D02; UUID canonical-byte hash tests do not enable that API.
Empty vector name selects default dense field 0; explicit native `field_id: 1`
selects the independent default sparse field. The latter is an Akasha selector,
not Qdrant protocol parity. No durable format or write protocol changed.

## Independent evidence

`scripts/qdrant_point_filter_reference.py` extends the original payload oracle.
Seven pinned files / 84 extracted units, scaffold and Cargo.lock hashes were
independently verified. Dependency archive checksums match Qdrant Cargo.lock,
and eight dependency source/metadata files match archive bytes. Six SipHash
units and the original COPYING notice are recorded. The adaptation selects
Apache-2.0 and includes its full text via the retained license.

- **12,656 source rows:** 5,509 matches, 7,118 nonmatches, 29 expected errors.
- **2,187 hash cases** within those rows: zero/max/random bytes of lengths
  0..512, 518 numeric UInt64 IDs and 130 UUIDs. Hash outputs match exact UInt64
  bits; canonical ID hashes match the same original byte streams.
- **9,573 public-applicable source rows** also run through actual native-backed
  Python and Arrow queries. Missing-ID-tracker and hash-only cases run natively.
- Native checks cover cloned predicates, signed IDs, parameter revalidation,
  slice partitions/correlated subsets, deleted metadata IDs and independent
  PointStore search. Whole-path vs field checks, nested negation and minimum
  conditions are evaluated by the original Rust checker.

The Rust scaffold changes storage/index plumbing to a single-ID tracker and
named-vector presence map. It retains original condition arms and nested empty
context. Standard HashSet replaces MaybeArc/AHashSet; canonical numeric/UUID
transport uses untagged serde decoding. This is not a server, protocol-ID or
Qdrant index/planner acceptance test. Python creates inputs only.

## Validation

Heavy builds and tests run serially. Logs: `.build/point-filter-validation/`.

| Command (prefixed with `rtk proxy`) | Result |
| --- | --- |
| `pixi run python scripts/qdrant_point_filter_reference.py` | Source oracle built; 12,656 rows / 84 units; final regeneration reproduced fixture, dependency and lock bytes exactly |
| `pixi run python` dependency/provenance checks | Archives, source units, scaffold, lock and COPYING verified |
| `pixi run mojo run -I src tests/mojo/test_point_filter.mojo` | **5 passed** |
| `pixi run mojo run -I src tests/mojo/test_persistent_filters.mojo` | **14 passed** |
| `pixi run build-python` | Passed |
| `pixi run python -m pytest -q tests/python/test_point_filter.py` | **36 passed**, 3 existing warnings; 4.39 seconds |
| Five additional native filter/index/mutation/formula modules | **26 passed**; `native.json` records commands and results |
| `env PYTHONPATH=python:. pixi run python -m pytest -q tests/python` | **3,248 passed, 1 skipped**, 3 existing warnings; 81.99 seconds |

Public integration includes default/named dense exact and HNSW, named IVF,
default/named sparse, hybrid, parallel batches, parent prefetch filters, formula
conditions, Arrow queries/scanners, HTTP search/mutation and rejection before
writes or candidate selection. WAL-only and checkpoint reopen, vector removal,
empty sparse/multivector presence and retained snapshot/scanner views are covered.

Diagnostics retained: initial oracle hash-output insertion matched helper
returns as well as main; it is now restricted to main and original source-unit
hashes were rechecked. Initial native test compilation used the wrong UInt64
accessor and tried copying a move-only document list; corrected to the existing
`_uint` converter and ownership transfer. The first full Python invocation
omitted the project's PYTHONPATH environment: **162 failed / 3,086 passed /
1 skipped**; all failures were child-process `akashadb` import errors. That
failed log is retained separately from the corrected-environment run.

All seven native modules total **45 passed**. Earlier successful point-filter
and persistent-filter runs were reused without redundant execution. No source
behavior was changed after the successful Python build and tests.

## Remaining scope

D03/Q04 remain open for dedicated geo/date/array/nested/UUID/text indexes,
typed-index formula retrieval, indexed tokenizer/BM25/phrase behavior,
sampling/feedback and complete protocols. Rich Arrow, full numeric/UUID IDs,
mixed CRUD batches, Lance/version/schema/Blob/object-store, SQL/transactions/
constraints, UI/security/cluster/operations and all other master-ledger tasks
remain open. M5/M6 and recommendation recall failures are unchanged; no
optimization or performance acceptance is claimed. Native Linux stays deferred.
