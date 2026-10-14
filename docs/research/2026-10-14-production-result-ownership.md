# Production Python result ownership fix — 2026-10-14

Adopted as a correctness fix: discarded Python search results now release their
rows and nested batch lists. Only four blocks of `bindings/python_module.mojo`
change; storage/query algorithms, C source, formats and Python return shapes are
unchanged. This fixes a demonstrated leak, **not M5/M6 performance acceptance**.
The separate mapped-storage candidate remains unadopted and its capacity results
are not inherited by this production port.

## Implementation and verification

The [isolated investigation](2026-10-14-python-result-ownership.md) proves that
Mojo 1.0.0 dynamic Python append keeps an extra strong reference per positional
argument. The production binding source is identical to that investigation's
parent, and production also fails all ten weak-reference lifetime cases. Build
owned `List[PythonObject]` rows/batches and return public `Python.list(Span(...))`
instead. No manual reference-count manipulation or dependency change is needed.

Ten new cases cover exact/approximate queries for all three dense metrics, ordinary
and filtered batches, named search and field fusion. All ten fail on the old
production binary and pass on the new Mac and Linux builds. The complete existing
Python suite passes **359 tests**, for **369 distinct Python cases** on the Mac.
All 15 child compiler invocations are audited: 14 use the isolated project source;
one target-contract probe imports only stdlib and has no project include.

After installing the exact tested Mac binary, all ten new cases pass again through
the root package. Every root Mojo source hash matches the tested candidate. Core
engine and C source are unchanged, so applicable prior core/C/crash validation is
reused; no new full Mojo, GPU or native Linux performance claim is made.

The direct 256-call allocation probe falls from about 0.85 MiB retained per
exact/approximate batch to 696/664 bytes, comparable to configuration/statistics
snapshot overhead. Row reference counts return from three to two. The no-engine
reproducer and upstream source evidence remain in the linked investigation archive.
These probes demonstrate ownership, not a speed gate or every Python interop path.

| Artifact | SHA-256 |
|---|---|
| Mac/root Python | `96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c` |
| Linux Python | `acdce914d071b9c8773ff3c928d83b4adbb2b2a2c9bccf1067bc66f0606d4e0d` |
| Unchanged root C | `1b818195c0918043f0bb986db3b1c9de93d21e36544b90bb42d0ff058be8dce5` |

The old `45b24374…` Python binary remains in the frozen `live-radius-python`
package. The new binary is installed atomically only after all measurement workers
finish. Future production comparisons should use the new immutable
`.build/m5-resume/production-python-results/python` package as baseline.

## Complete native performance decision

All 54 Mac workers complete, with nine rotating production-before/after/Qdrant
triples per phase, unchanged fixtures, queries, oracle, efs, timing and strict
Recall@10 >= .95, QPS >= Qdrant and p95 <= Qdrant criteria. IDs, Float32 score bits,
statistics and execution match. Reopen and Arrow lease checks pass.

| Phase | Quality before/after | Speed before/after | Pass to fail | Fail to pass |
|---|---|---|---:|---:|
| Warm | 36/36 each | 23/36 → 25/36 | 2 | 4 |
| Mixed | 36/36 each | 27/36 → 24/36 | 4 | 1 |

Write plus flush remains 3/9 for both. Mixed exit 1 is the failed strict gate,
not a worker failure. Every regression is retained; gains cannot offset it:

| Phase | Transition | Corpus | Trial | Mode |
|---|---|---|---:|---|
| warm | FAILED → PASSED | uniform-128 | 0 | selective |
| warm | FAILED → PASSED | uniform-128 | 1 | all |
| warm | FAILED → PASSED | uniform-1536 | 1 | selective |
| warm | FAILED → PASSED | real-1536 | 0 | selective |
| warm | PASSED → FAILED | real-1536 | 1 | all |
| warm | PASSED → FAILED | real-1536 | 2 | all |
| mixed | FAILED → PASSED | uniform-128 | 1 | all |
| mixed | PASSED → FAILED | uniform-128 | 1 | selective |
| mixed | PASSED → FAILED | uniform-128 | 2 | selective |
| mixed | PASSED → FAILED | uniform-1536 | 1 | selective |
| mixed | PASSED → FAILED | real-1536 | 1 | selective |

The correctness fix is adopted to release caller-discarded allocations. It is not
classified as a performance success: mixed speed declines and six previously
passing cells across both phases now fail. Real-1536 warm trial 1 all-query QPS is
0.928 of its paired old version and p95 is 1.092; trial 2 misses Qdrant p95 by
about 0.6% and is still failed. No tolerance or sample exclusion is applied.

## Evidence and remaining work

[Complete source, validation and raw comparisons](2026-10-14-production-result-ownership.json.gz): 902 files, 4,139,766 bytes, SHA-256
`02a8bad0267d3d87d1ddfcd43e84e98cbdfaf54a4e4870fd89e79fd92e052e7f`. Every embedded hash was verified after decompression. The archive includes both platform source/package snapshots, expected failures, child compiler records, allocation probe, all 54 native workers and root source/binary adoption checks. Binaries and copied databases are not embedded.

Production now consists of the `6d01819` storage/query engine plus this standalone
binding fix. Remaining per-cell warm/mixed speed failures, mapped-reader and
maintenance costs, full capacity adoption and native Linux performance gates are
still open. M5/M6 remain unfinished. The next optimization must use this corrected
production baseline and retain all existing failed samples.
