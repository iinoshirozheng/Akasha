# Four-row scoring in bounded delta scans — not adopted

Reusing the existing four-row F32 kernel improves all six real-1536 warm
correlated/independent QPS pairs by **1.0–9.8%**, with identical results and work.
The complete fixed matrix still fails: warm passes fall **23 → 22 / 36** and
mixed stays **29 / 36**, with two warm and one mixed pass→fail cells. This
candidate is not adopted; production engine source and binaries are unchanged.

The frozen [row-sized CRC development candidate](2026-10-14-crc32-row-stream.md)
is the parent, including its unresolved gates. Only the scoring loop in
`SegmentedHnsw._search_delta_prepared_backend` changes. It gathers four current,
admitted F32 slots and signed IDs into fixed SIMD locals, calls the graph's
existing four-row kernel for a full group, then offers results in the original
physical order. Tails and compact scalar backends use their original single-row
kernel. There is no early stopping or heap-dependent scoring in this scan, so
batching adds no distance evaluations. Policy, validation, backend dispatch,
query preparation, candidate breadth, final rerank and every counter remain.
There is no retained scratch, dependency, graph-construction or format change.

The original scan method is retained verbatim, then mechanically dedented and
given an explicit receiver type as a serial test reference. Both the unchanged
parent and candidate pass **2,736 paired scans** each: 36 fixtures covering all
three F32 metrics; dimensions 3, 63, 64, 65, 128 and 1536; owned/mapped bases;
zero through 17 admitted rows plus allow-all; four heap breadths; sparse holes,
replacement/deletion/reinsertion, ties and IDs near both signed Int extremes.
Every result ID, Float32 bit and all 19 search-statistic fields match. Five
inactive physical slots and unchanged preparation/descent counters are checked.
The evidence collector verifies the reference extraction and that replacing
only the original loop exactly reconstructs the candidate source.

Broader validation passes **173 Mojo cases in 18 files**, **10 crash-state cases
in three files**, **369 Python cases**, and all three C ABI stages. Coverage
includes native/compact delta backends, source ownership, graph fallback bounds,
filter bridges, widening, four-row arithmetic/bounds, mutations, rebuild and
checkpoint publication, incremental/point projection and persisted overlays.
Python has three existing warnings and no skips; builds have no warnings. The
successful new candidate matrix is reused in the broader count without rerun.

All **54 serial native workers** complete with the original corpora, filters,
ef settings, plans, oracles, timing boundaries and three rotating triples.
Warm takes 44.85 s and mixed 63.21 s. Each version passes quality **36/36** in
both phases; every paired ID, score bit, statistic and execution decision
matches. Leases and reopen oracles pass. All **18 overlay/metadata payload
pairs** are byte-identical with valid envelope and snapshot CRCs. Mixed returns
its expected strict-gate failure after all nine triples finish.

| Phase | Strict speed before → after | Pass → fail | Fail → pass |
| --- | ---: | ---: | ---: |
| Warm query | 23 → 22 / 36 | 2 | 1 |
| Mixed query | 29 → 29 / 36 | 1 | 1 |
| Mixed write+flush | 5 → 6 / 9 | 0 | 1 |

Warm loses uniform-128 selective trial 2 (p95 40.500 → 62.834 µs versus Qdrant
50.750 µs) and uniform-1536 selective trial 0 (QPS 10,140.48 → 9,603.78 versus
Qdrant 9,672.24). It gains uniform-1536 selective trial 2. These planned-exact
cells do not execute the changed delta scan; their failures remain, without a
causal claim or tolerance.

Mixed gains real-1536 correlated trial 0 but loses real-1536 all trial 2: QPS
2,002.26 → 1,830.49 versus Qdrant 1,942.71, and p95 662.459 → 735.667 µs versus
672.084 µs. All three real unfiltered mixed QPS pairs regress **5.8–8.6%**, and
p95 rises 3.5–11.1%. A subsequent per-query path audit finds **13 graph and
59 delta-scan queries per mixed trial**, while all 64 timed warm unfiltered
queries use graph search. Low ef routes the initial delta through the graph,
but later mixed maintenance changes the source geometry. The mixed regression
cannot be attributed solely to the graph branch. The complete raw results retain
both paths and these regressions.

| Real 1536D warm mode | QPS after/before, trials 0 / 1 / 2 | p95 after/before, trials 0 / 1 / 2 |
| --- | --- | --- |
| Correlated | 1.0684 / 1.0097 / 1.0728 | .9153 / 1.0097 / .9217 |
| Independent | 1.0360 / 1.0976 / 1.0137 | .9458 / .8527 / .9854 |

Five of six warm filtered p95 pairs improve; correlated trial 1 regresses .97%.
All six corresponding mixed QPS pairs improve .7–3.0%, and five mixed p95 pairs
improve, while independent trial 0 regresses 4.9%. These gains do not compensate
for any failed cell.

Combined write+flush gains real-1536 trial 1 parity. Only five of nine combined
QPS and p95 pairs improve, and six flush QPS pairs improve. Real-1536 trial-2
combined p95 regresses 11.0%; uniform-1536 trial 1 regresses 8.0%. No write or
flush path changed, so these observations do not establish a write optimization.
Fresh-process open improves four pairs (ratios .9519–1.0638), same-process reopen
six (.9175–1.0339); OS cache is present and neither is nonresident evidence.

The [archive](2026-10-14-delta-four-scores.json.gz) contains **839 files,
4,015,007 bytes**, with every embedded hash verified: full source/diffs, serial
reference and exact tests, validation logs, all native workers, gate transitions,
cache-byte audits and verified parent/original-plan references. No full CPU,
crash-kill, capacity, native Linux, HTTP or GPU acceptance is claimed. M5/M6
remain incomplete.

- Python SHA-256: `f65f3eed3313740e734a562c15db539d6c61bca1216d33f83687477755bbb05b`.
- C library SHA-256: `dde75ad72a0069ef65428ca9e48413cee4e452f6b8ac214ee729581270dc7f98`.
- Archive SHA-256: `c6963718b322d26c49fb27a90f0ed87cc8f7846571dd6ff769c140d007bfaecd`.

Next inspect the actual native code around the graph/scan dispatch. The repeated
unfiltered regression needs evidence about the unchanged graph path before any
new code-layout experiment; do not assume that source-level branch separation
implies an unchanged generated caller. No such follow-up is included above.
