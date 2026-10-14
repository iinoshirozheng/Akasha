# Typed live compaction: constrained-memory matrix

The frozen typed live-compaction source now builds on Linux and completes a full
60-worker matrix. Of 54 constrained workers, 51 complete and three Akasha workers
are OOM-killed late in sustained queries. Strict speed passes 42/108 comparison
cells. Twelve cells have paired sustained-pressure evidence; six also pass speed.
This is **not M5/M6 acceptance** and the candidate remains unadopted.

## Identity and scope

The source is identical to the [typed live-compaction implementation](2026-10-14-mapped-typed-compaction.md).
Eight new lifecycle tests pass under Linux Mojo 1.0.0 (`ed45d567`). Linux Python
binary SHA-256 is `375e843c24a076d5b09b3d9e9eeaaece13796a26b95713d374b1c8ea9cd73f3b`;
Qdrant is `492083fe580ab36dc91899bb2d401dbc3a86d0d3c60989a843f3bc9318f14ecc`.
Workers use pinned image `sha256:540414f50b96439a6ba1475b79b2e2dd2208e86ebef33e2fbf2a176a8f037d31`.
The x86-64 runtime is QEMU on an ARM Mac, not native Linux performance certification.
The fixtures are legacy collections; this matrix does not certify typed-maintenance
capacity or the previously failing warm/mixed performance gates.

Production engine remains `6d01819`. Root Python/C binaries were not replaced.

## Fixed protocol and results

Three existing 8,192-point corpora (uniform 128D, uniform 1536D, real 1536D), the
same seed, k, 10% updates, queries and exact oracle are retained. Each worker runs
three warm plus 64 measured queries per mode, four modes and eight sustained
passes. Both engines have one CPU, no swap and the same 128/192/256 MiB limit;
three alternating pairs run per corpus/cap. A 6 GiB control pair runs per corpus.
Every worker uses fresh fixture inodes with one pre-open eviction, without
in-query eviction. All 60 workers run serially; none times out.

| Corpus | Cap MiB | Quality /12 | Strict speed /12 | Paired pressure /12 |
|---|---:|---:|---:|---:|
| Uniform 128D | 128 | 12 | 4 | 0 |
| Uniform 128D | 192 | 12 | 4 | 0 |
| Uniform 128D | 256 | 12 | 6 | 0 |
| Uniform 1536D | 128 | 4 | 4 | 4 |
| Uniform 1536D | 192 | 12 | 11 | 0 |
| Uniform 1536D | 256 | 12 | 4 | 0 |
| Real 1536D | 128 | 8 | 2 | 8 |
| Real 1536D | 192 | 12 | 3 | 0 |
| Real 1536D | 256 | 12 | 4 | 0 |
| **Total** | | **96/108** | **42/108** | **12/108** |

Quality requires Recall@10 >= 0.95 and valid execution. Speed requires both
Akasha QPS >= Qdrant and Akasha p95 <= Qdrant, without tolerance or offsetting.
All 204 quality cells belonging to completed constrained workers pass; the
12 missing paired comparisons belong to three OOMs and stay failures. Controls
complete 6/6 workers, quality 12/12 and speed 2/12, without paired pressure.
These one-pair controls do not replace repeated performance gates.

All 60 preflights, including OOM workers, match their engine's control IDs,
Float32 score bits, planner execution and statistics. The archive retains
16,080 exact checks, 16,080 approximate preflight audits and 122,560 persisted
timed response audits, including partial OOM work. All slow Qdrant trials remain
in the matrix. Totals from different historical batches are not an A/B delta.

## Pressure and OOM evidence

The pressure classifier observes query input roles separately. Planned exact
queries require authoritative segments; ANN requires visited HNSW files and,
when reranking or scanning a delta, authoritative segments too. Qdrant observes
its vector matrices. Each of the final four passes must have positive process
major faults and relevant byte-weighted file residency below 0.95. Missing input
roles or invalid execution cannot qualify. Negative controls verify that an
evicted HNSW file cannot qualify a fully resident exact authority.

Akasha qualifies 21 individual cells, Qdrant 27 and both qualify 12 paired cells.
Only six of those 12 also pass speed. `mincore` covers whole files, including
record metadata; faults are process-wide rather than attributed to a specific
file. These limits remain part of the evidence, not an engine allocation census.

The three OOMs are uniform-1536/128 MiB trials 0 and 1, and real-1536/128 MiB trial 2.
All pass open and preflight; all reach selective pass 6 before exit 137. Uniform
trial 2 completes all modes with quality, speed and pressure passing. Real trials
0 and 1 complete with paired pressure in all modes, but only selective speed
passes. The OOMs cannot be described as open-time failures.

## Separate memory diagnostics

Three fresh 6 GiB uniform-1536 workers retain the full query work and in-memory
report: original repeated `json.dumps`, streamed `json.dump`, and final-only
serialization. Each enables tracemalloc, preserves 536 exact/approximate preflight
checks and 2,048 timed audits, and returns identical results. Post-preflight growth:

| Reporting | Anonymous RSS bytes | Traced current bytes | Traced peak bytes |
|---|---:|---:|---:|
| Original | 32,587,776 | 7,621,053 | 7,836,835 |
| Stream | 27,418,624 | 7,628,337 | 4,708,897 |
| Final only | 27,303,936 | 7,623,046 | 4,702,776 |

Streaming reduces some allocation peaks but does not explain the retained
query allocations. A fourth full worker records depth-eight allocation sites.
Traced current rises from 19,948,389 bytes after preflight to 28,624,722 after
queries; GC releases only 140,115 bytes. Two timed query stacks at the Mojo
binding account for 5,342,553 and 1,670,520 bytes. The next investigation is
result-object ownership at that boundary. Instrumented RSS is not directly
comparable to the uninstrumented capacity matrix; no diagnostic timing is used
for acceptance and no complete OOM-cause claim is made here.

## Retained evidence

[Archive](2026-10-14-typed-live-capacity.json.gz): 412 files, 13,166,244 bytes,
SHA-256 `840430123f8bbf61db713a342afdb5c0f366dc6ac727dfbc1129de020638574f`.
Every embedded hash was checked after decompression. It includes complete Linux
source/package/test snapshots, build identity and logs, fixed worker/driver and
pressure controls, all 60 raw reports and container records, fixture queries and
oracles, all four diagnostic workers, summaries and analysis scripts. It also
retains the initial missing-PYTHONPATH launch and premature analysis guard
failures; neither started extra measurement workers. Engine binaries are
identified by hashes rather than embedded.

Next fix the demonstrated query ownership growth in a new isolated candidate,
validate results and lifetimes, then repeat the unchanged capacity protocol.
Warm/mixed regressions and all strict M5/M6 gates remain outstanding.
