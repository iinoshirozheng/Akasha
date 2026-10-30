# Lance Materialized Row-Set Validation

Date: 2026-10-31. Baseline: `65b2e2e`. Mojo `1.0.0 (ed45d567)`.

The next index dependency now has a compiled native path: arbitrary UInt64
row sets and Lance's nullable allow/block mask algebra. This preserves the
identity and three-valued result contract required by the scalar target;
it is not yet a collection index or a full Roaring implementation.

## Source and implementation

`src/akasha/index/roaring_rows.mojo` ports roaring-rs 0.11.4 point insertion,
removal, membership, iteration and binary set operations. That version and
archive checksum match pinned Lance's lockfile. It retains upper UInt32 maps,
sorted UInt16 container keys, sorted sparse arrays, 1024-word bitmap stores,
the source 4096-entry transition, ordered merge visitors and array/bitmap
dispatch. Mojo Dict replaces the upper BTreeMap; sorted key iteration preserves
source order. Existing lower-bound code and native bit operations are reused.
No dense allocation spans the UInt64 universe, and IDs remain unsigned without
rounding or conversion through Float64/Python.

`src/akasha/index/nullable_rows.mojo` ports Lance's actual nullable mask NOT,
AND and OR formulas, and nullable-set true-row selection and union_all.
Raw selected and null sets can overlap, or nulls can exist only in nulls.
Nulls override selected. Allow/block negation represents complements without
enumerating a universe; both raw representation and semantic states match.
Existing Qdrant-style filter semantics are not changed to SQL semantics.

The materialized-row oracle compiles the original roaring crate and original
Lance nullable method bodies. Only DeepSizeOf import/derive are removed from
the source module; a finite-row wrapper supplies the same set interface using
actual RoaringTreemap operations. Full-fragment maps, serialization, caching
and planner behavior are outside this adapter's evidence.

## Validation

| Original-source evidence | Count |
| --- | ---: |
| Set scenarios | 309 |
| Union/intersection/difference/XOR results | 1,236 |
| Insert outcomes | 112,021 |
| Remove outcomes | 9,853 |
| Nullable mask scenarios | 564 |
| NOT/AND/OR/union_all results | 2,256 |
| Nullable probe states | 27,072 |

All original outputs match, including exact ordered UInt64 lists, cardinality,
duplicate mutation return values, raw selected/null sets and mask kind. Cases
exercise every array/bitmap pairing, threshold transitions in both directions,
UInt64.MAX, full 16-bit containers, multiple 16/32-bit partitions, empty sets
and unknown rows outside selected.

Five new native tests and five existing JSON-index input tests pass:

```text
rtk proxy pixi run python scripts/lance_rowset_reference.py
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_rowset.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_json_index_input.mojo
```

The JSON input regression retains all 32,405 source conversion outcomes.
Repeated source generation reproduces all fixture files byte-for-byte.
Commands, hashes and logs are retained in `.build/lance-rowset-validation/`;
fixture metadata and the port registry provide committed provenance.

The corrected red test first demonstrated absent native modules. Test-only
Mojo scalar/list construction errors and a missing `raises` declaration for
Dict lookup were corrected; their logs are retained. No source behavior was
changed to make the port pass.

## Limits and remaining work

RoaringRowSet defaults to 10 million materialized IDs and 64 MiB of logical
native state: map keys, bitmap/container descriptors and live array/bitmap
payloads. These limits exclude allocator and Dict/List capacity overhead;
they do not promise a peak-RSS ceiling. Operations can temporarily hold an
additional combined UInt32 partition before the result limit check. Mutation
preflight rejects over-limit insertions before changing the set; failed binary
operations leave both inputs intact. Returned sets and copied sets own data.

Binary operations use the left operand's limits; values() separately bounds
the materialized UInt64 output buffer. Native QueryControl checks are supported
at operation start, between upper partitions and between output containers.
They are cooperative boundaries, not interruption inside every container word
operation. Nullable composite methods currently use the default set-operation
controls; the future planner must thread its controls when integrating them.

Point-mutation stores use Array/Bitmap. Range insertion, Run containers,
full-fragment selections and portable Roaring serialization remain open.
No application runtime imports these modules yet; existing public APIs and
durable formats are unchanged. The prior full Python **3,752 passed / 1 skip**
results remain applicable and were not rerun or relabeled as new evidence.

Next: source scalar ordering (including Float64 total order), sorted value-run
training/merge, actual bitmap lookup and nullable search results, then JSON
stream training, query matching and durable catalog/public integration.
The complete [index plan](../plans/2026-10-31-lance-json-index.md), all 49 full
product packages, M5/M6 and deferred Linux acceptance remain open. No tuning.
