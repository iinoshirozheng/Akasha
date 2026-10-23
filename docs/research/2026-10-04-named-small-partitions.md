# Named small-partition search diagnostic — 2026-10-04

Production `1318457` is unchanged. Native measurements on the former bundle's actual graph bytes support **bounded scan of additional small partitions** as the next implementation. This does not adopt the old bundle, prove public speed or complete M5/M6.

The [former lifecycle candidate](../benchmarks/2026-10-04-named-graph-bundle.md) saved 43–93× in reopen first-query time but added graph work and regressed all 36 common-recall warm QPS comparisons. The [partition trace](2026-10-04-named-partition-work.md) showed 649/170-slot graphs contributing extra traversal. This package measures a different search mechanism on those exact graphs; it does not repeat the original unchanged candidate or its build/update cohort.

## Inputs and measured boundary

Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4. The probe compiles against a complete copy of current source. No production source, binding or worker is replaced. Nine serial workers use all three original corpora and trials, the six original efs, four filters and 67 queries per cell (three original warmups plus 64 measured queries). Stored kind-5 graph bytes, membership, original inputs and prior reports are checked by SHA/CRC; native graph/config decoders retain their full validation.

Each corpus has a leading 8,192-slot graph with 7,168 current members. Uniform-128 adds one 819-slot graph; both 1536D corpora add 649- and 170-slot graphs. Current membership across the bundle is exactly the 7,987 authoritative IDs. Query filters and membership are computed from the original workload, without altering data or graphs.

The scan is a diagnostic copy of the current checked delta scan, with a direct HNSW owner. It retains query preparation, identity/range/backend checks, current/member/filter admission, per-scored-candidate validation, bounded heap and public F32 score operations. Only non-leading graphs satisfying the existing live/history/component/ef policy are eligible. Leading graph search, original candidate budgets and widening remain. Scan/graph order alternates by query and trial; each candidate search is timed in native code. No graph build or decode is in this interval.

**This is partition-search timing only.** Filter construction, field wrapper, candidate merge, authoritative F64 rerank, cache IO, Python and service boundaries are outside it. Complete-query numbers below sum measured partition intervals; they are not end-to-end QPS or Qdrant ratios. No new thresholds or user options are selected from these timing samples.

## Correctness evidence

- 38,592 graph-partition rows, including **24,120 scan/graph pairs**; all nine workers exit 0.
- **2,513,574 common candidate F32 score bits agree**. Every candidate is unique and belongs to the correct current/filter membership. Every scan returns exactly its bounded demand and scores exactly the admitted rows.
- **24,120 scan top-10 ID orders match an independent Float64 authority oracle**, including warmups and all ef/trials.
- Offline native-score candidate merge plus independent F64 rerank reconstructs **14,472 original bundle results**, with all IDs, recall, distance evaluations and widening counts matching the frozen prior report.
- The independent oracle is computed **804 unique times**, cached across identical trial inputs, and explicitly revalidated against 2,412 corpus/trial oracle references. These are separate counts; repeated references are not additional calculations.

Hybrid final IDs differ from graph-only in 54/14,472 queries; all changes are retained. They occur at ef32 in uniform-128 all/correlated and uniform-1536 all/correlated/independent. Global fixed-ef quality remains **141/216** for each strategy, with **75 low-recall cells** retained and no new quality pass→fail versus the bundle. Relative to the old rebuilt single graph, its three existing uniform-128 independent/ef128 failures remain .94375 versus .95. This diagnostic does not repair those failures or justify changing frozen efs.

Global F64 rerank here is an independent Python oracle computation; this is not a claim that a new native public F64 implementation or its bits have been tested. The common-bit count above refers to graph candidate F32 scores.

## All selected native cost ratios

Each corpus/filter/trial selects the first original ef where both graph-only bundle and scan hybrid reach .95. This selection compares the two diagnostic strategies, not the former production merged graph. All 216 curve cells and 576 partition cells are retained. No quality failure is deleted.

| Corpus / mode | Ef | Mean ratio, trials 0 / 1 / 2 | p95 ratio, trials 0 / 1 / 2 |
|---|---:|---|---|
| uniform-128 / all | 128 | 0.7943 / 0.7925 / 0.7957 | 0.8001 / 0.8012 / 0.8040 |
| uniform-128 / correlated | 128 | 0.7305 / 0.7314 / 0.7317 | 0.7387 / 0.7415 / 0.7485 |
| uniform-128 / independent | 256 | 0.7222 / 0.7197 / 0.7221 | 0.7273 / 0.7362 / 0.7062 |
| uniform-128 / selective | 128 | 0.8474 / 0.8464 / 0.8466 | 0.8186 / 0.8360 / 0.7305 |
| uniform-1536 / all | 512 | 0.8658 / 0.8649 / 0.8635 | 0.8615 / 0.8696 / 0.8711 |
| uniform-1536 / correlated | 512 | 0.8348 / 0.8345 / 0.8330 | 0.8389 / 0.8298 / 0.8351 |
| uniform-1536 / independent | 512 | 0.8347 / 0.8329 / 0.8330 | 0.8375 / 0.8261 / 0.8339 |
| uniform-1536 / selective | 256 | 0.9339 / 0.9344 / 0.9347 | 0.9344 / 0.9362 / 0.9409 |
| real-1536 / all | 32 | 0.8888 / 0.8838 / 0.8880 | 0.8851 / 0.8790 / 0.8614 |
| real-1536 / correlated | 32 | 0.7312 / 0.7300 / 0.7306 | 0.7578 / 0.7617 / 0.7505 |
| real-1536 / independent | 32 | 0.7195 / 0.7276 / 0.7249 | 0.7568 / 0.7113 / 0.7727 |
| real-1536 / selective | 64 | 0.7569 / 0.7516 / 0.7512 | 0.8299 / 0.8037 / 0.8114 |

Ratios are hybrid/graph-only; smaller is faster. All 36 selected means/p95 improve. Summed partition-search mean falls about 6.5–28.1%; p95 falls about 5.9–29.4%. All 360 eligible small-partition cells also improve mean/p95 (mean ratios .0122–.7988, p95 .0130–.7230). No all-curve mean/p95 regression was observed in this native cohort, including the low-recall cells. These sums cannot be added to old public timing cohorts to predict or certify end-to-end gains.

The local Qdrant reference uses available-vector counts and estimated filter cardinality to choose plain versus graph search ([pinned dispatch source](https://github.com/qdrant/qdrant/blob/74f3e85b9473c62560006c043e13737ce6b48412/lib/segment/src/index/hnsw_index/hnsw/read_view/dispatch.rs)). Its source/hash are retained. This is precedent for a per-index strategy decision, not proof of Akasha's numerical limits or speed.

## Decision and next implementation

Proceed with [the scoped bundle plus bounded-partition plan](../plans/2026-10-04-named-bounded-partitions.md) in a fresh isolated tree. Rebase the bundle lifecycle onto current source, preserve later fixes/F64 rerank, and use a shared checked HNSW scan for eligible additional partitions before close and after load. Test the full codec/publication/lease lifecycle and all native backends; then run the original complete named public lifecycle grid and affected original Qdrant gates. Do not rerun the old bundle unchanged, lower budgets or reuse rejected graph repair.

Production kernel remains `eb3bebdea9ea4f9d8050d965af1625003d7aec9d841f02fbc9bf101c05f73945`; worker remains `bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`. Current original gate remains warm 21/36, mixed 26/36, write+flush 4/9, overall FAILED. There is no new full Mojo, Python, crash, C ABI, HTTP, Linux, GPU, ASan or nonresident/memory-limit validation here. No supported Linux runner is available.

## Failures, identity and reproduction

Two input-preparation failures occurred before workers: the old report key is `complete_cache`, not `final_cache`; config CRC covers bytes 4:56, excluding magic, unlike the cache envelope. Original scripts/failure records remain. The first probe compile rejected a loop variable shadowing its HNSW owner argument; original source/log/hash remain. The corrected source compiles. An initial summary counted cached trial oracle references without separating computations; the corrected analyzer records 804 computations and explicitly checks 2,412 references, preserving the initial version. No benchmark was rerun, and no timing sample was removed.

Probe source SHA-256: `f4c83b1d5bb14c3dcb9c5a97d1a7a91a4d9ae6ded98a068f7d47b6aca03a4009`.
Native executable SHA-256: `105af4783bc3e65fcecba464960cdba7055e8549c712e8d7518b09f7dbbf16ab`.

[Immutable archive](../benchmarks/results/2026-10-04-named-small-partitions.json.gz): `ba6e94f988f531d85bdf760ad4039437ce0748c46ddd26849f10845821de07eb`, 175 text entries / 23,424,783 bytes, every embedded text hash verified after decompression. It saves current source, both probe versions, preparation failures, build logs, jobs, complete raw candidate/score/timing logs, all oracle audits, changes, summaries, reference and next plan. Large graph/query/workload/binary payloads are represented by hashes and reproducible extraction instructions; original graph authority remains in the prior frozen cohort.

Restore into a fresh directory before invoking `prepare.py`, `build-v2.py` and `run.py`; they create exclusive outputs and must not overwrite this evidence. `analyze.py` only rechecks saved samples. All commands start with RTK; native compilation inherits the Metal wrapper and project PATH. All workers/builds/analysis/archive compression were sequenced without overlapping benchmark and build/test/compression. The output directory is `.build/2026-10-04-named-small-partitions`; M5/M6 remains open.
