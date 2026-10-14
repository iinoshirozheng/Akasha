# Filtered-only delta four-row scoring

The narrower candidate removes the repeated real-1536 mixed unfiltered QPS
regression seen in the original four-row experiment, while retaining filtered
query gains. It is **not adopted**: warm strict parity falls from 23/36 to
21/36 with two pass-to-fail selective cells. Mixed query parity remains 33/36
and combined write/flush parity remains 6/9. No failed cell is offset by another
cell's improvement.

The [native phase diagnosis](2026-10-14-delta-native-phases.md) localized the
earlier regression to delta scan/merge. The
[memory-context probe](2026-10-14-delta-memory-context.md) then reproduced slower
unfiltered scans alongside faster filtered scans. This candidate starts from
the frozen, still-unadopted row-CRC parent, not the production engine. Only
`segmented_hnsw.mojo` differs from that parent: a required internal compile-time
flag selects the existing four-row F32 loop for filtered scans, and the exact
original serial loop for unfiltered or compact-scalar scans. The two internal
collectors pass explicit values. No public option, retained state, dependency,
format, scan-versus-graph policy, ef or validation contract changes.

The grouped loop is mechanically identical to the frozen four-row version
apart from indentation; its original inner compile-time checks fold under the
enclosing F32 specialization. The serial loop is likewise an exact extracted
copy. Admission precedes scoring, physical offer order and Float32 accumulation
order stay intact, and graph fallback remains unchanged. This is evidence for
the fixed filter workloads, not a claim that every filter selectivity benefits.

Both specialization values pass **5,472 paired scans across 72 fixtures**:
three F32 metrics, dimensions 3/63/64/65/128/1536, owned/mapped bases, all group
tails, equal scores, negative/extreme IDs, historical replacements and
delete/reinsert. IDs, Float32 bits and all 19 statistics match the independent
serial reference. The prior parent's 2,736-pair successful run is reused with
its original hashes; it is not reported as a new 5,472-pair parent run.

Fresh candidate validation passes **173 Mojo cases in 18 files, 10 crash cases
in three files, 369 Python cases** (three existing warnings, no skips) and all
three C ABI build/compile/run stages. Full source inventories and Python/C
binary identities are verified; production engine and binaries remain unchanged.

All **54 serial native workers** complete: three rotating triples per corpus
for warm (44.60 s) and the original mixed plan (62.79 s). Both versions pass all
36 quality cells in each phase. Result IDs, score bits, statistics and execution
decisions match, including warmups; all original mixed oracle, retained-lease
and exact-reopen checks pass. Eighteen paired cache payloads are byte-identical,
with valid outer and nested snapshot CRCs.

| Strict gate | Row-CRC parent | Filtered-only candidate | Transitions |
| --- | ---: | ---: | --- |
| Warm query cells | 23/36 | 21/36 | Two pass → fail; no gains |
| Mixed query cells | 33/36 | 33/36 | None |
| Mixed combined write + flush | 6/9 | 6/9 | None |

The two warm failures are retained without tolerance:

- Uniform-1536 selective trial 0: QPS 10,246.35 → 9,520.63 versus Qdrant
  9,532.03; p95 109.875 → 131.375 µs versus Qdrant 124.667 µs.
- Real-1536 selective trial 0: QPS 9,559.25 → 9,292.81 versus Qdrant
  9,360.55; p95 124.875 → 132.959 µs versus Qdrant 124.875 µs. The parent's
  equal p95 passes the original ≤ requirement; the candidate fails it.

These are planned-exact queries, outside the changed segmented scan path.
That fact does not excuse the failures or establish a specific compilation,
cache or scheduling cause.

Real-1536 filtered warm QPS improves in all six correlated/independent cells by
1.7–17.7%; p95 improves in five, with independent trial 2 regressing .58%.
Mixed filtered QPS improves in all six by 1.1–2.5%; p95 improves in five, with
correlated trial 2 regressing 1.13%. All original trials remain.

| Real-1536 mixed all-query comparison | Trial 0 | Trial 1 | Trial 2 |
| --- | ---: | ---: | ---: |
| Full-cell QPS candidate / parent | 1.0106 | 1.0057 | 1.0231 |
| Full-cell p95 candidate / parent | .9486 | 1.0290 | .9808 |
| Original first 59 scan-query QPS ratio | 1.0112 | 1.0041 | 1.0326 |
| Original final 13 graph-query QPS ratio | 1.0084 | 1.0119 | .9868 |

The original mixed all ef remains 32, with 59 scans followed by 13 graph
queries; warm all ef remains 16 and uses graph search. Unlike the previous
four-row experiment's three full-cell QPS regressions of 5.8–8.6%, these three
new pairings improve. This is a comparison within each experiment's paired
parent, not a direct timing comparison between different sessions. Trial 1
p95 and trial 2 graph-cohort regressions remain visible; cohort ratios are
diagnostics and never substitute for full-cell gates.

Real mixed selective QPS regresses in all three trials by .9–2.6%, with p95
increasing 4.6–10.4%, although those full cells still pass Qdrant. Across all
nine maintenance comparisons, only four combined QPS and four combined p95
measurements improve; flush QPS improves in five and p95 in six. Real trial 2
combined QPS falls 3.3% and p95 rises 5.0%. No write/flush improvement is claimed
for a query-only change. Initial-open and cached-reopen observations are retained
separately and establish no nonresident/cold-disk result.

Python binary SHA-256:
`4b087562aa46225c41fff21a4e1c7b46fcdc54ae88b23c58a6698533f48da5b6`.
C library SHA-256:
`824c7c25d703aee07b305d2a78f923f267c7b5cae86d7974405eae9aada3cda9`.

The [archive](2026-10-14-delta-filtered-four.json.gz) contains **841 files,
4,024,327 bytes**, full isolated sources, differential reference/tests, runnable
drivers, all validation/native logs and samples, durable payload audits and
verified source/binary identities. Every embedded hash is verified.
Archive SHA-256:
`a191ce998288f88539a6516c54a5e86a76a249f93d30c19b62035714a612099b`.

The remaining planned-exact warm failures and real filtered throughput gaps
require separate evidence before another optimization. No acceptance threshold
is relaxed and no sample is dropped. Production, capacity, native Linux, HTTP
and GPU status remain unchanged; M5/M6 are incomplete.
