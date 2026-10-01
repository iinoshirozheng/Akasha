# Symmetric refined ef curves

The prior real-data curve used ef32/64 around a narrow recall crossing. This
diagnostic gives **both engines** the same prespecified grid:
10, 16, 24, 32, 40, 48, 64, 96, 128, 256, 512, 1024. Every other configuration,
closed database, query, oracle and seed remains the established baseline.
No engine default or planner policy changed. This is parameter measurement,
not a before/after implementation speedup.

Three serial, alternating engine-order pairs per corpus use public Python APIs,
pinned Qdrant Edge 0.8.0 and the current Akasha build. Every worker checks its
loaded native binary hash. No build, test or archive compression overlaps timing.
Exact API checks precede each mode; exact requests do not alternate with timed
ANN requests. Three warmups precede 64 measured queries per cell.

There are **864 cells, 55,296 timed query audits, 4,824 exact oracle checks and
2,592 retained warmups**. All 36 selected comparisons pass Recall@10 >= .95.
The **363 failed-recall cells remain in the archive**. Selection uses the lowest
passing ef on the grid, never the most favorable timing sample.

| Corpus | All QPS A/Q | Correlated | Independent | Selective |
|---|---:|---:|---:|---:|
| Uniform 128D | .714 (.697–.783) | 2.176 (1.881–2.477) | 2.430 (2.205–2.732) | .997 (.871–1.320) |
| Uniform 1536D | 1.761 (1.681–1.863) | 1.214 (1.206–1.237) | 1.156 (1.152–1.166) | .801 (.791–.890) |
| Real 1536D | .844 (.821–.852) | .675 (.639–.735) | .573 (.568–.613) | .698 (.646–.708) |

Values are median and full three-trial range. Selected Akasha/Qdrant ef:

| Corpus | All | Correlated | Independent | Selective |
|---|---:|---:|---:|---:|
| Uniform 128D | 128/96 | 32/256 | 32/256 | 10/10 |
| Uniform 1536D | 512/512 | 128/512 | 128/512 | 10/10 |
| Real 1536D | 16/24 | 32/128 | 40/128 | 10/10 |

Real-data achieved recall is .967188/.953125/.965625/1 for Akasha and
.953125/.967188/.9625/1 for Qdrant respectively. Akasha real independent ef32
still fails at .946875; ef40 passes. Correlated ef24 fails at .940625. Uniform
Akasha selected cells use planned exact scans with recall 1; Qdrant exposes no
fallback counters, so its execution stays marked unobservable. The new grid
also finds Qdrant uniform-128 all/ef96 exactly at .95, changing that comparison
relative to the previous coarse curve. Prior and new ratios are not a paired
engine-change experiment.

The real-data query gap persists after parameter refinement. These results do
not establish whole-matrix parity or better write/flush behavior. Original cloned
databases lack the optional overlay cache, so initial opens include delta
reconstruction; they must not replace cached-reopen measurements. OS cache is
present, with no eviction or enforced memory limit: cold/non-resident gates
remain unverified. Full latency/recall curves and slow samples are retained.

[Full source, driver, jobs, logs and raw results](results/2026-10-02-refined-ef-warm.json.gz)
(3,284,317 bytes; SHA-256
`57ef83273b96c0a6866f8ea516d71cce626881369da6dcb43454865023e2259f`).
