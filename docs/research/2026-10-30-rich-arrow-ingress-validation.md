# Rich Arrow ingress validation — D01c1

This is the ingress part of the [rich Arrow plan](../plans/2026-10-30-rich-arrow-source-port.md).
It does not complete D01, rich typed export or Lance compatibility. Features and
correctness remain the priority; no optimization or performance gate changed.

## Behavior and implementation

Both Arrow upsert APIs now decode borrowed payload buffers in Mojo using one
bounded schema and value traversal. Supported physical types are null/bool,
all signed/unsigned integer widths, F16/F32/F64, UTF-8/large UTF-8 and composed
struct/list/large-list/fixed-size-list. Integers widen without passing UInt64
through Python's signed conversion; floating values widen to finite Float64.
The adapter exposes type/buffer descriptors only. It never stages payload rows
as Python list/dict/scalar values or calls `.as_py()` inside the ingress loop.

Parent validity masks children before reading values. Active required children
reject null, invalid active numeric values reject the entire batch, and schema,
row, validity, offsets, child ranges and resource bounds are checked natively.
Accepted values detach from the producer into existing native payload ownership.
One batch retains the existing all-or-nothing WAL publication and post-conversion
collection-close guards. No durable-format change is introduced.

Supplied top-level nulls now remain explicit native null rather than disappearing.
An absent column remains absent; upsert replaces the point. Scalar scanner output
maps both missing and explicit null to Arrow null. Stored non-null mismatches
still fail, and rich typed projections remain pending.

Arrow C Data's NUL-terminated names cannot preserve embedded NUL. Tests exposed
silent truncation by PyArrow's C Data round-trip. Direct RecordBatch schemas are
now checked before capsule export, and native schemas reject these names too.
Empty nested keys, Unicode, and embedded NUL in string values remain supported.
Dynamic `arrow.json` interop is still needed for arbitrary schemaless keys.
Unknown extension metadata is rejected at root and nested fields, preventing an
unregistered extension from silently becoming its plain storage type.

## Source evidence

- Lance source revision `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`, unchanged
  `rust/lance-arrow/src/{list,struct}.rs` compiled into the reference executable.
- Actual Arrow 58.4.0 array/schema/buffer/data/IPC/select and 58.3.0 JSON crates,
  matching Lance's lock. Registry archives and 198 original Rust source-file
  hashes are verified; crate Git revisions are not fabricated when absent.
- Arrow-produced IPC input and explicit-null JSON output: **4 rows × 22 columns,
  88 cells**, plus source assertions for null garbage removal, trimmed lists,
  struct pushdown/normalization and required child validation.
- F16, independent parent/child and bitmap offsets, unsupported/duplicate schema,
  native buffer errors, atomicity, producer detachment, close reentrancy,
  WAL/flush reopen, top-level null projection and bounds have separate tests.

Provenance, reference Cargo.lock and regeneration command are in
[`tests/fixtures/rich-arrow`](../../tests/fixtures/rich-arrow/README.md).
The oracle executes upstream libraries; it does not run Akasha to generate its
expected values. Rust dependencies are used only for reference generation.

## Verification

Final regression results after the last resource-bound change:

- `pixi run build-python`: passed with Mojo 1.0.0 (`ed45d567`).
- Native payload tests: **4 passed** after the final bound change.
- Existing Arrow export/C Data tests: **11 passed**; the later input-budget
  change does not alter these paths. Total related native tests: **15 passed**.
- Targeted Python Arrow/close tests: **222 passed** before the final shared
  payload bound; the full run below covers these tests again after that change.
- `PYTHONPATH=python:. pixi run python -m pytest -q tests/python`:
  **3,330 passed, 1 existing skip, 3 existing warnings**, 79.91 seconds.
  This includes **82 new public tests** for rich ingress.

Logs and exact commands: `.build/rich-arrow-validation/`.
The initial tests caught NUL name truncation and ran scalar output against a
previous binary while its replacement was compiling; subsequent runs are serial.
The initial native test harness also needed explicit Python eval globals, since
Mojo has no Python caller frame; that harness was corrected before rerunning.

The existing crash/C ABI suites were not rerun: this slice changes Arrow ingress
and explicit-null scanner projection, not the durable format or C ABI. Targeted
tests exercise actual WAL and flushed-segment reopen. Linux/device/performance
gates and every other product capability retain their earlier open status.
