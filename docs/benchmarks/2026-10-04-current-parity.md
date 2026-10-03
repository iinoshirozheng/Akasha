# 2026-10-04 current production Qdrant parity checkpoint

**M5/M6 remains incomplete.** The unchanged current production binary completed every resident warm, mixed, and HTTP trial. All matched recall cells passed; all three performance gates failed. Assessment exit 1 means a completed, failed gate, not an interrupted measurement.

| Boundary | Strict QPS and p95 | Matched Recall@10 ≥ .95 | Result |
|---|---:|---:|---|
| Resident binding warm | 22/36 | 36/36 | FAILED |
| Resident mixed queries | 25/36 | 36/36 | FAILED |
| Mixed durable write + flush | 3/9 | — | FAILED |
| Native HTTP, 1/2/4 clients | 18/108 | 108/108 | FAILED |

These are independent current-binary measurements, not an implementation A/B. Earlier gate counts are historical; they are not combined with or used to offset failures in this experiment. Each cell/trial requires QPS ≥ Qdrant and p95 ≤ Qdrant with no tolerance. All slow samples remain.

## Identity and method

- Engine source commit `3a5ad04`; CPU checkpoint/docs HEAD `f125dea`. No source, binary, or route changed during this run.
- Python `_kernel.so`: `53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6`.
- Native worker: `bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`.
- HTTP route: `497da8534c983040f2f5cd6278c56fc60c0e89f54175889e444dde24b3f9a7db`.
- Qdrant REST source `21db2f3ff95d50de3a2b88a741312c056fd1762d`, binary `ee0ddd031084b22be0bb7fd95a90c5b0a521b0d506fedc16034b90f5504b0b28`. Binding Qdrant Edge identity is recorded independently in each report.
- Original fixed 8,192-row corpora, seeds, updates/deletes, four filters, K=10, service boundaries and selected efs; three trials in AB/BA/AB engine order. No retuning.
- Warm/mixed workers use fresh clones of closed original trial-0 templates. HTTP uses the original trial-specific Akasha templates; Qdrant is seeded fresh and waits for its index optimizer. Template/input hashes are retained.
- Warm: three warmups plus 64 timed queries/filter, first query separately. Mixed: 32 blocks × nine queries and eight updates followed by durable flush. HTTP: 1/2/4 concurrent clients, three warmups and 64 timed queries/cell.
- Runs were serial, after full CPU verification, with no build/test/archive compression overlap. Warm 41.27 s, mixed 74.19 s, HTTP 296.31 s. All three returned their expected FAILED exit 1.

| Corpus | Akasha efs (all/correlated/independent/selective) | Qdrant efs |
|---|---|---|
| uniform-128 | 128 / 32 / 32 / 10 | 96 / 256 / 256 / 10 |
| uniform-1536 | 512 / 128 / 128 / 10 | 512 / 512 / 512 / 10 |
| real-1536 | 16 / 32 / 40 / 10 | 24 / 128 / 128 / 10 |

## Complete cell results

Each table entry is **Akasha/Qdrant QPS ratio / p95 ratio**, followed by P (both thresholds pass) or F. Higher QPS and lower p95 are better. Trial numbers are zero-based. Full raw latencies, IDs, score bits, stats, execution routes and recall remain in the archive. Ratios shown rounded here do not change the unrounded gate.

### warm

| Corpus | Filter | Clients | Trial 0 | Trial 1 | Trial 2 |
|---|---|---:|---|---|---|
| uniform-128 | all | — | 0.778 / 1.470 F | 0.746 / 1.510 F | 0.983 / 0.788 F |
| uniform-128 | correlated | — | 1.796 / 0.785 P | 2.891 / 0.371 P | 3.023 / 0.286 P |
| uniform-128 | independent | — | 3.117 / 0.380 P | 2.466 / 0.505 P | 3.065 / 0.325 P |
| uniform-128 | selective | — | 1.430 / 0.551 P | 1.110 / 0.788 P | 1.055 / 1.036 F |
| uniform-1536 | all | — | 2.369 / 0.467 P | 2.524 / 0.396 P | 2.487 / 0.401 P |
| uniform-1536 | correlated | — | 1.542 / 0.727 P | 1.471 / 0.742 P | 1.541 / 0.712 P |
| uniform-1536 | independent | — | 1.481 / 0.747 P | 1.546 / 0.691 P | 1.542 / 0.682 P |
| uniform-1536 | selective | — | 1.246 / 0.743 P | 1.288 / 0.686 P | 0.912 / 1.036 F |
| real-1536 | all | — | 1.052 / 0.960 P | 0.842 / 1.269 F | 1.142 / 0.898 P |
| real-1536 | correlated | — | 0.786 / 1.184 F | 0.760 / 1.171 F | 0.899 / 0.933 F |
| real-1536 | independent | — | 0.836 / 1.180 F | 0.675 / 1.546 F | 0.756 / 1.267 F |
| real-1536 | selective | — | 0.974 / 1.016 F | 0.983 / 0.981 F | 1.259 / 0.680 P |

### mixed

| Corpus | Filter | Clients | Trial 0 | Trial 1 | Trial 2 |
|---|---|---:|---|---|---|
| uniform-128 | all | — | 1.494 / 0.653 P | 1.572 / 0.528 P | 1.606 / 0.651 P |
| uniform-128 | correlated | — | 2.955 / 0.695 P | 2.957 / 0.668 P | 3.386 / 0.438 P |
| uniform-128 | independent | — | 3.180 / 0.461 P | 2.944 / 0.525 P | 3.070 / 0.508 P |
| uniform-128 | selective | — | 1.130 / 2.353 F | 1.292 / 0.916 P | 1.360 / 0.861 P |
| uniform-1536 | all | — | 2.521 / 0.344 P | 2.353 / 0.355 P | 2.423 / 0.394 P |
| uniform-1536 | correlated | — | 1.722 / 0.642 P | 1.634 / 0.632 P | 1.696 / 0.623 P |
| uniform-1536 | independent | — | 1.824 / 0.552 P | 1.714 / 0.621 P | 1.733 / 0.612 P |
| uniform-1536 | selective | — | 1.040 / 1.717 F | 0.947 / 1.523 F | 1.049 / 0.984 P |
| real-1536 | all | — | 1.028 / 0.896 P | 1.001 / 0.965 P | 0.902 / 1.096 F |
| real-1536 | correlated | — | 0.931 / 1.140 F | 0.901 / 1.146 F | 0.831 / 1.230 F |
| real-1536 | independent | — | 0.611 / 1.664 F | 0.590 / 1.658 F | 0.544 / 1.921 F |
| real-1536 | selective | — | 1.091 / 0.968 P | 1.045 / 0.976 P | 0.960 / 1.583 F |

### http

| Corpus | Filter | Clients | Trial 0 | Trial 1 | Trial 2 |
|---|---|---:|---|---|---|
| uniform-128 | all | 1 | 0.780 / 1.263 F | 0.700 / 1.422 F | 0.724 / 1.426 F |
| uniform-128 | all | 2 | 0.813 / 1.090 F | 0.695 / 1.593 F | 0.636 / 1.729 F |
| uniform-128 | all | 4 | 0.846 / 1.350 F | 0.756 / 1.771 F | 0.869 / 1.268 F |
| uniform-128 | correlated | 1 | 1.121 / 0.758 P | 0.770 / 1.446 F | 0.814 / 1.349 F |
| uniform-128 | correlated | 2 | 0.929 / 1.183 F | 0.875 / 1.141 F | 0.930 / 1.175 F |
| uniform-128 | correlated | 4 | 0.877 / 1.153 F | 0.882 / 1.300 F | 0.871 / 1.250 F |
| uniform-128 | independent | 1 | 0.760 / 1.623 F | 0.615 / 2.614 F | 1.018 / 1.005 F |
| uniform-128 | independent | 2 | 0.924 / 1.121 F | 0.926 / 1.194 F | 0.854 / 1.373 F |
| uniform-128 | independent | 4 | 0.909 / 1.322 F | 0.955 / 1.345 F | 0.890 / 1.165 F |
| uniform-128 | selective | 1 | 0.820 / 1.267 F | 0.852 / 1.162 F | 0.789 / 1.334 F |
| uniform-128 | selective | 2 | 0.884 / 1.071 F | 0.962 / 0.920 F | 0.783 / 1.246 F |
| uniform-128 | selective | 4 | 0.872 / 1.202 F | 1.312 / 0.709 P | 0.879 / 1.214 F |
| uniform-1536 | all | 1 | 1.718 / 0.593 P | 1.579 / 0.641 P | 1.574 / 0.689 P |
| uniform-1536 | all | 2 | 1.938 / 0.529 P | 1.777 / 0.573 P | 1.829 / 0.544 P |
| uniform-1536 | all | 4 | 1.646 / 0.711 P | 1.502 / 0.831 P | 1.530 / 0.832 P |
| uniform-1536 | correlated | 1 | 1.053 / 0.975 P | 1.101 / 0.822 P | 1.067 / 0.946 P |
| uniform-1536 | correlated | 2 | 0.786 / 1.391 F | 0.868 / 1.336 F | 0.925 / 1.142 F |
| uniform-1536 | correlated | 4 | 0.717 / 1.696 F | 0.645 / 1.919 F | 0.700 / 1.570 F |
| uniform-1536 | independent | 1 | 1.085 / 0.938 P | 1.061 / 0.939 P | 1.090 / 0.899 P |
| uniform-1536 | independent | 2 | 0.915 / 1.023 F | 0.897 / 0.956 F | 1.007 / 1.003 F |
| uniform-1536 | independent | 4 | 0.730 / 1.576 F | 0.768 / 1.658 F | 0.847 / 1.488 F |
| uniform-1536 | selective | 1 | 0.679 / 1.459 F | 0.820 / 1.177 F | 0.796 / 1.240 F |
| uniform-1536 | selective | 2 | 0.795 / 1.202 F | 1.070 / 1.070 F | 0.749 / 1.379 F |
| uniform-1536 | selective | 4 | 0.774 / 1.265 F | 0.763 / 1.288 F | 0.764 / 1.203 F |
| real-1536 | all | 1 | 0.793 / 1.274 F | 0.747 / 1.426 F | 0.797 / 1.213 F |
| real-1536 | all | 2 | 0.882 / 1.065 F | 0.808 / 1.149 F | 0.734 / 1.503 F |
| real-1536 | all | 4 | 0.709 / 1.585 F | 0.685 / 1.649 F | 0.685 / 1.768 F |
| real-1536 | correlated | 1 | 0.815 / 1.160 F | 0.810 / 1.178 F | 0.749 / 1.373 F |
| real-1536 | correlated | 2 | 0.714 / 1.169 F | 0.769 / 1.258 F | 0.647 / 1.600 F |
| real-1536 | correlated | 4 | 0.615 / 1.969 F | 0.662 / 1.768 F | 0.717 / 0.496 F |
| real-1536 | independent | 1 | 0.697 / 1.592 F | 0.757 / 1.310 F | 0.721 / 1.418 F |
| real-1536 | independent | 2 | 0.860 / 1.037 F | 0.712 / 1.461 F | 0.761 / 1.181 F |
| real-1536 | independent | 4 | 0.599 / 1.828 F | 0.777 / 0.428 F | 0.666 / 1.492 F |
| real-1536 | selective | 1 | 0.806 / 1.198 F | 0.766 / 1.306 F | 0.772 / 1.332 F |
| real-1536 | selective | 2 | 0.747 / 1.367 F | 0.784 / 1.244 F | 1.007 / 0.918 P |
| real-1536 | selective | 4 | 0.769 / 1.172 F | 0.752 / 1.356 F | 0.857 / 1.044 F |

### Durable writes and reopen

Write + flush includes the durability boundary and uses all 32 paired observations per trial. Each reopen ratio is one final observation, **not** a p95 distribution or a passed reopen gate.

| Corpus | Trial | Write+flush QPS ratio | Write+flush p95 ratio | Gate | Reopen duration ratio |
|---|---:|---:|---:|---|---:|
| uniform-128 | 0 | 1.424 | 0.694 | PASSED | 1.586 |
| uniform-128 | 1 | 1.425 | 0.712 | PASSED | 2.001 |
| uniform-128 | 2 | 1.528 | 0.609 | PASSED | 1.752 |
| uniform-1536 | 0 | 0.664 | 1.462 | FAILED | 2.471 |
| uniform-1536 | 1 | 0.705 | 1.297 | FAILED | 2.523 |
| uniform-1536 | 2 | 0.638 | 1.561 | FAILED | 2.628 |
| real-1536 | 0 | 0.760 | 1.262 | FAILED | 2.542 |
| real-1536 | 1 | 0.793 | 1.207 | FAILED | 2.723 |
| real-1536 | 2 | 0.768 | 1.340 | FAILED | 2.463 |

## Audits and validation scope

- Warm: 4,608 timed result audits, 216 warmup audits, 4,824 independent exact checks, 18 first-query audits. Akasha IDs/F32 score bits/stats match across all three trials on the same templates.
- Mixed: 5,184 query audits; all 18 final reopen exact checks passed, and all nine Akasha Arrow leases survived writes/close. All 576 write batches and 576 flush observations retained.
- HTTP: 4,824 exact preflights, 4,824 approximate preflights, 13,824 timed audits and 648 warmup audits: 24,120 total. All valid; no transport/audit failures.
- Existing current-source CPU evidence remains applicable: [1,001 Mojo / 23 crash / three rebuilt examples / existing C client](../research/2026-10-04-cpu-integration.md), and the same binary’s [388 full Python / 129 targeted Python](2026-10-03-python-vector-validation.md). No tests or builds were rerun during this benchmark-only package.
- This is resident measurement. Sustained nonresident and controlled memory-limit are unverified; no native Linux runner is available. No new Linux, GPU, ASan or distributed functional run is claimed.

## Reproduction and immutable evidence

Archive: [2026-10-04-current-parity.json.gz](results/2026-10-04-current-parity.json.gz), SHA-256 `2acea3566eae5e2d4fe34bd35d3f157f601a491ca587a96442bcfe17cdaa63e2` (22,144,831 bytes; 311 text entries). Every archived text hash was checked after decompression. It contains plans/drivers, copied exact measurement harnesses, all reports/raw samples, commands, inputs/template hashes, server logs/configs and build identity; no database or executable payload.

The local output is `.build/2026-10-03-current-parity`; the directory date reflects preparation before the date changed. Assessment is read-only except its derived JSON and can be reproduced with:

```sh
rtk proxy pixi run python .build/2026-10-03-current-parity/assess.py
```

Expected exit: **1**, with the counts above. For fresh timing, recover the archived drivers into a new `.build` directory and retain the original pinned corpora/templates, dependencies, binaries and compiler-wrapper environment. Run that directory’s `run.py`; it creates fresh warm/mixed/HTTP outputs and must not overwrite this experiment. The driver verifies production SHA and the completed CPU checkpoint before measuring. Do not run old drivers blindly in their original output directories.

## Remaining work

Current warm failures include uniform-128 full scans and real-data correlated/independent ANN. High-dimensional write+flush fails all six trials. HTTP remains broadly behind Qdrant. Profile these exact workloads and preserve validation/durability semantics before choosing another implementation. M5 named first-build/multi-run reopen costs and the remaining M6 gates are still open.
