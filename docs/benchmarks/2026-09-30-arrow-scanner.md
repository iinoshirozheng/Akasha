# Leased scanner and native Arrow C Data export

`scan_record_batches(collection, ...)` now captures an immutable view, scans one
run at a time and yields bounded PyArrow RecordBatches. The Mojo API is
`ReadSnapshot.scanner()`. Each selected batch holds bounded ordinals and a strong
root owner; it does not call `documents()`, build a full-snapshot ordinal list or
stage Python rows. New writes and index publications leave acquired scans intact.

## Buffer and release contract

Current dense storage owns one F32 vector per row. Single-row vector columns
borrow that allocation and retain the generation. Multi-row vectors gather
directly into final native column buffers. IDs, sequences, sparse term/weight
columns and typed payload projections also own their output. Absent sparse and
payload fields are null; present payload type mismatches fail and close the
scanner. Explicit payload types give every batch the same schema without a
whole-collection discovery pass. The default projection includes ID, vector and
both sparse columns; sequence and typed payload fields are optional.

The exporter implements the standard ArrowArray header, per-node private owner,
aligned buffers and a real Mojo `abi("C")` release callback. PyArrow constructs
the schema and imports the header synchronously inside the binding. The public
API returns normal RecordBatches with PyArrow's own capsule export support; it
does not expose raw pointer integers. Unconsumed or failed exports clean up via
RAII. A moved child owns its state independently; parent cleanup releases only
children whose release callback is still non-null. Owned columns have no root
pin, while the final borrowed child/slice releases its source generation.

This follows the [Arrow C Data release/move contract](https://arrow.apache.org/docs/format/CDataInterface.html).
The implementation was first proven with an isolated compiled extension using
the pinned Mojo 1.0.0 and the installed PyArrow consumer. The native C ABI test
compares all field offsets against PyArrow's installed official `arrow/c/abi.h`
and compares sizes, alignment and callback representation with compiled Mojo.

The cursor has one consumer. Errors and explicit close discard its root;
exhaustion releases it automatically. Previously returned batches remain valid.
Python cancellation is checked between batch calls; native cancellation/deadline
checkpoints cover slot scanning and column materialization. Candidate limits
count visited physical slots, including hidden/deleted/filtered slots. The
default 64 MiB output buffer limit counts allocation padding and closes a scan
whose next batch exceeds it. It excludes source roots, bounded selections and
Arrow metadata. Keeping an old borrowed slice can intentionally retain an entire
old generation and its files.

## Verification

On the final worktree based on `31f27e5`:

- `pixi run build-python` and the complete Python suite passed **111 tests**.
  This includes the existing 46 Arrow ingress/result tests, 18 scanner cases and
  the external C layout probe. Scanner coverage includes sparse ragged values,
  UTF-8/empty strings, Boolean bitmap boundaries, all-null columns, signed-I64
  limits, U64 sequences, zero columns, empty collections/results, projections,
  filters, limits, deadlines, cancellation and all six orders of closing the
  collection/cursor/parent batch while retaining a slice. Independent scanners
  keep old and new views while writes, deletes and flush/index publication occur.
- **35 targeted Mojo tests** passed: scanner (4), actual C Data export (6),
  existing snapshots (10), concurrency (6), and exact file retirement (9).
  Pointer equality is checked against the native source vector, not another
  exported view. PyArrow imports a moved header and a manually relocated child.
  Generation pin counts prove borrowed last-slice release and immediate source
  release for gathered columns. Partial export failures discard borrowed children.
- A real compaction/close test retains its old base until the last Arrow slice
  dies, then verifies immediate file reclamation. A Python consumer releases the
  last borrowed slice on another thread and verifies retired HNSW sidecar removal.
- `pixi run build`, `pixi run test-c`, and all three built examples passed.
  `git diff --check` passed. Two native binding `__module__` warnings (Collection
  and Scanner) and the existing Starlette deprecation warning remain in pytest.

This slice changes read iteration and bindings, not durable bytes, write ordering,
HNSW scoring or GPU execution. The unchanged kernel's earlier 761-test CPU and
19-test crash evidence remains recorded in the
[file-retirement report](2026-09-30-file-retirement.md); those entire suites were
not rerun for this read-only addition. No Linux-host or actual-device GPU run is
claimed here; the C layout probe runs in the existing Python CI matrix.

## Costs

Command:

```sh
pixi run env PYTHONPATH=python:. python benchmarks/arrow_scanner.py \
  --output docs/benchmarks/results/2026-09-30-arrow-scanner.json
```

Each batch-size cell uses a separate process, 4,096 rows × 128 F32 coordinates,
ascending I64 IDs, and deterministic `arange % 101` values. Ingress is through
the established Arrow API. A warm scan establishes the shared root and import
cost before five timed complete scans of the ID/vector projection. Each pass
checks the ID checksum and returned row count. Timing includes Python iteration
and zero-copy NumPy ID reduction; it is not a native-kernel-only measurement.

| Batch rows | Median complete scan | Materialized bytes, entire scan | Borrowed bytes, entire scan | Largest batch materialized bytes | RSS peak before → after |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 24.898 ms | 32,768 | 2,097,152 | 8 | 90.891 → 93.422 MiB |
| 128 | 1.151 ms | 2,129,920 | 0 | 66,560 | 88.906 → 88.953 MiB |
| 1,024 | 0.946 ms | 2,129,920 | 0 | 532,480 | 86.578 → 86.594 MiB |
| 4,096 | 0.998 ms | 2,129,920 | 0 | 2,129,920 | 86.641 → 90.125 MiB |

One-row batches avoid dense copying but pay 4,096 binding/import calls. Larger
batches copy the dense values while reducing that overhead. Materialized bytes
are source-derived logical output buffer sizes; metadata/headers, allocation
padding, source roots and interpreter allocations are separate. Per-batch output
buffer size is bounded by the requested chunk size, not the full dataset.

RSS uses the OS process high-water mark (`getrusage`), including setup, imported
libraries, producer arrays and the collection. Setup may already establish a
higher watermark than scanning; a small peak increase does not imply no native
allocation. Ordinary iteration can briefly retain the previous batch while the
next one is created. These are warm, dense-only, single-host diagnostics, not
service QPS, cold-RSS guarantees or a matched-recall comparison.

[Raw samples and provenance](results/2026-09-30-arrow-scanner.json) record source
SHA-256 `1c95194649df7532688d65e0adcf2243605bbe0612e1cb9ad3f0cdcd8a8fc110`,
the benchmark checksum, toolchain and deterministic dataset checksum. Source
identity uses the prior path/NUL/bytes/NUL algorithm over sorted `rg --files src
tests native include python`. The recorded hash matches the final source tree.

This completes #58's current F32/payload/sparse implementation and verification.
Commits/branch integration, #59–#63 and named/native/binary/multivector work remain
open. Those future field types must extend the scanner's schema and buffer tests.
