# Named HNSW reuse across immutable runs

Named HNSW now belongs to an immutable `ReadRun`, so a new snapshot reuses the
unchanged base graph and builds only new runs. This removes whole-collection graph
rebuilding after small updates. It is a partial M5 lifecycle improvement; M5/M6
remains incomplete. First use after open/reopen still builds a graph, and several
warm query cases regress. The original strict Qdrant matrix is not redefined or
declared passed by this diagnostic.

Baseline source: `cc1e482` (engine `a57f11a`), Python binary `b183b880…`.
Final Python binary SHA-256:
`7db8a2d6b20436c5efdc71dd92565d58c4037448c32fbd7bfbee6a81c19910a6`.
Timing measurements below use the preceding slot-admission binary `2d7506f89430a5014232e175b055d36ae05952501293d0e2e63f0a57510ff64f`.
Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4. All builds, tests and benchmarks ran
serially. The native maintenance worker stayed at `bc064bc8…`.

## Implementation and correctness

The run owns the existing locked artifact state. Rows use run-local ordinals;
authority scalar and exact HNSW configuration are checked before reuse. Root
visibility and payload filters exclude overwritten, deleted and absent-field
rows before candidate admission. Per-run candidates merge into one bounded F32
candidate set, then the captured root supplies native authority for F64 reranking.
`rerank_k` remains a global upper bound. Query controls, retry after failed builds,
concurrent first-query locking and old-snapshot ownership remain in effect.

The final implementation reuses `HnswSearchAdmission`: graph construction checks
every append's public ID against its row/slot, then queries use owned slot flags.
No query/candidate numeric validation is removed. A separate comparison against
the ID-admission implementation reproduced all **4,824 paired samples' IDs,
F64 score bits and traversal counters**. That experiment retained its two selected
cells with a QPS or p95 regression; its timing ratios are not multiplied into the
final comparison below.

The original reuse assertion failed on the baseline. New regressions cover
payload changes, replacement/removal, deletion/reinsert, missing fields, bounded
global reranking, sealed-run merging, retained old snapshots after close, changed
configuration rejection, and a failed new head build leaving the base ready.
Durable bytes, public signatures and other field artifacts are unchanged.

Validation: the initial run-owner implementation passed **76 targeted Mojo**
tests. After the slot adapter change, **22 targeted Mojo / 358 complete Python**
tests, C ABI/client and three examples passed. These are distinct validation
stages, not a new full Mojo/crash run. Slot-version promotion reruns passed:
5 named Mojo tests, 59 named Python tests and the C client.

Final review found that the new merge heap reserved the full requested budget
even on a tiny/empty root. It now caps allocation at the visible population
(with a one-entry empty placeholder). A regression exercises UInt32.MAX ef and
rerank budgets on empty/tiny filtered and unfiltered views. This final change
passed **8 targeted Mojo / 358 complete Python / C ABI/client / three examples**;
the promoted final package also passed 59 named Python tests and the C client.
No timing run was repeated for this allocation bound. All measured corpus sizes
exceed their candidate budgets, so their heap capacity is unchanged; the numbers
below remain evidence for the measured binary, not a new final-binary gate.

## Measured lifecycle cost

The first diagnostic imports 2,048 final-state points from each frozen corpus,
uses query ordinal 3, K=10 and ef=512, and keeps an old snapshot through updates.
Each phase's approximate result has 10/10 exact matches and equal native scores.
Times are individual samples, not p95 or repeated-trial estimates.

| Corpus | Payload-only update: before → final | One-vector update: before → final |
|---|---:|---:|
| Uniform 128D | 1,415.052 → 0.583 ms | 1,411.479 → 0.599 ms |
| Uniform 1536D | 4,646.421 → 2.011 ms | 4,733.258 → 1.915 ms |
| Real 1536D cosine | 3,010.061 → 1.983 ms | 3,001.190 → 1.955 ms |

The base build count stays at one. Each one-row head adds its own one-row graph;
the old snapshot retains its original graph. Final reopened first-query times
remain **1.479 / 4.937 / 3.120 s**. Initial build and unchanged-root warm samples,
including slower samples, remain in the raw logs.

## Full fixed named-field curve diagnostic

The final direct comparison uses production and the measured slot candidate binaries on
the complete frozen 8,192-point input streams, original replacements/deletes,
three datasets, four filters, K=10, six original ef values and all 64 queries plus
three warmups per cell. This is one paired diagnostic trial through named-field
Python calls, not the existing three-trial default-field Qdrant performance gate.

All **1,608 exact oracle checks / 9,648 ANN sample audits** pass live-ID, filter
and native-score checks (9,216 timed samples). Both variants reach mean Recall@10
≥ .95 in all 12 dataset/filter combinations. All 144 curve cells remain, including
**28 baseline / 25 candidate** below-target cells. Per-run topology changes recall;
128D independent requires ef=256 instead of 128. No failing cell or slow sample is
removed. The earlier run-owner and slot-admission experiments are also retained
separately, not combined into repeated final trials.

With the original full update/delete stream, updated-root first-query time is:

| Corpus | Before | Final |
|---|---:|---:|
| Uniform 128D | 6.874 s | 0.536 s |
| Uniform 1536D | 33.082 s | 1.124 s |
| Real 1536D cosine | 17.346 s | 0.916 s |

Warm timing below selects the smallest tested ef reaching .95 in each variant.
Ratios are final/baseline: higher QPS and lower p95 are better.

| Corpus | Filter | ef before → final | QPS ratio | p95 ratio |
|---|---|---:|---:|---:|
| Uniform 128D | all | 128 → 128 | 0.668 | 1.451 |
| Uniform 128D | correlated | 256 → 128 | 1.244 | 0.865 |
| Uniform 128D | independent | 128 → 256 | 0.536 | 2.026 |
| Uniform 128D | selective | 128 → 128 | 0.884 | 1.198 |
| Uniform 1536D | all | 512 → 512 | 0.843 | 1.170 |
| Uniform 1536D | correlated | 512 → 512 | 0.868 | 1.157 |
| Uniform 1536D | independent | 512 → 512 | 0.902 | 1.053 |
| Uniform 1536D | selective | 256 → 256 | 0.946 | 1.072 |
| Real 1536D | all | 32 → 32 | 0.814 | 1.217 |
| Real 1536D | correlated | 64 → 32 | 0.997 | 1.017 |
| Real 1536D | independent | 64 → 32 | 1.080 | 0.945 |
| Real 1536D | selective | 128 → 64 | 1.826 | 0.690 |

The lifecycle fix does not establish warm-query parity. Small-run graph building,
extra per-run query work, first-open/reopen artifacts, concurrent clients and the
original complete Qdrant gate remain work to do. Sustained nonresident/controlled
memory validation still has no available native Linux runner.

## Evidence and reproduction

[Final allocation-bound evidence](results/2026-10-03-named-run-bound.json.gz):
19,272 bytes, 30 files, SHA-256
`99ba7da9d2305e80fec6de02e2bd98acf036116308c763d3a35881e884eaa2bf`.
This addendum preserves the already-frozen measurement archive below.

[Frozen archive](results/2026-10-03-named-run-hnsw.json.gz): 4,823,585 bytes, 184 text files, SHA-256
`6115ca3fc12be54c10044c6148dd1f0b453a5eaaff99105dc08ad2531fee2899`.
Decoded file hashes were verified. It contains the baseline,
initial and final diagnostic drivers, all samples/curves, failed development
attempts, source variants, compiler wrapper, test logs, binary hashes and input
hashes. The workload NPZ files retain their existing frozen hashes; no source or
old archive was overwritten. `named-root-cost/export.py` reproduces the small
probe inputs into a new directory. Use a new output directory for each driver;
existing database/report paths deliberately refuse reuse.

```sh
rtk proxy pixi run mojo --version
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_named_hnsw.mojo
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD" OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 python NEW_OUTPUT/named-quality.py
```

For isolated builds, use both the copied include tree and its copied
`bindings/python_module.mojo` entry. Saved-package pytest uses `-o pythonpath=`
and the archived child-compiler wrapper. All timing phases must remain serial
with respect to builds, tests and archive compression.
