# Remaining score work after weak value certificates

The retained candidate already uses NEON FMA in its hot Dot kernels. Its
real-correlated workload still performs **32.6–33.0% more complete vector
evaluations than Qdrant**, after accounting for score reuse. This establishes
excess work, not an allocation of the elapsed-time gap. No engine optimization
or new performance acceptance is claimed in this diagnostic.

The next bounded implementation is score reuse for **already-scored delta
candidates**, using the same immutable-owner proof discipline. It can remove
the remaining 128 duplicate delta evaluations in real-independent queries.
It cannot remove the 204.75 real-correlated delta evaluations: that path already
skips delta graph scoring and evaluates each admitted delta vector once.

## Exact binaries and source

The retained weak-certificate native binary is
`5ae85379b8948276ac2aba0e0fa1fd86447989c499562cc57fa1411b50c936fc`.
Disassembly of its width-16 Dot functions contains:

| Function | Instructions in complete function | `fmla.4s` instructions | `fmul.4s` instructions |
|---|---:|---:|---:|
| Mapped single | 274 | 4 | 0 |
| Mapped four | 510 | 16 | 0 |
| Authority pair | 237 | 8 | 0 |

These are static instruction counts, not dynamic work or latency. The captured
symbol inventory, exact ranges, disassembly commands and output are archived.
The pinned Qdrant `simple_neon.rs` also uses FMA. Adding explicit FMA syntax to
Akasha therefore lacks a demonstrated mechanism for improvement. No arithmetic,
reduction order or numerical contract changed.

One isolated Python-binding getter exposes the **existing** private
`_last_reused_base_scores` counter. All 131 other Mojo files, including every
search/scoring implementation, remain identical to the retained candidate.
The instrumented binding builds with Mojo **1.0.0 (ed45d567)**; its native SHA is
`36fdc21876e31d166b9cac85883773e0d9f6bea00be8a942b137390255f842bb`.
The getter is a diagnostic seam, not an adopted public API or concurrent getter.

The existing Qdrant counting executable is reused without rebuilding:
`10d5053dbdad54dda45662c08c44d807d1b8bdeae21857ac66fdf20e375f6e94`.
It instruments `MetricQueryScorer` only, at pinned upstream revision
`21db2f3ff95d50de3a2b88a741312c056fd1762d`. Its previous build used release opt2,
no LTO and 16 codegen units; it is not the official-wheel performance binary.
The official wheel remains
`746ce4acdbb56db68aaba805bddf52961a083c5ed5da19f16b5ba500114c788d`.
Original/instrumented scorer sources, patch, Rust example, build provenance,
NEON scorer, PointScorer and upstream license are included.

## Work counts

All nine existing graph pairs are cloned read-only. The three corpora, three
trials, four modes, 67 queries per mode and selected ef values stay fixed.
Each native engine is run twice in separate serial processes. The only
previously authorized parameter change remains Qdrant real-correlated ef128.
No fresh index construction, timing samples or ef selection occurs here.

For successful ANN queries, actual metric evaluations are:

`distance_evaluations + reranked_candidates - reused_base_scores`

The public rerank counter counts authority-checked candidates, including reused
scores. Adding it unconditionally overstates the current work. Planned exact
queries use `distance_evaluations` alone; their retained candidates are not
additional metric evaluations. Explicit Qdrant exact queries provide controls
against the independently eligible population. No stale Akasha explicit-exact
statistics are used.

Means below cover ordinals 3–66. Akasha counts are identical across the three
frozen Akasha graphs; Qdrant ranges retain all three graph results.

| Corpus / mode | ef A/Q | Traversal or exact | Base reused | Rerank recomputed | Akasha total | Qdrant total range | A/Q work range |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| uniform-128 / all | 128/96 | 4274.969 | 128 | 128 | 4402.969 | 3759.125–3763.828 | 1.1698–1.1713 |
| uniform-128 / correlated | 256/256 | 1310.109 | 256 | 204.750 | 1514.859 | 1555.719–1558.062 | .9723–.9737 |
| uniform-128 / independent | 256/256 | 1312.500 | 256 | 204.750 | 1517.250 | 1543.234–1544.188 | .9826–.9832 |
| uniform-128 / selective | 10/10 | 249.594 | 0 | 0 | 249.594 | 249.594 | 1.0000 |
| uniform-1536 / all | 512/512 | 7628.219 | 512 | 512 | 8140.219 | 7685.172–7690.391 | 1.0585–1.0592 |
| uniform-1536 / correlated | 512/512 | 1706.375 | 512 | 204.750 | 1911.125 | 1925.938–1926.812 | .9919–.9923 |
| uniform-1536 / independent | 512/512 | 1699.500 | 512 | 204.750 | 1904.250 | 1921.484–1924.047 | .9897–.9910 |
| uniform-1536 / selective | 10/10 | 249.594 | 0 | 0 | 249.594 | 249.594 | 1.0000 |
| real-1536 / all | 32/24 | 1580.438 | 32 | 32 | 1612.438 | 1492.531–1497.203 | 1.0770–1.0803 |
| real-1536 / correlated | 256/128 | 955.391 | 256 | 204.750 | 1160.141 | 872.422–874.938 | 1.3260–1.3298 |
| real-1536 / independent | 128/128 | 817.672 | 128 | 128 | 945.672 | 851.562–853.750 | 1.1077–1.1105 |
| real-1536 / selective | 10/10 | 249.594 | 0 | 0 | 249.594 | 249.594 | 1.0000 |

The source-derived delta breakdown is separately checked against frozen update
IDs, deletion membership, payload filters and each query's retained delta count.
All selected ANN cells meet the existing small-delta scan predicate. For real
independent, the scan evaluates a mean 204.75 vectors, retains 128, then reranks
those 128 again. Real all similarly rescans 32 retained delta candidates.
For real correlated, every eligible delta population fits ef256, so the scan
admits IDs without scoring; the mean 204.75 rerank evaluations are first-time
work. These breakdowns are derived from the audited path and inputs, not newly
instrumented per-source counters or assumptions based on retained counts alone.

## Verification and limits

- **54 workers** exit successfully: 18 instrumented Akasha, 18 official Qdrant,
  and 18 instrumented native Qdrant.
- **4,824 Akasha queries**, **9,648 official Qdrant queries**, and **9,648 native
  Qdrant queries** are retained, including warmup requests and exact controls.
- **9,216** selected responses match frozen IDs, F32 bits, recall and available
  complete stats. The first three requests per mode are retained and compared
  between repeats, but are not included in this frozen measured-response count.
- All **9,648** native Qdrant results match the official wheel IDs and F32 bits.
  All **4,824** forced-exact native counts equal the eligible population.
- All **1,206** Akasha planned-exact counts equal the eligible population.
  All **27** paired result/count groups repeat identically.

The evidence-preparation helper initially lacked the repository Python import
path. Its failure and corrected `PYTHONPATH=.` invocation are recorded; no
engine query failed or needed rerunning. Repeated request streams are byte-equal:
all 18 consumed stream hashes are retained, with their three unique contents
stored once. No responses or count samples are omitted. Archive-only replay
recomputes the numerical summaries and audits without engines, NumPy, database
files or the original work directory.

Production `src` remains byte-equivalent to `a6822c3`; the retained certificate
candidate is unchanged. Existing performance failures remain failures. This
diagnostic does not refresh CPU/crash/C/client/capacity acceptance. Native Linux
x86_64 remains explicitly deferred. The strict per-cell quality/QPS/p95 gates,
all old failures and the remaining M5/M6 work stay open.

For delta score reuse, preserve same-query score provenance, source identity,
finite checks, first-error/partial-stat order, replacement/deletion behavior
and graph promotion invalidation. A scored delta path may carry its scores;
the unscored admission path must not manufacture them. Never treat an ID,
sequence or raw address alone as proof. Measure the resulting implementation
against the retained candidate before extending the full fixed acceptance runs.

[Complete evidence archive](2026-10-23-immutable-point-work-audit.json.gz):
**350 artifacts, 24,991,378 bytes**, SHA-256
`f377ea33b0ae153c9a72c5bdb0d99ea4541e4d31abf7a474e37f712fa27b7cf7`.
Archive-only replay passes and reproduces both audit outputs byte-for-byte.
