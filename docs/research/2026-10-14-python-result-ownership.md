# Python query results release their rows

This isolated candidate fixes one leaked strong reference per search-result row,
and per nested list in batch search, under the project compiler Mojo 1.0.0.
The defect reproduces in both production and the mapped typed-compaction parent.
The ten new lifetime cases all fail on the parent and pass after the fix; full
Python regression is 359 passed. The same ten lifetime cases pass on Linux.
This correctness result does not imply that all M5/M6 speed gates pass.

## Mechanism and validation

A minimal extension with no Akasha import constructs identical dictionaries by
(a) dynamic PythonObject.append and (b) a typed Mojo List[PythonObject] converted
with public Python.list(Span). CPython reports one excess reference per row only
for (a). After 256 ten-row calls, (a) retains 901,558 traced bytes and (b) retains
zero in the minimal test. Production exact/approx queries retain about 0.85 MiB;
fixed queries retain 696/664 bytes, comparable with configuration/statistics
snapshot bookkeeping. These are allocation diagnostics, not timing gates.

The pinned Mojo 1.0.0 PythonObject.__call__ implementation creates a reference via
steal_data on a borrowed positional argument, then increments it again with
Py_NewRef before the tuple takes ownership. Cleanup releases only one reference.
The public Python.list(Span) constructor transfers one reference directly.
[Upstream source](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/python/python_object.mojo)
and [list construction](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/python/python.mojo)
are retained with content hashes beside the reproducer. Installed dependencies
and stdlib are not edited.

Only four blocks of bindings/python_module.mojo change: the ordinary and named
result builders, and unfiltered/filtered batch result wrappers. They build typed
temporary lists and convert at the return boundary. Returned Python list/dict
shapes, primitive ID/score conversion, order, execution and column paths remain
the same. The tests attach a weakly referenced sentinel to a returned row, discard
the result, and require its release while the collection remains open. This
checks actual reachability, including nested batch owners, rather than only RSS.

The initial filtered test fixture omitted its required kind; that failed attempt
is retained. Once corrected, all ten parent cases fail on retained sentinels.
The child compiler audit retains one stdlib-only target probe, which has no
project include; all 14 project-dependent invocations use the isolated source.
Core engine/C sources are byte-identical to the prior typed-compaction candidate;
its applicable Mojo/crash/C evidence is reused rather than rerun. No new GPU gate.

Mac Python SHA-256: f500e869935d33082861632d1672e1a12af814a09565239ec507e568eb500b62.
Linux Python SHA-256: 985c8b992c7caf94043ba79426731ab1674e0f56e0039e5424fde818b7e84ee0.
Production engine and binaries have not been replaced.

## Full-query memory diagnostic

Same frozen uniform-1536 data, query inputs, end-only worker, one CPU, 6 GiB limit,
no swap and depth-one tracemalloc. Both workers complete 536 exact/approx preflight
checks and 2,048 timed response audits. Preflight IDs, Float32 bits, traversal
statistics and execution are identical. Only the engine binary changes.

| Post-preflight increase | Parent bytes | Candidate bytes |
|---|---:|---:|
| Anonymous RSS | 27,303,936 | 1,478,656 |
| Traced current | 7,623,046 | 690,283 |
| Traced peak | 4,702,776 | 0 |

The residual tracked memory includes the complete report held by the worker.
This does not prove that all other Python interop paths are free of leaks.
A zero peak increase means the earlier input/preflight high-water mark was not
exceeded, not that the query loop allocated nothing. Tracemalloc affects RSS/timing;
this diagnostic is not capacity acceptance.

## Complete constrained-memory matrix

The unchanged worker, queries, efs, modes, oracles, caps, one CPU, swap prohibition,
worker timeout and alternating orders from the [previous matrix](2026-10-14-typed-live-capacity.md)
are retained. This complete new batch has 60/60 workers finished, zero OOMs and
zero timeouts. It is QEMU on the Mac, not native Linux performance certification.
All 60 preflights match the previous batch's IDs, Float32 score bits, execution and
statistics. There are 16,080 exact checks, 16,080 approximate preflight audits and
122,880 timed response audits.

| Corpus | Cap MiB | Quality /12 | Strict speed /12 | Paired pressure /12 |
|---|---:|---:|---:|---:|
| Uniform 128D | 128 | 12 | 6 | 0 |
| Uniform 128D | 192 | 12 | 6 | 0 |
| Uniform 128D | 256 | 12 | 7 | 0 |
| Uniform 1536D | 128 | 12 | 11 | 12 |
| Uniform 1536D | 192 | 12 | 12 | 0 |
| Uniform 1536D | 256 | 12 | 12 | 0 |
| Real 1536D | 128 | 12 | 0 | 12 |
| Real 1536D | 192 | 12 | 9 | 7 |
| Real 1536D | 256 | 12 | 2 | 0 |
| **Total** | | **108/108** | **65/108** | **31/108** |

All 54 limited workers finish, including the three locations that previously
OOM-killed Akasha. Quality remains Recall@10 >= .95 and valid execution; speed
requires both QPS >= Qdrant and p95 <= Qdrant without tolerance. Only 18 of the
31 paired-pressure cells also pass speed. Individual pressure cells are 33 Akasha
and 49 Qdrant. The 6 GiB controls pass 12/12 quality and 2/12 speed, without paired
pressure; their one pair per corpus is not repeated performance acceptance.

The role-aware pressure classifier and negative controls are byte-identical to
the prior validated versions, whose checks are reused. Exact requires authority;
ANN requires visited HNSW plus authority when reranking or scanning delta. Each
last-four pass must have positive process major faults and relevant whole-file
weighted residency below .95. Whole-file metadata and process-wide rather than
file-attributed faults remain limitations. Small resident cells are not relabeled
nonresident. These legacy fixtures do not certify typed-maintenance capacity.

All Qdrant slow trials remain, including uniform-1536/192 MiB trial 2 at about
395 seconds and the 256 MiB trials around 253–268 seconds. Their preflight/results
are unchanged, but their fault/residency histories differ substantially from
other trials. The archive records those observations without claiming a cause.
The change from earlier aggregate speed totals is not a causal A/B speed gain.
Uniform-1536/128 MiB trial 1 selective QPS narrowly misses (78.0 versus 78.6),
and remains a failure. Real-1536/128 MiB fails speed in all 12 cells.

## Native Mac warm and mixed comparisons

Each phase includes all 27 serial workers, three rotating production/candidate/
Qdrant triples for each unchanged corpus. Results, Float32 score bits, statistics
and execution match between Akasha versions. All 36 cells in each phase pass
quality, but the candidate is **not adopted**:

| Phase | Production speed /36 | Mapped candidate speed /36 | Pass to fail | Fail to pass |
|---|---:|---:|---:|---:|
| Warm after reopen | 23 | 20 | 3 | 0 |
| Mixed read/write/maintenance | 25 | 25 | 4 | 4 |

Write plus flush is 4/9 for both. Mixed exit 1 is its failed strict speed gate;
all workers complete and reopen/Arrow lease checks pass. These comparisons include
the candidate's mapped engine changes, so they do not isolate the Python fix from
storage changes. Every transition and raw sample is retained. The binding file
is identical in the production and mapped parents, enabling a separate production-
only correctness fix without adopting the mapped storage regressions.

## Evidence and remaining work

[Complete sources, tests, traces and matrices](2026-10-14-python-result-ownership.json.gz):
1,288 files, 9,591,951 bytes, SHA-256
`d4d4b9c7be03958700f198a2ceca800cd168ed641044e35a6083183dad56d57c`.
Every embedded hash is checked after decompression. The archive includes both
platform source/package snapshots, the no-engine reproducer, pinned upstream
sources, expected failures, original and serial-repeat ownership probes, child
compiler commands, memory traces and all 114 new capacity/warm/mixed workers.
Prior fixture inputs and unchanged engine lifecycle evidence remain in the linked
parent archives. Binaries and copied databases are identified, not embedded.

The first green test invocation had reported all passes before its wrapper was
reaped when a small allocation probe started. Both are repeated serially and
retained; no accepted timing run overlaps builds/tests/profiling/compression.

Next independently validate the production-only result fix. The full mapped
candidate, remaining real-cosine/filtered-delta costs, strict per-cell speed gates
and native Linux performance requirements remain unresolved. M5/M6 are not done.
