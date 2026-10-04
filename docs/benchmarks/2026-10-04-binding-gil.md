# Python ANN GIL experiment — not adopted

Production remains at engine `cc15f37`, Python kernel SHA-256
`609aeb2b0d721cbc1d84f6aec1bd325a360484cfa72d207600313b342c5cd8d9`.
The isolated candidate permits Python thread progress during native ANN, but its
complete fixed matrices do not establish enough end-to-end benefit to adopt it.
**All performance assessments FAILED; M5/M6 remain unfinished.**

## Evidence and implementation

Baseline HTTP phase instrumentation covers the original three corpora, four
filters and 1/2/4 clients: 4,020 valid responses, including 2,304 timed requests.
Each request schedules one worker. High-dimensional single-client JSON parsing
takes approximately 179–212 µs; body validation approximately 15 µs and response
validation/encoding approximately 6–9 µs. Worker waits grow with concurrency.
These wall intervals include waiting and are not native CPU measurements.

A separate observer records native `c_call`/`c_return` boundaries and a Python
heartbeat thread, excluding 50 µs at either boundary. Production has zero calls
with an interior heartbeat among 402 valid searches and 5,790 heartbeat ticks.
Source inspection confirms no GIL-release scope. This motivates an experiment,
not an assumed speedup.

The candidate uses Mojo 1.0.0's existing `GILReleased` and `ArcPointer` APIs.
`BoundCollection` pins a shared native owner before Python conversions, releases
the GIL only around approximate search, and converts results after reacquisition.
The native writer lock continues to serialize collection ANN, writes and close.
No engine, durable format, C ABI, candidate budget or public API changes.
See the [design and revision history](../plans/2026-10-04-binding-gil.md).

The corrected V2 observer witnesses interior heartbeat progress in 345/402
valid calls, with 10,539 ticks. Short calls need not contain a tick. Its HTTP
profile has 4,020 paired responses with identical IDs, F32 score bits and stats.
This confirms thread progress, not a formal throughput result.

## Fixed V2 before/after/Qdrant gates

All corpora, seeds, filters, K, ef settings, trials and service boundaries remain
fixed. Each trial/cell requires Recall@10 ≥ .95, QPS ≥ Qdrant and p95 ≤ Qdrant.
Gains in another cell do not offset failure.

| Gate | Before strict passes | Candidate strict passes | Matched recall |
| --- | ---: | ---: | ---: |
| Warm binding | 20/36 | 22/36 | 36/36 each |
| Mixed query | 25/36 | 25/36 | 36/36 each |
| Durable write + flush | 4/9 | 4/9 | Not a recall gate |
| HTTP, 1/2/4 clients | 24/108 | 28/108 | 105/108 each |

Warm has 19/36 A/B timing regressions and one pass→fail (real-1536, trial 1,
selective). Mixed has 23/36 regressions and two pass→fail cells (uniform-128 and
uniform-1536, trial 2, selective). These before samples are this experiment's
cohort; changes from older counts are not adopted improvements.

HTTP has 64/108 cells with at least one slower A/B timing metric and six
pass→fail cells, all uniform-128: trial 1 independent at all three client counts;
trial 2 correlated at 1/4 clients; trial 2 independent at 1 client. Per-client
strict counts are 13→11, 6→9 and 5→8 out of 36. Per-corpus counts are uniform-128
9→5, uniform-1536 15→23, real-1536 0→0 out of 36. Only 44/108 cells improve both
A/B timing metrics. These comparisons inform adoption; they are not an added
“every A/B cell must improve” requirement.

Qdrant's uniform-128/trial-1/all Recall@10 is .946875 at 1/2/4 clients: three
quality failures remain in the assessment. Requests are valid; quality failed.
No ef retuning, rerun substitution or removal of these samples was performed.

Audits: warm 7,236 requests and 7,236 exact checks, 2,412 paired query IDs/stats
and 24,120 common F32 score bits; mixed 7,776 requests, 2,592 paired IDs/stats,
25,920 bits, all 27 reopen oracles and 18 Akasha leases; HTTP 36,180 valid
requests (7,236 exact preflight, 7,236 approximate preflight, 20,736 timed,
972 warmup) and 12,060 paired IDs/F32 bits. All completed successfully.

## Correctness and retained launcher failures

V1 passed 22 targeted and 388 existing full Python tests. A later direct
reproduction found that Python vector conversion can call `close()` before the
owner is pinned, aborting both production and V1 on empty `Optional.value()`.
V2 pins before conversion. Its 12 subprocess regressions cover `__len__` and
`__iter__`, approximate/filtered approximate/filtered exact, and list/column
results: all 12 abort on production; V2 passes all 34 targeted tests and the
388 existing full Python tests. Race tests exercise competing calls but do not
claim scheduler-guaranteed interleavings. No new full Mojo/crash/C ABI/examples,
Linux/GPU/ASan or sustained nonresident gate was run.

V1's HTTP launcher accidentally replaced Pixi's PATH without the Pixi Python
bin: miniconda Python 3.10/FastAPI 0.122.0 ran instead of project Python 3.11/
FastAPI 0.141.1. Its provisional 18→27/108 and three Qdrant .9484375 quality
failures are preserved **but are not the intended runtime's gate**. The first
summary incorrectly asserted every quality cell passed; that failure and the
corrected assessment remain. V2's first heartbeat inherited the wrong launcher,
and its first HTTP profile failed before measurement because that FastAPI lacked
`serialize_json`. Those outputs are separate from verified V2 results.

The corrected seven-stage pipeline uses absolute project Python, includes its
bin for children and checks interpreter/package identities. It completed all
stages serially: heartbeat, profile, profile assessment, 54 binding workers,
binding assessment, 27 HTTP servers, HTTP assessment. Valid runtime versions:
FastAPI 0.141.1, pydantic 2.13.4, pydantic-core 2.46.4, Starlette 1.6.0,
uvicorn 0.52.4, httpx 0.28.1, uvloop 0.22.1, httptools 0.8.0. Test evidence uses
the intended Pixi interpreter and remains valid in both revisions.

## Frozen evidence and next step

[Immutable archive](results/2026-10-04-binding-gil.json.gz): 1,192 files,
23,002,938 bytes, SHA-256
`830a869d911c75a095c698e5f45932dd1abc62a4047f096b0cdff8b2b6ae02d0`.
It includes baseline, both candidates, all source/package snapshots, identities,
scripts, tests, raw samples, diagnostics, logs, failed launches and assessments.
Gzip readback and every embedded file hash were checked. V2 binary SHA-256:
`940cdb1b5b06b534852b44aa18f65fe2e45975bfe6d0273528f6340a04fabc01`.

As-run directories are `.build/2026-10-04-http-phases`,
`.build/2026-10-04-binding-gil` and `.build/2026-10-04-binding-gil-v2`.
The verified orchestration is V2's `pipeline-verified.py`; its manifests record
each exact command, runtime and exit status. To reproduce, extract to a fresh
directory, inspect/rebase absolute paths and use fresh output/database paths;
do not blindly rerun drivers over frozen samples. All shell commands start `rtk`.
Saved-package pytest uses `-o pythonpath=`, import/hash guards and a Metal wrapper
that routes child compiles to copied source. Measurements are serial and do not
overlap builds, tests or compression.

The independent production conversion-close abort will be fixed with a minimal
post-conversion handle check. GIL release and the heap-owner change remain
unadopted. This correctness fix does not imply the performance gates passed.
