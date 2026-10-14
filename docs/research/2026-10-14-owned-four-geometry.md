# Owned four-row kernel and scan geometry diagnostics

The isolated diagnostics **do not reproduce the real-1536 mixed scan regression**.
Four-row scoring improves all 27 high-dimensional kernel cases by 7.8–34.9% and
all 18 high-dimensional complete synthetic scan cases by 10.8–21.2%. This is
counterevidence to a simple kernel or admission/heap explanation, not acceptance
of the rejected [four-row candidate](2026-10-14-delta-four-scores.md) or
[dispatcher outlining](2026-10-14-delta-dispatch-outline.md).

No engine source changes. The kernel harness uses the frozen row-CRC source;
the full-scan harness uses the frozen four-row source plus an exact extracted
serial scan reference. Both use the installed Mojo 1.0.0, metal:4/apple-m4 target.
Full source inventories and binaries are identified and verified. The underlying
owned distance and metric sources are byte-identical to production. Both new
harnesses compile and execute successfully; existing engine regressions are not
rerun or claimed as new results.

The kernel harness builds 1,024 prepared owned rows and 17 prepared queries,
using deterministic synthetic values. It tests dot/L2/cosine, dimensions 128 and
1536, and continuous, stride-four and coprime-permuted slot sequences. Each case
scores 64, 256 or 819 rows. Query selection and starting position vary each
repetition; two variants rotate across five trials. A no-inline sequence wrapper
prevents repeated-call elimination, while the underlying kernels retain their
original compilation contract. Order iteration and result-bit accumulation are
included; admission and heap work are absent.

All **313,344 preflight per-score bit comparisons** and every aggregate match.
All **540 timed block observations** remain, including regressions. The data
fits an owned resident working set; no cold-cache or nonresident claim follows.

| 1536D cosine, 819 rows | Single-row ns/distance | Four-row ns/distance | Four / single |
| --- | ---: | ---: | ---: |
| Continuous | 76.078 | 66.310 | .8716 |
| Stride four | 95.144 | 67.155 | .7058 |
| Permuted | 103.315 | 67.906 | .6573 |

At 128D, benefits are inconsistent: for example, continuous dot with 64 rows
regresses 7.7%, while permuted L2 with 819 rows improves 29.4%. Nothing is
excluded, and these geometry cases are not replacements for the fixed corpora.

The complete-scan harness constructs actual segmented indexes with one base
node and 64, 256 or 819 delta rows, three F32 metrics and both dimensions. It
uses the real `_SourceAdmission` or `_FilteredSourceAdmission` with bitmap/ID
lookup accepting every fourth row. Both versions use k10, initial ef32, max
128 and the unchanged bounded-scan policy. These are declared diagnostic
fixture settings, not edits to any native acceptance plan.

For every fixture, all 17 prepared queries match in IDs, Float32 bits, all
19 statistic fields, scan label and visited count: **612 paired scans**. Timings
include validation, source/filtered admission, bounded heap, statistics, result
construction and destruction. Each of the **360 observations** measures 64
calls with varying queries; variants rotate over five trials. Base graph search,
merged authoritative rerank, Python and writes are outside these measurements.

| 1536D cosine, 819 physical slots | Serial µs/scan | Four-row µs/scan | Four / serial |
| --- | ---: | ---: | ---: |
| All current delta rows | 81.063 | 70.922 | .8749 |
| Every fourth row eligible | 37.141 | 29.281 | .7884 |

All 18 high-dimensional full-scan cases improve. Four of 18 low-dimensional
cases regress, including all three unfiltered 819-row cases by 10.7–12.9%.
This distinguishes a measured low-dimensional overhead from the unexplained
high-dimensional whole-query regression; it does not justify a new dispatch
threshold without complete evidence.

Eighteen complete native symbol dumps compare the six width-16 single/four
kernels in the Python candidate, kernel harness and full-scan harness. All six
remain separate symbols with equal sizes across binaries: single dot/L2/cosine
764/752/832 bytes and four-row 1,616/1,696/1,644 bytes. Thus the harness does not
simply inline away all distance calls. Equal sizes do not prove instruction or
caller identity, and no such claim is made.

The archive also retains the correction of the original mixed-path explanation.
Warm real-unfiltered uses ef16; the original mixed plan uses ef32. Each mixed
trial starts with **59 delta scans**, then switches to **13 graph queries** at
all-query ordinal 59, block 26. Earlier prose reversed this order; the original
runs, plans, ef values and raw observations were never changed. Both experiment
reports now state the actual order.

The [archive](2026-10-14-owned-four-geometry.json.gz) contains **286 files,
679,540 bytes**, including full frozen sources, runnable harnesses, all 900 timing
observations, semantic checks, native assembly and verified parent references.
Every embedded hash is verified. Production engine and Python/C binaries remain
unchanged. No Qdrant, native Linux, capacity, HTTP, full CPU/crash or GPU gate is
closed; M5/M6 remain incomplete.

Archive SHA-256: `d3a5bf7b14209ac41a5cb2b258af6257ef31b06098137b792bd83012e54fcc47`.

Next localize base, delta and authoritative rerank time within the original
mixed plan using an isolated diagnostic, keeping the same result/stat audits.
The synthetic benefit cannot explain the full workflow's regression by itself;
no further code-layout or row-grouping change is justified yet.
