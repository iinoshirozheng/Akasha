# DBSF Source Port Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Qdrant distribution-based score fusion to native named-field search, Python and Arrow, with an upstream-source oracle.

**Architecture:** Port Qdrant `distr_norm`/`norm`/Welford computation into a small Mojo query module; accumulate normalized F32 branch scores through the existing captured-root field fusion. Keep RRF as the default and preserve Akasha deterministic ID ties and optional final-field rerank.

**Tech Stack:** Mojo 1.0.0, existing bindings, Python/PyArrow, pinned Qdrant Rust source and a standalone rustc fixture generator.

---

## Source and semantic decisions

- Source: `reference/qdrant/lib/segment/src/common/score_fusion.rs` at
  `74f3e85b9473c62560006c043e13737ce6b48412`, Apache-2.0.
- Follow upstream: empty => empty, singleton/constant => 0.5, Welford **sample**
  variance (`n - 1`), limits `mean +/- 3 * sqrt(variance)`, no clamping, unit weights,
  scores for the same ID summed in branch order in F32, final score descending.
- Input scores follow their existing branch result units, as upstream fusion does;
  do not invent metric-dependent inversions. Document distance-score behavior.
- Named scores convert to F32 at this explicit fusion boundary; preserve native
  exact/rerank scoring contracts. Existing `fusion="rrf"` stays behavior-identical.
- Reject unknown fusion and nonfinite F32 normalization inputs/results with clear
  errors; this is an Akasha boundary adaptation, not claimed upstream parity for NaN/Inf.
- A standalone Rust harness extracts the original upstream functions without
  rewriting the algorithm; minimal ScoredPoint/type shims are recorded. Freeze
  input/output bits and source hash in checked-in fixtures. Compare finite
  calculations with the stated upstream numerical tolerance, not an invented oracle.

## Tasks

1. **Baseline and failing regressions.** Run `rtk proxy pixi run mojo run -I src
   tests/mojo/test_rank_fusion.mojo`. Add `tests/mojo/test_score_fusion.mojo` for
   upstream fixture normalization, no-clamp outliers, constants, singleton, invalid
   input and merged-ID ranking. Run it and retain the missing-implementation failure.
2. **Source/oracle/notice.** Add `scripts/qdrant_dbsf_reference.py`, frozen fixtures
   under `tests/fixtures/qdrant-dbsf/`, and `docs/upstream/ports.json` plus upstream
   license/notice. Verify extraction hash and compile with `rustc`; emit source bits
   and normalized bits without Python reimplementation.
3. **Mojo port.** Create `src/akasha/query/score_fusion.mojo` and call it from
   `src/akasha/query/field_fusion.mojo`. The core sequence is exactly:
   `old_delta=score-mean; mean+=old_delta/count; delta=score-mean;
   aggregate+=old_delta*delta; variance=aggregate/(n-1)` followed by upstream limits.
   Compile/run the focused Mojo tests before any binding build.
4. **Public path.** Thread keyword `fusion: String = "rrf"` through
   `api/{snapshot,collection}.mojo`, `src/bindings/python_module.mojo`,
   `python/akashadb/database.py` and `arrow.py`; validate enum before work and report
   stats `metric_name="dbsf"` when appropriate. No mutation format change.
5. **Integration regressions.** Add `tests/python/test_score_fusion.py` for a real
   collection, two branches, filters, overlap/ties, empty fields, reopen, final rerank,
   invalid mode, Arrow output ownership and unchanged default RRF. Preserve callback
   close validation and resource/cancellation controls. Add a native snapshot case.
6. **Build and test serially.** `rtk proxy pixi run build-native-worker`,
   `rtk proxy pixi run build-python`, then `rtk proxy env PYTHONPATH=python:.
   .pixi/envs/default/bin/python -m pytest tests/python/test_score_fusion.py
   tests/python/test_named_vectors.py tests/python/test_field_ivf.py
   tests/python/test_field_rerank.py tests/python/test_binding_conversion_close.py -q`.
   Run focused native rank/score/named-sparse/rerank tests. Fix failures before claiming the slice.
7. **Documentation/evidence.** Update `docs/python-api.md`, source-port ledger,
   fixture README and master ledger with actual output. `git diff --check` and
   commit the verified slice. Q01 remains open for weighted fusion and service exposure.
