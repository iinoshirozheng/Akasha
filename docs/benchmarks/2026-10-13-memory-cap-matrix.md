# Repeated constrained-memory matrix

The three-corpus, three-cap, three-trial matrix is complete and **FAILED**.
Of 108 constrained comparison cells, **84 have valid matched quality and 57
meet both speed requirements**. Six Akasha workers were OOM-killed at 128 MiB;
their 24 missing cells remain failures. Every completed worker passes quality.
No same-cap pair satisfies the predefined sustained-nonresident criterion for
both engines. M5/M6 remains open.

This is **emulated Linux x86-64 on the ARM64 Mac**, not native Linux performance.
Akasha uses the adopted mapped-segment implementation at `406eccd`. The rejected
candidate-summary and SIMD-validation prototypes are absent. Qdrant Edge is the
pinned 0.8.0 Linux wheel, with vectors converted to `on_disk=True` through its
public load/configure/optimize/flush/close APIs. Original resident fixtures are
retained. These results are separate from the resident warm and HTTP matrices.

## Frozen method and validation

Each corpus has 8,192 points, the original replacement/delete state, K=10,
unchanged filters, queries, oracle and frozen warm ef values. Each engine gets
one CPU, the same 128/192/256 MiB cap, and zero swap allowance. Three alternating
pairs run at each cap. One additional 6 GiB control pair per corpus checks
quality and residency; those single control pairs are not repeated acceptance.
All 60 workers run serially, without overlapping builds/tests/compression.

The immutable Docker image ID is
`sha256:540414f50b96439a6ba1475b79b2e2dd2208e86ebef33e2fbf2a176a8f037d31`.
Every worker copies fresh database inodes onto a Linux Docker volume, fsyncs and
requests `FADV_DONTNEED` once before open. Every initial vector-file `mincore`
observation is zero. No eviction is requested during measurement. Code/reports
use the host bind mount; database cache accounting uses the Linux volume.
Workers load query inputs and allowed-ID sets, without the full corpus matrix.

Each completed worker performs 67 exact/approximate preflight queries per mode,
then eight passes of the same 64 measured queries. Repetitions add timing
observations, not independent recall samples. All completed preflights match
their same-engine 6 GiB control, including IDs, Float32 score bits, execution
kind and statistics. All timed responses match preflight IDs and score bits.

| Scope | Completed workers | Matched quality | Strict speed | Exact checks | Timed response checks |
|---|---:|---:|---:|---:|---:|
| 6 GiB controls | 6/6 | 12/12 | 7/12 | 1,608 | 12,288 |
| Constrained matrix | 48/54 | 84/108 | 57/108 | 12,864 | 98,304 |

The 54 completed workers have 216/216 passing individual engine quality cells.
The constrained denominator retains all six failed workers. There are **no
timeouts** under the frozen 900-second per-worker bound. Docker independently
reports `OOMKilled=true` and exit 137 for all six failures. Their last persisted
checkpoint is `copied_new_inodes_before_open`, with status `initializing` and no
query cells. The worker does not persist again until open succeeds, so these
reports do not locate the exact allocation that failed. Binary/input identities
are frozen in the launch plan; those fields were not yet persisted by the killed
workers and are explicitly reported as missing. Completed-worker identities,
container image, CPU/caps and zero swap are verified.

The post-run summarizer initially assumed those identity fields existed and
raised `KeyError`. Its correction retains missing fields on failed workers while
requiring them for completed workers. The failed summary attempt and successful
retry are preserved; neither changed the measurements or acceptance rules.

## Every constrained result

Recall@10 must be at least .95, QPS at least Qdrant, and p95 no greater than
Qdrant. There is no tolerance or offset across cells or trials.

| Corpus | Cap | Matched quality | Strict speed |
|---|---:|---:|---:|
| uniform-128 | 128 MiB | 12/12 | 12/12 |
| uniform-128 | 192 MiB | 12/12 | 7/12 |
| uniform-128 | 256 MiB | 12/12 | 9/12 |
| uniform-1536 | 128 MiB | 0/12; Akasha OOM | 0/12 |
| uniform-1536 | 192 MiB | 12/12 | 12/12 |
| uniform-1536 | 256 MiB | 12/12 | 11/12 |
| real-1536 | 128 MiB | 0/12; Akasha OOM | 0/12 |
| real-1536 | 192 MiB | 12/12 | 2/12 |
| real-1536 | 256 MiB | 12/12 | 4/12 |

Each entry below shows trials 0/1/2. **P** passes both speed checks after quality;
**F** fails speed; **O** has no valid pair because Akasha was OOM-killed.

| Corpus / mode | 128 MiB | 192 MiB | 256 MiB |
|---|---|---|---|
| uniform-128 / all | PPP | FFF | FFF |
| uniform-128 / correlated | PPP | PPP | PPP |
| uniform-128 / independent | PPP | PPP | PPP |
| uniform-128 / selective | PPP | FPF | PPP |
| uniform-1536 / all | OOO | PPP | PPP |
| uniform-1536 / correlated | OOO | PPP | PPP |
| uniform-1536 / independent | OOO | PPP | PPP |
| uniform-1536 / selective | OOO | PPP | PFP |
| real-1536 / all | OOO | FFF | FFP |
| real-1536 / correlated | OOO | FFF | FFP |
| real-1536 / independent | OOO | FFF | FFP |
| real-1536 / selective | OOO | PFP | FFP |

## Residency and limits

Before launch, the diagnostic required positive process major faults in **each
of the final four passes**, and vector-file residency below .95 at every
corresponding boundary. Multiple files use byte-weighted residency; every file
observation is retained. Faults are process-wide, not attributed to a specific
file. This criterion is evidence of sustained pressure, not an I/O trace of
every scoring operand.

Akasha meets that criterion in nine cells: all three real-1536 ANN modes, in
all three 192 MiB trials. Late pass boundaries show 28.9–43.3% vector-file
residency and 23,513–56,561 major faults per pass. Their QPS is 17.3–43.4, versus
Qdrant's 1,165–2,917 across the corresponding ANN cells. Qdrant vector residency
there remains about 99–100%, so none is a paired nonresident comparison.

Qdrant meets the criterion in 28 constrained cells, including all uniform-1536
128 MiB modes and the final real-1536 256 MiB trial. Akasha either OOMs, remains
resident, or uses owned exact vectors in the corresponding cells. Uniform
workloads and real selective use Akasha's planned exact path; evicting their
unused HNSW sidecar does not make the authoritative exact inputs nonresident.
Thus **zero of 108 pairs** qualify for paired sustained-nonresident acceptance.

Nonmonotonic and variable results remain in the matrix. Qdrant uniform-1536
256 MiB workers take 6.66 / 257.41 / 15.00 seconds, while real-1536 256 MiB takes
3.48 / 9.91 / 139.74 seconds. These whole-worker durations include preparation
and preflight and are not query latency summaries. The final real trial's four
speed passes coincide with Qdrant pressure; they do not cancel the earlier
failures or prove a general query speed advantage.

The adopted mapping change enables the repeated 192 MiB Akasha trials to finish,
but the 128 MiB capacity failures, owned exact residency and remaining per-cell
speed failures still require work. Native Linux performance is unverified.

## Reproduction evidence

[Complete raw archive](2026-10-13-memory-cap-matrix.json.gz): 213 files,
11,684,290 bytes; SHA-256
`1f72f9ed18a2b2eb9b221e7245b2d15e87c6684c39b6a2897ccbe3b6ce336320`.
It contains the frozen plan/method, queries and oracle, fixture hashes/config,
worker/driver/summary code, all jobs/logs/reports/latencies, container inspections,
pressure observations, failed summary attempt and validation evidence. Existing
[mapped-reader build evidence](2026-10-13-mapped-segment-read.md) and
[Qdrant wheel/fixture preparation](2026-10-13-memory-cap-probe.md) identify the
binaries and their build sources.

The retained driver is
`.build/linux-runtime-20261012/memory-probe/run-matrix.py`; it used
`rtk proxy pixi run env PYTHONPATH=python:. python <driver>`.
Reproduction requires new output directories and container/trial names. Do not
rerun its mutating preparation over retained fixtures or overwrite raw trials.
