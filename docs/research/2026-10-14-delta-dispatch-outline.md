# Keep delta dispatch out of line — not adopted

Adding only `@no_inline` to the existing delta dispatcher does not resolve the
four-row candidate's regressions. Warm strict passes fall **22 → 21 / 36**;
mixed remains **33 / 36**, and write+flush **6 / 9**. All three real-1536 mixed
unfiltered QPS pairs regress another **1.8–6.2%**. This candidate is not adopted.
Production engine source and binaries remain unchanged.

The frozen [four-row candidate](2026-10-14-delta-four-scores.md) is the parent.
Every method body, algorithm, guard, source policy, query parameter and score
operation is byte-identical. The evidence collector verifies the single
annotation delta. No helper, configuration, dependency, persistent state or
retained scratch is added.

The hypothesis came from actual generated ARM64 code, not an assumed compiler
behavior. Four-row grouping enlarged each F32 unfiltered collector from 14,580
to 15,108 bytes, with local stack reservation 0xac0 → 0xb60 (+160 bytes).
Filtered collectors grew 14,964 → 15,384 bytes and 0xbd0 → 0xc90 (+192 bytes).
The initial 112-byte register-save area was unchanged. These observations alone
do not establish the cause of slower queries.

Outlining creates six separate F32 delta routines: three filtered at 3,172 bytes
and three unfiltered at 3,076 bytes, with local stack reservations 0x260 and
0x240. Filtered outer collectors shrink to 12,248 bytes with local reservation
0xb50. However, the compiler then inlines all unfiltered collectors into one
**128,316-byte** `_search_candidates` wrapper, reserving 0x3000 + 0xe20 local
stack bytes. The parent's wrapper was itself inlined and had no standalone
symbol. These are different generated boundaries, not a simple reduction of
the whole call stack. The Python library grows 11,504 bytes to 4,679,816 bytes.
Full symbols, commands, hashes and assembly are retained.

Two assembly-capture assertions failed because the harness incorrectly expected
both versions to retain the same six collector symbols, then the same wrapper
symbol. Neither was an engine, compiler or functional-test failure. Original
capture scripts and successful partial dumps remain; the corrected collector
reuses all nine existing dumps and captures the actual wrapper. No successful
source build or functional suite was repeated for these harness corrections.

The candidate passes the unchanged **2,736 paired semantic scans** against the
exact original serial method; the frozen parent's success is reused by exact
source/test/archive identity. Broader checks pass **173 Mojo cases in 18 files**,
**10 crash-state cases in three files**, **369 Python cases**, and all three C
ABI stages. Python has three existing warnings and no skips. The body-preserving
annotation compiles with the installed Mojo 1.0.0 and M4/metal:4 target.

All **54 serial native workers** complete: warm 44.37 s, mixed 62.90 s. Original
corpora, filters, ef, plans, oracles, timing boundaries and rotating triples stay
fixed. Both versions pass quality **36/36** in both phases. All paired IDs,
Float32 bits, statistics and execution decisions agree; leases and reopen
oracles pass. All **18 cache payload pairs** are byte-identical with valid CRCs.
The expected mixed strict-gate exit occurs after all nine triples complete.

| Phase | Strict speed before → after | Pass → fail | Fail → pass |
| --- | ---: | ---: | ---: |
| Warm query | 22 → 21 / 36 | 2 | 1 |
| Mixed query | 33 → 33 / 36 | 0 | 0 |
| Mixed write+flush | 6 → 6 / 9 | 0 | 0 |

Warm loses uniform-1536 selective trial 2: QPS 9,446.38 → 9,210.34 versus
Qdrant 9,291.91. It also loses real-1536 selective trial 1: QPS
9,617.56 → 9,322.99 versus 9,485.16, and p95 113.083 → 145.042 µs versus
129.709 µs. Uniform-1536 selective trial 0 gains parity. All are retained;
planned-exact queries do not execute delta dispatch, so no direct cause is
assigned to those changes.

A per-query audit corrects the previous mixed path interpretation. Real
unfiltered warm queries all use graph search. In **each mixed trial**, 13 queries
use graph search and 59 use delta scan, in both versions. The fixed mixed all
ef is 32, versus warm ef 16: the **first 59 mixed queries scan**, then block 26
switches to graph as writes change physical source geometry. Earlier explanatory
prose had reversed that order; neither run changed its original plan or ef. The
earlier report now states this explicitly. The following
post-hoc subsets retain their original samples and are descriptive, not new
acceptance cells or independent trials.

| Experiment / real unfiltered mixed path | QPS after/before, trials 0 / 1 / 2 |
| --- | --- |
| Four-row / graph, 13 queries | .9627 / 1.0987 / .9988 |
| Four-row / delta scan, 59 queries | .9180 / .9056 / .8946 |
| Outlined dispatcher / graph, 13 queries | .8983 / .9566 / 1.0167 |
| Outlined dispatcher / delta scan, 59 queries | .9482 / .9686 / .9735 |

The previous four-row scan cohort slows **8.2–10.5%** in all three trials;
outlining slows that cohort another **2.6–5.2%**. This disproves an explanation
based solely on an unchanged graph branch. Outlining also does not consistently
retain the real filtered QPS gains. Only two of nine combined write+flush QPS
pairs improve; uniform-1536 trial-2 combined p95 regresses 10.0%. No write or
flush implementation changed, and no such optimization is claimed.

The [archive](2026-10-14-delta-dispatch-outline.json.gz) contains **871 files,
4,926,732 bytes**, with every embedded hash verified: full source/diffs, exact
tests and validations, both failed capture attempts and actual native code,
all worker observations, path subsets, cache-byte audits and parent/plan
references. No full CPU/crash-kill, native Linux, capacity, HTTP or GPU gate is
claimed. M5/M6 remain incomplete.

- Python SHA-256: `5186af69b4191379d0846347017301f7525e04979718548949cbd3e9d22a82d4`.
- C library SHA-256: `02050218cbf8e4006e48e9ca5dd84092656cc62c54c64ed7b8a308bae96f85af`.
- Archive SHA-256: `32ca23b002c6ec3ecac89e4344ce51d6889c40678b86bdc3115819fda8dceed9`.

Next measure the unchanged owned single-row and four-row kernels directly with
continuous and sparse row positions. The scan cohort regression needs a kernel
versus gather/admission/heap explanation before another production experiment.
No new query-setting or acceptance-threshold change is authorized by this result.
