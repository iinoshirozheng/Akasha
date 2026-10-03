# 2026-10-04 payload scratch experiment and baseline lock stall

**Not adopted. Production source and Python binary remain unchanged. M5/M6 is incomplete.** Reusing payload encoding scratch reduced maintenance cost, but a complete three-way comparison introduced two warm pass→fail cells. Mixed gains do not offset those failures. A separately observed baseline lock stall also remains unresolved.

## Evidence and hypothesis

Profiles used unchanged production `53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6` at `87f845b`. Four seven-second warm diagnostics (five-second native sampling each) checked all 248,000 repeated IDs/F32 score bits/stats against the latest fixed gate. Uniform-128 all remains dominated by checked distance and default-field lookup; real correlated/independent ANN remains dominated by mapped distance. No query validation was removed.

Two original full mixed plans were sampled starting at their first write. All 576 query audits, two final reopen oracles and two Arrow leases passed. High-dimensional flush wall/foreground CPU totals were 938/852 ms (uniform) and 1004/915 ms (real). CPU work includes fingerprinting, payload encoding and byte-list allocation/reallocation; fsync alone is not the explanation. These sampled timings are diagnostics, not acceptance latencies.

Source inspection found both fingerprint and metadata-cache loops creating a fresh payload byte builder for every row. The isolated candidate adds caller-owned scratch to the existing payload encoder, backed by the existing List clear/capacity behavior. Both cache loops reuse one writer. The old owned-return API delegates to the same encoder; all per-field validation, payload limits, order, bytes, checksum and durability operations remain. No dependency, global cache, schema change or ownerless span was added. Local Qdrant payload storage uses its existing serde JSON encoder; there was no reusable project-format encoder to import.

Candidate Python SHA-256: `f59be5bd94dd329c7ce7b80f36e3ad6c6fb022e4ef38cfb6ca9d16263f239d42`. Four source files differ only in the isolated copy: document codec, BinaryWriter, authoritative fingerprint and metadata cache encoder. They were **not promoted**.

## Isolated validation

- Two new Mojo tests cover independent UTF-8/all-kind/signed-zero bytes, large→small→empty scratch, retained capacity/address, framed borrowed writes, duplicate rejection, oversized payload and retry. They first fail compilation because the new overload/accessors are absent, then pass.
- **67 targeted Mojo**, **388 full Python**, **9 related crash tests**, rebuilt **C ABI/client**, and **three rebuilt/executed examples** pass on isolated candidate sources. Child compiles inherit the Metal wrapper and remap `-I src` to the isolated source; pytest uses `-o pythonpath=` and verified candidate import/hash.
- Three micro-harness compilation errors (explicit Int64 conversion and DocumentField ownership/clone handling) were corrected before measurement; all logs remain. A matrix-parent missing PYTHONPATH failure occurred before any matrix output/measurement and is retained.
- Production source/binary/native worker hashes stayed unchanged. Candidate tests are not relabeled as a new full production Mojo/crash run. Existing [production CPU](../research/2026-10-04-cpu-integration.md) and [Python](2026-10-03-python-vector-validation.md) evidence remains applicable.

## Native microbenchmark

8,192 rows, fixed four-field payload, ten measurements per phase, three alternating pairs per dimension; independent before/after metadata bytes and fingerprint/checksum agree. Each value is **after/before mean duration**, with all ten samples retained.

| Dimension | Trial | Fingerprint | Metadata encoding |
|---|---:|---:|---:|
| 128 | 0 | 0.318 | 0.236 |
| 128 | 1 | 0.255 | 0.191 |
| 128 | 2 | 0.261 | 0.199 |
| 1536 | 0 | 0.637 | 0.184 |
| 1536 | 1 | 0.627 | 0.183 |
| 1536 | 2 | 0.656 | 0.195 |

## Completed A/B mixed cohort

The original three corpora × three trials use 32 blocks of nine reads, eight updates, then durable flush; before/after order AB/BA/AB and fresh closed templates. All 2,592 paired query ID/F32-bit/stats/execution checks, 5,184 query audits, 18 reopen oracles and 18 leases pass. Final metadata-cache payload hashes and authoritative checksums match in every pair. This cohort is separate from the subsequent three-way gate.

All nine flush and combined write+flush p95 values improve. Five write-only p95 values regress; 22/36 query cells regress in QPS or p95. Full raw query and operation samples remain, including selective tail regressions. Reopen ratios are single observations per trial, not p95 distributions.

| Corpus | Trial | Write p95 ratio | Flush p95 ratio | Write+flush p95 ratio | Reopen ratio |
|---|---:|---:|---:|---:|---:|
| uniform-128 | 0 | 1.015 | 0.577 | 0.698 | 0.926 |
| uniform-128 | 1 | 1.015 | 0.640 | 0.742 | 0.919 |
| uniform-128 | 2 | 1.056 | 0.675 | 0.769 | 0.923 |
| uniform-1536 | 0 | 0.908 | 0.777 | 0.851 | 0.935 |
| uniform-1536 | 1 | 0.994 | 0.721 | 0.856 | 0.963 |
| uniform-1536 | 2 | 1.024 | 0.751 | 0.856 | 0.928 |
| real-1536 | 0 | 0.960 | 0.619 | 0.740 | 0.979 |
| real-1536 | 1 | 0.967 | 0.773 | 0.830 | 0.961 |
| real-1536 | 2 | 1.027 | 0.818 | 0.884 | 0.932 |

### A/B query regressions

| Corpus | Trial | Filter | After/before QPS | After/before p95 |
|---|---:|---|---:|---:|
| uniform-128 | 0 | all | 1.034 | 1.069 |
| uniform-128 | 1 | correlated | 0.931 | 1.571 |
| uniform-128 | 2 | all | 0.985 | 0.989 |
| uniform-128 | 2 | correlated | 0.942 | 1.189 |
| uniform-128 | 2 | independent | 0.970 | 0.954 |
| uniform-1536 | 0 | correlated | 1.032 | 1.001 |
| uniform-1536 | 0 | independent | 1.016 | 1.028 |
| uniform-1536 | 1 | all | 0.979 | 1.042 |
| uniform-1536 | 1 | correlated | 0.971 | 1.001 |
| uniform-1536 | 1 | independent | 0.962 | 1.068 |
| uniform-1536 | 2 | all | 1.002 | 1.055 |
| uniform-1536 | 2 | correlated | 0.993 | 1.077 |
| uniform-1536 | 2 | independent | 0.986 | 1.017 |
| real-1536 | 0 | all | 1.019 | 1.038 |
| real-1536 | 0 | independent | 1.015 | 1.087 |
| real-1536 | 0 | selective | 0.921 | 1.967 |
| real-1536 | 1 | all | 1.008 | 1.092 |
| real-1536 | 1 | independent | 0.991 | 1.051 |
| real-1536 | 2 | all | 0.950 | 1.073 |
| real-1536 | 2 | correlated | 0.980 | 1.014 |
| real-1536 | 2 | independent | 0.984 | 0.992 |
| real-1536 | 2 | selective | 0.902 | 1.346 |

## Full three-way resident gates

Fixed original corpora/seeds/K/filters/efs/warmups/service boundaries, all three trials and all samples. Serial order is before/after/Qdrant, Qdrant/after/before, before/after/Qdrant. Each Akasha variant is compared to the same Qdrant trial. Nothing overlaps a build, test or archive compression. No retuning, median-only verdict, tolerance or cross-cell compensation.

| Gate | Before | Candidate | Matched recall | Pass→fail |
|---|---:|---:|---|---|
| Warm | 19/36 | 18/36 | Both 36/36 | Real-all trials 1 and 2 |
| Mixed queries | 24/36 | 29/36 | Both 36/36 | None |
| Durable write+flush | 3/9 | 3/9 | — | None |

**All performance gates FAILED.** The measurement orchestrator exits 0 after completing all 54 workers; the independent assessment exits 1 for performance failure. Do not interpret worker completion as passing the gate.

Warm audits: 6,912 timed + 324 warmups + 7,236 exact checks + 27 first queries; 2,304 paired before/after query identities match. Mixed: 7,776 query audits, 27 reopen oracles and 18 Akasha leases; 2,592 paired query identities match. Both variants match all selected Recall@10 ≥ .95 cells.

Each following ratio is **Akasha/Qdrant QPS / p95**, followed by P/F using unrounded values. Higher QPS and lower p95 are better. Trial indices are zero-based.

### warm

| Corpus | Trial | Filter | Before ratios | Candidate ratios |
|---|---:|---|---|---|
| uniform-128 | 0 | all | 0.793 / 1.253 F | 0.762 / 1.492 F |
| uniform-128 | 0 | correlated | 2.371 / 0.671 P | 2.502 / 0.605 P |
| uniform-128 | 0 | independent | 3.352 / 0.283 P | 3.203 / 0.318 P |
| uniform-128 | 0 | selective | 1.241 / 0.680 P | 1.199 / 0.754 P |
| uniform-128 | 1 | all | 0.831 / 1.139 F | 0.820 / 1.182 F |
| uniform-128 | 1 | correlated | 2.713 / 0.384 P | 3.042 / 0.387 P |
| uniform-128 | 1 | independent | 1.930 / 0.794 P | 2.541 / 0.642 P |
| uniform-128 | 1 | selective | 0.976 / 1.363 F | 1.080 / 1.036 F |
| uniform-128 | 2 | all | 0.859 / 1.083 F | 0.881 / 1.106 F |
| uniform-128 | 2 | correlated | 2.767 / 0.555 P | 2.613 / 0.542 P |
| uniform-128 | 2 | independent | 3.101 / 0.370 P | 3.210 / 0.345 P |
| uniform-128 | 2 | selective | 1.111 / 1.016 F | 0.995 / 1.092 F |
| uniform-1536 | 0 | all | 2.584 / 0.381 P | 2.435 / 0.453 P |
| uniform-1536 | 0 | correlated | 1.587 / 0.725 P | 1.551 / 0.736 P |
| uniform-1536 | 0 | independent | 1.584 / 0.682 P | 1.599 / 0.676 P |
| uniform-1536 | 0 | selective | 0.947 / 1.078 F | 1.063 / 0.878 P |
| uniform-1536 | 1 | all | 2.591 / 0.386 P | 2.598 / 0.384 P |
| uniform-1536 | 1 | correlated | 1.554 / 0.705 P | 1.459 / 0.738 P |
| uniform-1536 | 1 | independent | 1.594 / 0.683 P | 1.591 / 0.676 P |
| uniform-1536 | 1 | selective | 0.894 / 1.148 F | 0.957 / 1.089 F |
| uniform-1536 | 2 | all | 2.570 / 0.411 P | 2.591 / 0.376 P |
| uniform-1536 | 2 | correlated | 1.553 / 0.730 P | 1.492 / 0.736 P |
| uniform-1536 | 2 | independent | 1.608 / 0.683 P | 1.571 / 0.685 P |
| uniform-1536 | 2 | selective | 0.896 / 1.316 F | 0.986 / 1.064 F |
| real-1536 | 0 | all | 1.077 / 1.038 F | 1.015 / 1.053 F |
| real-1536 | 0 | correlated | 0.883 / 1.056 F | 0.825 / 1.146 F |
| real-1536 | 0 | independent | 0.767 / 1.289 F | 0.762 / 1.286 F |
| real-1536 | 0 | selective | 0.959 / 1.014 F | 0.934 / 1.083 F |
| real-1536 | 1 | all | 1.082 / 0.958 P | 1.057 / 1.058 F |
| real-1536 | 1 | correlated | 0.889 / 0.996 F | 0.878 / 1.027 F |
| real-1536 | 1 | independent | 0.680 / 1.491 F | 0.774 / 1.275 F |
| real-1536 | 1 | selective | 0.948 / 0.967 F | 0.947 / 0.952 F |
| real-1536 | 2 | all | 1.055 / 1.000 P | 1.043 / 1.018 F |
| real-1536 | 2 | correlated | 0.837 / 1.079 F | 0.812 / 1.135 F |
| real-1536 | 2 | independent | 0.704 / 1.436 F | 0.639 / 1.742 F |
| real-1536 | 2 | selective | 1.194 / 0.603 P | 1.133 / 0.617 P |

### mixed

| Corpus | Trial | Filter | Before ratios | Candidate ratios |
|---|---:|---|---|---|
| uniform-128 | 0 | all | 1.519 / 0.602 P | 1.518 / 0.575 P |
| uniform-128 | 0 | correlated | 2.860 / 0.849 P | 2.685 / 0.732 P |
| uniform-128 | 0 | independent | 3.167 / 0.508 P | 3.037 / 0.529 P |
| uniform-128 | 0 | selective | 1.281 / 1.572 F | 1.222 / 2.387 F |
| uniform-128 | 1 | all | 1.854 / 0.431 P | 2.035 / 0.367 P |
| uniform-128 | 1 | correlated | 2.995 / 0.643 P | 3.882 / 0.322 P |
| uniform-128 | 1 | independent | 3.775 / 0.336 P | 3.976 / 0.362 P |
| uniform-128 | 1 | selective | 1.905 / 0.702 P | 2.089 / 0.550 P |
| uniform-128 | 2 | all | 1.852 / 0.412 P | 1.873 / 0.397 P |
| uniform-128 | 2 | correlated | 3.629 / 0.384 P | 3.582 / 0.365 P |
| uniform-128 | 2 | independent | 3.674 / 0.435 P | 3.587 / 0.462 P |
| uniform-128 | 2 | selective | 1.169 / 2.620 F | 1.416 / 2.123 F |
| uniform-1536 | 0 | all | 2.443 / 0.380 P | 2.357 / 0.422 P |
| uniform-1536 | 0 | correlated | 1.742 / 0.622 P | 1.672 / 0.629 P |
| uniform-1536 | 0 | independent | 1.831 / 0.611 P | 1.741 / 0.597 P |
| uniform-1536 | 0 | selective | 1.054 / 1.359 F | 0.976 / 1.759 F |
| uniform-1536 | 1 | all | 2.315 / 0.399 P | 2.355 / 0.404 P |
| uniform-1536 | 1 | correlated | 1.651 / 0.633 P | 1.692 / 0.644 P |
| uniform-1536 | 1 | independent | 1.697 / 0.618 P | 1.731 / 0.631 P |
| uniform-1536 | 1 | selective | 0.973 / 1.502 F | 1.090 / 0.838 P |
| uniform-1536 | 2 | all | 2.448 / 0.361 P | 2.496 / 0.349 P |
| uniform-1536 | 2 | correlated | 1.728 / 0.626 P | 1.809 / 0.568 P |
| uniform-1536 | 2 | independent | 1.770 / 0.614 P | 1.853 / 0.552 P |
| uniform-1536 | 2 | selective | 0.998 / 1.831 F | 1.052 / 1.652 F |
| real-1536 | 0 | all | 1.084 / 0.921 P | 1.089 / 0.933 P |
| real-1536 | 0 | correlated | 0.991 / 0.962 F | 1.004 / 0.961 P |
| real-1536 | 0 | independent | 0.660 / 1.525 F | 0.667 / 1.398 F |
| real-1536 | 0 | selective | 1.153 / 1.099 F | 1.229 / 0.905 P |
| real-1536 | 1 | all | 1.213 / 0.645 P | 1.191 / 0.752 P |
| real-1536 | 1 | correlated | 1.054 / 0.821 P | 1.102 / 0.703 P |
| real-1536 | 1 | independent | 0.719 / 1.087 F | 0.708 / 1.025 F |
| real-1536 | 1 | selective | 1.259 / 1.201 F | 1.221 / 0.746 P |
| real-1536 | 2 | all | 1.107 / 0.956 P | 1.128 / 0.873 P |
| real-1536 | 2 | correlated | 1.017 / 0.914 P | 1.008 / 0.929 P |
| real-1536 | 2 | independent | 0.671 / 1.461 F | 0.666 / 1.431 F |
| real-1536 | 2 | selective | 1.199 / 1.323 F | 1.222 / 0.958 P |

### Durable write+flush gate

| Corpus | Trial | Before QPS / p95 | Candidate QPS / p95 |
|---|---:|---|---|
| uniform-128 | 0 | 1.473 / 0.665 P | 1.983 / 0.490 P |
| uniform-128 | 1 | 1.537 / 0.625 P | 2.093 / 0.467 P |
| uniform-128 | 2 | 1.498 / 0.666 P | 2.029 / 0.500 P |
| uniform-1536 | 0 | 0.710 / 1.476 F | 0.813 / 1.212 F |
| uniform-1536 | 1 | 0.691 / 1.544 F | 0.797 / 1.288 F |
| uniform-1536 | 2 | 0.676 / 1.507 F | 0.780 / 1.281 F |
| real-1536 | 0 | 0.852 / 1.149 F | 0.987 / 1.015 F |
| real-1536 | 1 | 0.815 / 1.254 F | 0.964 / 1.019 F |
| real-1536 | 2 | 0.828 / 1.222 F | 0.953 / 1.097 F |

## Unresolved initial baseline stall

The first A/B attempt stopped in unchanged **before** binary, before any candidate worker ran. It produced no completed report, used approximately zero CPU while stuck, and was terminated with SIGTERM after 124.97 s. Its database, input hashes, empty worker log, exit record and one-second native stack remain. Both foreground and background maintenance threads were inside BlockingScopedLock; the optimized stack does not identify the lock or exact originating operation. The last durable delta filename was sequence 9424. This is an unresolved failure, not a discarded slow latency or a demonstrated candidate bug.

Three separately instrumented baseline repeats and ten repeats with only a traceback watchdog completed. The subsequent 18-worker A/B and 54-worker three-way cohorts also completed. These successes **do not explain or fix** the original stall. No locking code was changed. Further stress/reproduction and lock ownership diagnosis are required before completion.

## Evidence and reproduction

[Immutable archive](results/2026-10-04-payload-buffer.json.gz), SHA-256 `904472d6e763cd6c2c0dc07f55f4b991bb1e1ca827cbb0b90af59d297766454f` (7,471,883 bytes; 632 text entries). All archived text hashes were checked after decompression. It contains original profiles, isolated before/after sources and tests, compiler/pytest/crash/C/example logs, all raw measurement cohorts, failed initial attempts, and diagnostic repeats; no databases/binaries. The live stalled database remains in `.build/2026-10-04-payload-buffer/paired/uniform-128-0-before/database`.

Local evidence root: `.build/2026-10-04-payload-buffer`. Recheck the completed matrix with:

```sh
rtk proxy pixi run python .build/2026-10-04-payload-buffer/assess.py
```

Expected exit is **1**. Timing drivers create fresh directories and must not be rerun in place. Recover archived drivers into a new directory, keep the pinned corpora/templates and package identities, and use the saved exact commands/environments. `python-tests.py` provides the required source-remapping and Metal-wrapper setup. Saved-package pytest must retain `-o pythonpath=`.

No HTTP candidate measurement, sustained nonresident/memory-limit, Linux, GPU or ASan result is claimed. The [unchanged production gate](2026-10-04-current-parity.md) remains warm 22/36, mixed 25/36, HTTP 18/108 and durable write+flush 3/9 in its own experiment. Candidate/historical counts are not substituted or combined.
