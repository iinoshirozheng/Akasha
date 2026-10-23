# Keep inactive nodes out of the filtered HNSW traversal radius

Adopted as a **search correctness fix**. Filtered search previously let deleted
or replaced slots consume the retained navigation radius; unfiltered search did
not. At ef=1, an all-true filter could therefore stop early or return no result
although the unfiltered search reached a live nearest neighbor. Three independent
deleted-entry/deleted-middle/replaced-middle regressions demonstrate the defect.

Only `src/akasha/index/hnsw_core.mojo` changes engine behavior: current slots may
enter the filtered navigation heap, while inactive slots remain traversable.
Current nodes rejected by metadata still contribute to that heap. Query vectors,
distance arithmetic, validation, configured ef, heap tie-breaking, cancellation,
result admission and serialization contracts remain intact. Regression tests are
in `tests/mojo/test_hnsw_live_radius.mojo`.

The fix was separated from the larger unadopted
[named-cache reconciliation candidate](2026-10-04-named-cache-reconcile.md).
That work's byte-identical-graph cohort improved fixed recall passes 129→135/216,
with six fail→pass and none pass→fail, and removed all three quality regressions
against the original rebuilt graph. It still had 20/36 selected timing regressions;
no cache reconciliation code is included in this adopted patch.

## Validation and exact scope

Baseline tests fail all three assertions after correcting an initial test-only
Float64/Float32 conditional-literal compile error. The isolated one-file fix passes
**119 unique targeted Mojo, 388 full Python, C ABI/client and three rebuilt examples**.
The targeted suite covers core layer search, filtered/widening paths, counters,
group order, mutations, quantized/owned/mapped access, invariants, segmented and
named search/cache behavior. The complete Python run uses the copied package with
`-o pythonpath=`, kernel path/hash guards and child compiler wrapper propagation.

Promotion copies the identical validated binary and checks all source hashes.
Production checks pass the same three Mojo regressions, **8 server tests**, C client
and all three examples. These repeat checks are not added to the 119/388 counts.
The native maintenance worker remains unchanged and was never overwritten during
tests. There is no new full Mojo, crash, distributed, HTTP performance, Linux,
GPU, ASan or sustained-nonresident/memory-limit run. Prior full-suite evidence
continues to describe its earlier source/binary, not this one.

Current artifacts:

| Artifact | SHA-256 |
| --- | --- |
| Python `_kernel.so` | `609aeb2b0d721cbc1d84f6aec1bd325a360484cfa72d207600313b342c5cd8d9` |
| C ABI library | `2da670ff6b2db10fba287507df0f288f34eef04941f3d11598f937a01aaf1326` |
| C client | `fc7c60215c287126f6e9ebe04d4bf90012a834d897434667fc0f54eb97ebbc12` |
| Native worker (unchanged) | `bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6` |

Compiler: Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4 via the existing wrapper.
The baseline kernel is `53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6`.

## Fixed default warm/mixed gates: FAILED

All **54 serial workers** completed, with original corpora/seeds/filters/K/efs,
service boundaries and three trials. Before/after/Qdrant use fresh cloned original
fixtures, ordered B/A/Q, Q/A/B, B/A/Q. No builds/tests/compression overlap the
benchmarks. All trials and slow samples are retained.

| Gate | Baseline | Fix |
| --- | ---: | ---: |
| Warm matched recall ≥ .95 | 36/36 | 36/36 |
| Warm QPS and p95 strict parity | 19/36 | 22/36 |
| Mixed matched recall ≥ .95 | 36/36 | 36/36 |
| Mixed QPS and p95 strict parity | 19/36 | 19/36 |
| Mixed durable write+flush parity | 3/9 | 3/9 |

Two strict performance pass→fail cells remain: warm real-1536/trial 1/all, and
mixed uniform-128/trial 2/correlated. There are also **21/36 warm and 25/36 mixed
A/B cells** with lower QPS or higher p95, even when parity status is unchanged.
No aggregate gain offsets any failed cell. This correctness adoption does not
constitute performance acceptance: **M5/M6 remain unfinished**.

Warm: 7,236 three-engine result audits and 7,236 exact oracle checks; all 2,412
A/B queries have identical IDs, F32 bits and stats (24,120 score-bit checks).
Mixed: 7,776 three-engine query audits; all 2,592 A/B ID lists and their F32 bits
agree (25,920 comparisons); 2,472 stats agree and 120 differ. All mixed workers
pass reopen oracles and 32 writes/flushes; both Akasha variants preserve Arrow
leases after close. Result equivalence does not turn failed timing into a pass.

The first matrix launch failed before starting any worker because an adapted
harness retained the old `folded_binary_sha256` key. Its source/error record and
unused output directory remain intact. The corrected driver uses a new
`matrix-retry` directory; the complete performance assessment correctly exits 1.

## Evidence and reproduction

[Immutable text archive](results/2026-10-04-live-filtered-radius.json.gz):
655 entries, 4,425,168 bytes; SHA-256
`77ae0191f6ebbe08689c184c9f6cc0aa5686480ca0f102e98a5bb29f159c53ce`.
Gzip readback and every embedded file hash were checked. It includes both source
and Python package trees, tests, commands/logs, exact binary/source identities,
all 54 worker reports/samples, the initial harness error and promotion checks.
The prior cache archive contains the complete named fixed-graph diagnostic;
its summary and baseline regression failures are also included here.

Temporary workspace: `.build/2026-10-04-live-filtered-radius`. `validate.py` builds
from copied `after-src/bindings/python_module.mojo`; `python-tests.py` tests the
isolated package; `postvalidate.py` builds C/examples; `matrix.py` runs the fixed
cohort; `promotion-check.py` verifies production paths. Read these before copying
them to new outputs: writing drivers refuse existing artifacts.

Read-only reassessment (exit 1 is the retained performance failure):

```sh
rtk proxy python3 .build/2026-10-04-live-filtered-radius/summarize.py
```

For the new production regression test, preserve the Metal wrapper PATH:

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_hnsw_live_radius.mojo
```

Next work remains the named multi-run/update lifecycle performance decision,
initial build cost, and the original M6 performance/residency/maintenance matrix.
The lack of a native Linux runner is unchanged; no unrun gate is claimed.
