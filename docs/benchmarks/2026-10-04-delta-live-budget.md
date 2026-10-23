# Bounded live-vector work and delta history — 2026-10-04

Adopted on top of `f963365` (production engine `9bf69e0`). The small-delta policy now charges live rows for vector scoring and separately bounds physical history inspection. This removes a measured search-cost jump when a fixed-size delta accumulates replacements. **M5/M6 remains incomplete; the full original performance gate is FAILED.**

## Implementation and decision

Only `src/akasha/index/segmented_hnsw.mojo` changes in the engine. It uses the existing cached source live count; the private predicate signature is replaced, with no compatibility overload or public setting. Every condition is required:

- A live immutable base and `0 < delta_live <= physical_slots`.
- At most 1,024 live rows and 1,572,864 live vector components.
- Physical slots at most `max(1024, 2 * delta_live)`, never above 2,048.
- Physical slots still bounded by normalized initial ef times M0.

Division/subtraction avoid overflow. Delta-only collections and the known low-ef/large-delta regressions stay on graph search. Scan/graph loops, admission, candidate breadth, query/candidate validation, metric arithmetic, public scoring, ownership, durable formats and rebuild settings are unchanged. Inactive headers are visited but their vectors are not scored.

The [preceding 324-cell history sweep](../research/2026-10-04-mixed-query-work.md) supports separating these costs. This package then verifies actual public queries. The new path lowers foreground CPU in all nine affected late-phase diagnostic groups. That bounded, reproducible benefit supports incremental adoption despite the original matrix's remaining failures and timing regressions. Adoption is not the final Qdrant gate; no tolerance or cross-cell offset was introduced.

## Correctness and integration

Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4. The two new history behavior tests first compiled against the baseline and failed at the expected graph-versus-scan assertion. Both original failures are retained.

The candidate passes **146 unique targeted Mojo tests**: 9 narrow cases plus 137 related HNSW/native/filter/widening/planner/recovery/cache cases. New cases cover overflow, work ceilings, 1,110/1,200 physical slots with 600 live rows, replacement/delete/reinsert history, owned/mapped bases, all 11 supported metric/scalar backends (22 owned/mapped combinations inside one test), filters, exact public score bits, bounded candidates, stable ties and the 1,201-slot exclusion. Existing invalid-query/identity/demand and delta-only cases remain.

**506 full Python tests, C ABI/client and three rebuilt examples pass.** The isolated binding is built from copied `after-src/bindings/python_module.mojo`. Pytest uses `-o pythonpath=` with import/hash guards. The child wrapper remaps both relative and absolute root includes: 17 compiler invocations audited, 12 root include remaps. The Metal wrapper and Pixi Python PATH are inherited.

After promotion, the formal paths pass another **9 Mojo / 26 Python**, C loader/client and three example runs. These are repeated checks, not additional unique integration counts. The C loader path and all source/binary hashes are verified. The worker is unchanged. TestSuite durations in raw logs are milliseconds.

There is no new full Mojo or crash suite here; the change affects only query strategy selection, with targeted recovery/cache coverage above. No new HTTP performance, Linux, GPU, ASan, sustained nonresident or controlled-memory gate is claimed. No Linux runner is available.

## Original fixed performance matrix

All **54 workers** finish with exit 0, serially, with original three corpora, three trials, seeds, filters, K, efs, service boundaries and raw samples. The complete assessment correctly exits **1 (FAILED)**. CPU diagnostics below do not replace these samples.

| Boundary | Before strict parity | After strict parity | Matched recall, each version |
|---|---:|---:|---:|
| Warm | 21/36 | 21/36 | 36/36 |
| Mixed queries | 28/36 | 26/36 | 36/36 |
| Mixed write+flush | 4/9 | 4/9 | — |

Every cell still requires Recall@10 ≥ .95, QPS ≥ Qdrant and p95 ≤ Qdrant. Each trial is judged separately. These are this package's fresh same-batch results, not merged with the prior package's counts.

Five performance pass→fail cells are retained:

- Warm: real-1536, trial 1, all.
- Mixed: uniform-128, trial 0, selective.
- Mixed: uniform-1536, trial 1, selective.
- Mixed: real-1536, trial 2, all and correlated.

Warm has 24/36 A/B timing regressions (QPS down or p95 up); mixed has 22/36. Real mixed independent still has QPS only .649–.827 of Qdrant; it is not a new parity pass. Timing changes also occur in unchanged-path controls; they are retained without assigning all differences to noise or to this source change.

Warm: 7,236 query audits and 7,236 exact-oracle checks; 2,412 A/B query pairs have identical IDs, all stats and 24,120 F32 score bits. Mixed: 7,776 query audits, 2,592 A/B pairs with identical IDs and 25,920 F32 score bits; all 27 final reopen oracles and 18 Akasha retained leases pass. Mixed stats match in 2,472 pairs; all **120 differences** are explicitly audited below.

## Actual path changes

Only real-1536 ANN queries before blocks 26–31 change from `segmented-f32` to `segmented-delta-scan-f32`: 39 all, 39 correlated and 42 independent queries across three trials. All IDs, recall and scores stay identical. Only physical/distance/filter/inactive visit counters and the storage label change; ef, widening and retained candidate counts do not. Selective remains the planned exact path.

| Changed mode | Mean distance evaluations before | After | Change |
|---|---:|---:|---:|
| all | 1,611.54 | 1,762.31 | +9.36% |
| correlated | 1,621.69 | 1,148.62 | −29.17% |
| independent | 2,474.79 | 1,778.93 | −28.12% |

The all case scores more vectors; lower CPU cannot be described as a universal distance-count reduction. The scan also avoids delta graph navigation. Every exact stats difference and every original early/late timing group is saved in `matrix-summary.json` and `path-audit.json`.

## Additional CPU diagnostic

Six fresh real-1536 workers execute the original full 32-block mixed plans, in B/A, A/B, B/A order. Extra wall/thread/process clocks are diagnostic only and change instrumentation; they are not an acceptance boundary. All 1,728 query audits, 864 A/B pairs / 8,640 score bits, six final reopen oracles and six leases pass. All 1,728 cross-run queries also match the original matrix's IDs, bits, stats, oracle and recall.

Late blocks 26–31 are a preidentified code-path phase, not removed samples. All earlier blocks and selective controls are retained. Foreground CPU ratios below are after/before; smaller is faster.

| Mode / phase | Trial 0 | Trial 1 | Trial 2 |
|---|---:|---:|---:|
| all / 0–25 | 1.0112 | 0.9773 | 0.9975 |
| all / 26–31 | 0.8316 | 0.9106 | 0.8962 |
| correlated / 0–25 | 1.0019 | 0.9856 | 0.9671 |
| correlated / 26–31 | 0.7687 | 0.8337 | 0.8535 |
| independent / 0–25 | 1.0083 | 0.9948 | 0.9930 |
| independent / 26–31 | 0.7182 | 0.7961 | 0.8350 |
| selective / 0–25 | 1.0178 | 0.9785 | 1.0472 |
| selective / 26–31 | 0.9042 | 0.8985 | 1.0577 |

Across the full diagnostic query stream, foreground CPU falls 3.6–4.6% in each pair. All nine changed late ANN groups lower CPU by 9–28%; one of the 12 whole-mode query groups has a CPU/wall increase. Write/flush samples also remain: total measured query+write+flush work increases in two of three pairs. No particular lock or background-maintenance cause is established by wall-minus-thread time.

## All original query timing ratios

Each entry lists trial 0 / 1 / 2. QPS is after/before (higher is faster); p95 is after/before (lower is faster). No slow trial is removed. Original per-trial Qdrant ratios, pass/fail verdicts, raw query samples and write/flush measurements are all in the archive.

| Boundary / corpus / mode | QPS ratios | p95 ratios |
|---|---|---|
| warm / uniform-128 / all | 1.0092 / 0.9615 / 0.9962 | 0.9927 / 1.1157 / 0.9880 |
| warm / uniform-128 / correlated | 0.9840 / 1.0292 / 0.7941 | 1.0494 / 0.8797 / 1.4347 |
| warm / uniform-128 / independent | 0.7676 / 0.7058 / 0.9346 | 1.7788 / 2.1363 / 1.2168 |
| warm / uniform-128 / selective | 1.0443 / 0.9134 / 0.9587 | 0.9148 / 1.0184 / 1.0763 |
| warm / uniform-1536 / all | 0.9149 / 0.9545 / 1.0298 | 1.1718 / 1.0526 / 0.9556 |
| warm / uniform-1536 / correlated | 0.9500 / 0.9902 / 1.0259 | 1.0646 / 1.0071 / 0.9511 |
| warm / uniform-1536 / independent | 0.9750 / 0.9945 / 1.0407 | 1.0348 / 0.9968 / 0.9787 |
| warm / uniform-1536 / selective | 1.0960 / 1.0174 / 1.0168 | 0.7636 / 0.8903 / 0.9928 |
| warm / real-1536 / all | 1.0157 / 0.9590 / 1.0043 | 0.9943 / 1.0630 / 1.0182 |
| warm / real-1536 / correlated | 1.0284 / 1.0112 / 0.8868 | 0.9546 / 1.0103 / 1.1596 |
| warm / real-1536 / independent | 0.9900 / 0.9985 / 0.8663 | 1.0170 / 1.0021 / 1.2119 |
| warm / real-1536 / selective | 1.0250 / 1.0732 / 0.9517 | 0.8859 / 1.0043 / 1.0307 |
| mixed / uniform-128 / all | 0.9614 / 0.9492 / 0.9761 | 1.0578 / 1.2001 / 0.9552 |
| mixed / uniform-128 / correlated | 0.9466 / 1.0326 / 1.0910 | 0.9714 / 0.5997 / 0.6451 |
| mixed / uniform-128 / independent | 1.0125 / 0.9466 / 0.9714 | 0.7954 / 0.9272 / 1.0548 |
| mixed / uniform-128 / selective | 0.8320 / 1.1413 / 1.1802 | 2.3027 / 0.9907 / 0.3405 |
| mixed / uniform-1536 / all | 1.0279 / 0.9656 / 1.0186 | 1.0578 / 1.0501 / 1.0212 |
| mixed / uniform-1536 / correlated | 1.0755 / 0.9515 / 1.0609 | 0.9631 / 1.0364 / 0.8975 |
| mixed / uniform-1536 / independent | 1.1015 / 0.9232 / 1.0193 | 0.9335 / 1.2522 / 1.0047 |
| mixed / uniform-1536 / selective | 1.1135 / 0.8811 / 1.0467 | 1.0686 / 1.2526 / 0.7437 |
| mixed / real-1536 / all | 0.9868 / 1.0366 / 0.8826 | 1.0057 / 0.8918 / 1.3705 |
| mixed / real-1536 / correlated | 0.9698 / 1.0551 / 0.9032 | 0.9848 / 0.8966 / 1.0153 |
| mixed / real-1536 / independent | 1.0211 / 1.0926 / 0.9096 | 0.8875 / 0.7764 / 1.1357 |
| mixed / real-1536 / selective | 0.8983 / 1.0329 / 0.8191 | 1.2555 / 0.8879 / 1.3019 |

## Identity, reproduction and remaining work

The exact tested artifacts were promoted; Python and C were not rebuilt into different production binaries after measurement.

- `python/akashadb/_kernel.so`: `eb3bebdea9ea4f9d8050d965af1625003d7aec9d841f02fbc9bf101c05f73945`.
- `.build/c/libakasha_c.dylib`: `e97b2885e0490cea8f2ac304269bd9223c176c15ddce5af9782bbc1158886a82`.
- `.build/c/test_akasha_c_api`: `011d6142869a8616a24cadf708fff85cab8159b3e9f9ab008fa510b7692dda8d`.
- `.build/native/libakasha_worker.so`: `bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`.

[Immutable evidence archive](results/2026-10-04-delta-live-budget.json.gz): `1ed7117a675c89ee7d299ebfa8ee84e9f240b50a90b9b0e6988fcc933e99a72b`, 521 text entries / 4,764,796 bytes. Every embedded text hash was verified after decompression. It includes both source snapshots, the initial failing cases, all test/build/worker logs, plans/input hashes, all samples, counter differences and diagnostic clocks. Large binaries/database/workload payloads are represented by SHA-256.

Restore drivers into a fresh output directory; do not rerun writing drivers over frozen evidence. `run_mojo.py`, `build.py`, `matrix.py`, `cpu-diagnostic.py`, `integration.py` and `validate-promotion.py` retain exact RTK commands, environment and hash guards. Saved pytest keeps `-o pythonpath=`; child compiles keep both include remaps. Benchmarks remain serial and separate from tests/builds/compression. The current narrow root check is reproducible with:

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run -I src tests/mojo/test_delta_live_history.mojo
```

Continue the remaining original real ANN / selective / maintenance failures and the named multi-run/update/reopen artifact lifecycle. Single-run named caching does not finish that lifecycle. Sustained nonresident/controlled-memory verification remains unavailable without a supported runner. This bounded query optimization does not complete M5/M6 or repeat the October 2 Git delivery.
