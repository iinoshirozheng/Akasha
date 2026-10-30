# Collection payload mutation validation

Date: 2026-10-30. Mojo 1.0.0 (ed45d567), macOS ARM64.
Baseline: `ec09624`. Qdrant v1.19.0 source:
`74f3e85b9473c62560006c043e13737ce6b48412`.

## Source and implementation

Read Qdrant's shard `update/payload.rs`, `update/helpers.rs`, `update/mod.rs`,
`operations/payload_ops.rs` and segment `segment/entry.rs`. They establish the
four operations, point/filter selection, missing-point errors, payload-only
changes and existing point ownership. Value semantics reuse the original-source
JSON-path/map port and its Rust-generated fixtures from D01b.

`PayloadUpdate` adapts the ordered document root separately from nested values.
Its name/value lists do not add an artificial container level to every field.
Root set uses the source shallow merge and swap removal; overwrite retains
null, delete applies parsed paths in order, and clear removes payload fields.
Nested operations call the same ported value functions. Empty/NUL nested keys
are accepted; existing top-level naming constraints remain.

`prepare_payload_mutations` selects live points from the authoritative point
table. Explicit IDs take precedence over a filter, as in source dispatch.
Filters use the existing native predicate. The collection holds its writer lock
across selection, reading, transformation and the existing atomic point-batch
commit. Complete replacement payloads enter the unchanged WAL; vector updates
are absent. Existing metadata, HNSW/read-root publication and I/O failure
handling therefore follow the established point-write path.

Python exposes set_payload/overwrite_payload/delete_payload/clear_payload, and
the current HTTP service exposes their routes. Both are transport layers.
The Mojo boundary rechecks the owner after all potentially reentrant conversion
and bounds actual iterator output as well as reported input lengths.

## Native contract adaptations

- Qdrant may update earlier chunks before discovering a missing point in a later
  chunk. Akasha preserves its established all-or-nothing native batch contract;
  all selected replacements validate before any WAL append.
- Explicit duplicate IDs select one point once; filter targets are ID ordered.
  Qdrant's internal segment/chunk counters are not exposed as this native result.
- Empty selection performs no write and returns count=0, first_sequence=0 and
  unchanged last_sequence. Qdrant bumps operation acknowledgment versions for
  no-op operations; Akasha row sequences are a different contract.
- Root names remain nonempty/NUL-free. Input maps and deletion paths are each
  bounded to 1,024 members; target counts respect max_batch_rows and the native
  65,536 limit. Durable payload/WAL limits remain enforced.
- The HTTP routes use Akasha filter syntax and BatchWriteResult responses;
  they are not full Qdrant REST/gRPC compatibility claims.

## Verification

- `rtk proxy pixi run mojo --version`: 1.0.0 (ed45d567).
- `rtk proxy pixi run mojo run -I src tests/mojo/test_payload_updates.mojo`:
  **3 tests passed**. Includes **1,644 original-source mutation cases**, depth-64
  fields, null merge/overwrite, actual collection batch publication, unchanged
  vector ownership, old snapshots, missing-target rollback, empty/deduplicated
  selectors, WAL-only recovery and checkpoint reopen.
- `rtk proxy pixi run build-python`: passed.
- Initial targeted public suite: **17 passed**. A final iterator-budget test was
  added and is included in the complete suite below.
- `rtk proxy pixi run env PYTHONPATH=python:. pytest tests/python -q --tb=short`:
  **3,078 passed, 1 skipped**, three existing deprecation warnings; **18 new
  payload-mutation tests**. The optional Qdrant Edge integration remains skipped.
- Public source comparison runs the same 1,644 cases through real Python writes.
  It checks ordered JSON text, preserving scalar kind distinctions and negative
  zero. Named F16, binary, sparse, multivector and default vectors survive edits
  and both WAL-only and flushed reopen. Tests also cover scalar Arrow snapshots,
  array filter selection, no-prefix failure from an oversized resulting payload,
  resource limits, torn batch rollback, concurrent disjoint merges, conversion
  close, malformed inputs and all four HTTP operations.
- `rtk proxy git diff --check`: passed. Port registry records upstream and current
  artifact hashes.

Final API review expanded invalid-input tests and reproduced acceptance of a
dictionary where an ID list was required. The same iterable conversion also
allowed a string to be interpreted as individual deletion paths. The native
boundary now requires lists for both inputs, while accepting bounded list
subclasses and rechecking the owner after conversion. This validation-only
correction passed a rebuild and targeted mutation-suite rerun: **18 passed**.
Other paths retain the complete-suite result above; these overlapping tests are
not added to the full-suite count.

Of D01b's 2,088 reference cases, 238 are read-only and 206 require top-level keys
outside the current persisted document contract. They are not claimed as new
public mutation coverage; all 2,088 remain covered by the prior owned-value
helper test. D02 retains the top-level-key gap. Selection/dispatch was inspected
in original source; this is not a full Qdrant server differential.

No durable layout, recovery algorithm, existing vector algorithm or C ABI changed.
The immediately preceding baseline's 171 related native tests, 24 crash tests and
C ABI checks remain applicable to those unchanged paths. They were not rerun or
added to this slice's test totals. New mutation-specific recovery is tested above.
GPU and deferred native Linux gates were not run. No performance gate resumed.

## Remaining full goal

D05 stays open for combined mixed-operation batches, remaining vector/filter
CRUD and full protocol integration. D01 rich Arrow, D02 keys/IDs, D03 nested
filter/index types, formula traversal and the entire Lance/SQL/UI/security/
cluster/operations ledger remain. M5/M6 and recommendation recall failures are
unchanged. Finish those functional requirements before optimization.
