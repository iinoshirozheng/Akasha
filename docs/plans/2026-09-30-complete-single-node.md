# Complete the remaining single-node work

> **For Codex:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Finish the user-authorized #54–#63 work, the compaction stability issue,
and named/native-scalar/binary/multivector support, with durable migration and
end-to-end verification. Completion of one slice does not complete this goal.

**Architecture:** Extend ADR 0007's immutable read roots and independent field
owners. Use existing Mojo/Python/PyArrow interfaces; isolate durable schema changes
from index-cache and buffer changes. Keep `tasks/todo.md` as the execution checklist.

**Tech Stack:** Project-pinned Mojo 1.0.0/MAX 26.5.0, Python 3.11, NumPy, PyArrow,
native pthread worker, Pixi; local references under the main checkout's `reference/`.

## Delivery order and evidence

Each implementation slice starts with a failing behavioral test, then implementation,
targeted verification, its measurement where required, documentation, and a separate
commit. Preserve established format readers and public APIs. Continue authorized work
across checkpoints without requesting permission again.

1. **#54 SQ8:** inspect existing uncommitted implementation and recorded gates;
   run `pixi run mojo run -I src tests/mojo/test_quantized_search.mojo`, then commit.
2. **#55 PQ:** root-owned artifacts keyed by all actual training parameters
   (subquantizers, centroids, iterations; current initialization is deterministic,
   with no seed parameter). Reuse one ready artifact across metrics, k, and rerank.
   Use the existing `ArtifactState` and official `Dict`. Add cooperative query/build
   cancellation through existing `QueryControl`; never publish partial builds.
   Files: `index/artifact_state.mojo`, `storage/read_generation.mojo`,
   `api/snapshot.mojo`, `index/quantization.mojo`, `test_product_quantization.mojo`.
   Test repeated/concurrent queries, all key parameters, root freshness, cancellation,
   build failures, close, and oracle parity; measure cold and warm separately.
3. **Compaction stability + #56:** inspect real conflict transitions and reproduce
   the race before changing coordination. Pin graph inputs, build outside the writer
   lock, bounded catch-up, validate config/source, publish and retire sidecars safely.
   Files: `api/collection.mojo`, `index/segmented_hnsw.mojo`, maintenance/retirement
   modules as callers require; compaction/HNSW publication and crash tests.
4. **#57 direct Arrow results:** `src/bindings/python_module.mojo`,
   `python/akashadb/arrow.py`, `tests/python/test_arrow_c_data.py`, ingress benchmark.
   Output I64 IDs/F32 scores to official typed buffers without per-row Python objects;
   test empty/ties/slices/closed-source ownership and account for copies.
5. **#58 scanner:** prove real Mojo C Data callback/owner lifetime on the pinned
   compiler, then implement bounded run/chunk scanning with borrowed contiguous
   buffers and owned gather/cast output. Test release, close, cancel, slices and
   projection using real Arrow consumers. Files per #58 in `tasks/todo.md`.
6. **#59 comparison:** fixed commits/hardware/data checksums; synthetic 128/high-D
   plus real embeddings; compare equivalent service boundaries at matched recall.
   Add reproducible `benchmarks/qdrant_compare.py`, raw results and report. Failed
   recall cells remain failed; do not claim parity without measured acceptance.
7. **#60/#61 primitives:** inspect the pinned official comparator/sort/heap APIs;
   adapt one component per commit only after semantic and scaling gates. Preserve
   measured rejection evidence if an official API is not suitable.
8. **#62 WAL decode:** bounded owner-backed reader and record decoding; retain CRC,
   overflow/bounds/old-version/torn-tail/append-repair behavior. Measure peak memory.
9. **#63 read-only copies:** borrow fingerprint inputs and check sparse liveness
   without materializing documents; verify unchanged bytes and failure sequences.
10. **Field schema + named F32 + atomic combined mutation:** first commit durable
    catalog/record specifications and fixtures, then reader-first migration,
    writer/API and search/reopen slices. Preserve legacy data and unknown-version
    rejection; test torn writes, rollback/forward recovery and field independence.
11. **Native F16/BF16/I8/U8:** implement each authority dtype with ingress bounds,
    exact distance oracles, persistence, bindings, query and reopen tests.
12. **Binary:** native packed bits with bit dimension/padding and Hamming/Jaccard;
    own format migration and full write/read/search/reopen tests.
13. **Multivector:** ragged offsets, empty-row semantics and MaxSim/late interaction;
    persistence, named-field/filter integration, bindings and reference oracle.
14. **Integration:** reconcile stale README/architecture docs; CPU/Python, crash,
    C ABI, build/examples and quality gates; actual-device GPU only for changed GPU
    behavior. Audit every task and typed-field matrix cell against current evidence,
    then integrate the completed branch without overwriting unrelated user edits.

## Test commands

Targeted: `pixi run mojo run -I src tests/mojo/<test_file>.mojo`.
Python Arrow: `pixi run build-python`, then
`pixi run env PYTHONPATH=python:. pytest tests/python/test_arrow_c_data.py -q`.
Integration: `pixi run test`, `pixi run test-crash`, `pixi run test-c`,
`pixi run build`, `pixi run check-hnsw-quality`, `pixi run check-post-hnsw-quality`.
Reuse successful unchanged gates; record command, source revision, results and limits.

## Completion audit

The authoritative requirements are this goal's full scope, #54–#63 in
`tasks/todo.md`, ADR 0007, the M2/M4/M5/M6 contracts in
`2026-09-07-single-node-lifecycle-zero-copy.md`, and format/API compatibility.
No checkbox is evidence by itself. Inspect implementation, tests and measured
artifacts for each requirement before marking the overall goal complete.
