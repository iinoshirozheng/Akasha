# JSON expressions and catalog indexes in Arrow scanning

Implemented against the [approved scope](../plans/2026-11-08-json-arrow-scanner.md)
using Mojo 1.0.0 (ed45d567) on macOS arm64. No dependencies or durable formats
changed. Existing native prepared expression semantics, read-generation owners,
ReadScanner and Arrow C Data export are reused; no upstream algorithm is newly
ported in this integration.

## Behavior verified

- `scan_record_batches(json_expression=..., indexes=[...])` prepares from the
  same root used for physical row scanning and Arrow projection. Residual-only
  scans omit indexes. Named indexes without an expression are rejected.
- The ordinary filter runs first, then JSON. Native per-row evaluation is shared
  with `PreparedJsonQuery.execute`; physical ID lookup resolves bitmap ordinals
  by binary search. No complete matched-ID list is created.
- Physical run/slot ordering is preserved; visibility excludes shadowed and
  deleted rows. Indexed/residual projections match, nullable NOT retains unknown,
  logical short circuit skips invalid JSON, and later residual/projection errors
  remain deferred until iteration reaches them.
- Scanner and returned Arrow batch owners survive mutation, index drop, flush,
  compaction and collection close. Exhaustion releases the query/root; explicit
  close, cancellation, deadlines and errors close terminally. Returned batches
  keep their buffers independently.
- Preparation checks live candidate count; iteration checks physical visited
  slots, including hidden history. Cancellation is sampled before preparation
  and between batches; native deadlines apply to preparation and scanning.
  Output byte-limit failures release the scanner. Snapshot-sized locations and
  masks remain outside the per-batch output byte cap, as documented.

## Executed checks

1. Initial three Python tests failed on missing `json_expression`/`indexes`
   parameters before implementation, demonstrating the absent behavior.
2. `pixi run build-python`: passed with the native implementation.
3. `pixi run mojo run -I src tests/mojo/test_scanner.mojo`: four passed.
4. `pixi run mojo run -I src tests/mojo/test_json_expression_snapshot.mojo`:
   nine passed after extracting shared per-row evaluation.
5. `pixi run mojo run -I src tests/mojo/test_json_scanner.mojo`: final two
   passed, covering pinned batches across compaction/close and deadline cleanup.
6. `PYTHONPATH=python:. pixi run pytest -q` on `test_json_arrow_scanner.py`,
   `test_json_catalog.py`, `test_arrow_scanner.py`, `test_rich_arrow_scanner.py`,
   `test_jsonb_projection.py`, `test_jsonb_condition.py` and
   `test_binding_conversion_close.py`: final **202 passed**, four preexisting
   extension/Starlette deprecation warnings, 13.31 seconds.
7. `git diff --check`: passed.

The first broad Python run had 201 passed and one failed callback test: a direct
internal binding caller lacked newly required options and raised a missing-key
error. Internal test dictionaries were updated to the new contract, preserving
their close-during-conversion assertion; the final 202-test run passed. There is
no compatibility fallback in production code. Other intermediate counts overlap
and are not added to these results.

This is targeted functional acceptance, not a full CPU/platform/performance run.
Disk bitmap encoding, lazy file/cache access, external sorting/spill and other
index targets remain separate work.
