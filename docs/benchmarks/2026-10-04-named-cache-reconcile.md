# Named cache reconciliation: isolated lifecycle evidence

The named cache candidate is **not adopted**. It makes the first query after
updates/reopen about 6–7 times faster, but initially regresses three fixed-ef
recall cells and 28/36 selected warmed timing cells. A separate filtered-search
radius correction removes those recall regressions on byte-identical saved
graphs; it still has 20/36 timing regressions against the first candidate.
Neither cohort is a Qdrant parity result. M5/M6 remain unfinished.

Production source remains `3a5ad04`, with Python kernel SHA-256
`53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6`.
The evidence starts from `0d33b19` and follows the
[reconciliation design](../plans/2026-10-04-named-cache-reconcile.md).
No production source or binary changed in this experiment.

## Candidate and correctness

The isolated implementation introduces optional AKIC kind 5 with an explicit
field identity prefix. A writer may save its ready base graph despite later
runs/head. On reopening, a private decoded graph is reconciled against current
authority using existing delete/upsert/rebuild-policy operations, then checked
for complete live ID and prepared-vector coverage. Exact source-key matches
remain strict: a wrong graph is rejected, not repaired. Kind 4 remains a
recognized envelope but is a safe miss for this field loader. Authority formats
are unchanged. Queries and snapshots never publish cache files; writer locks
retain their nonblocking, one-attempt protocol.

Current graph slots replace the previous dense-only ID/ordinal assumption.
Admission masks include inactive slots, and native rerank reads current rows.
Tests cover native F32/F16/BF16/I8/U8 with supported graph codecs and metrics,
field absence, changed IDs/ordinals, snapshots, all-deleted and rebuild thresholds,
CRC-correct wrong graphs, cancellation/retry and busy/failed publication.

Two baseline assertions fail as expected: no cache publication with a later head,
and no stale-cache reuse after updates/deletions. The first candidate passes both
and **115 unique targeted Mojo, 11 related crash, 388 full Python, C ABI/client,
and three rebuilt examples**. These are not a full Mojo/crash integration run.
The first candidate kernel is
`5e45df4f26f177243fa8a20f51b23a8d7a084c079207064c97ea0d88b99a96a6`.

All initial failures remain archived: a validation driver referenced a nonexistent
test after six successful files; an extended test initially called nonexistent
`VectorValue.copy`; and a blanket full-K no-fallback assumption failed. The latter
was diagnosed with fresh controls: 20 Dot native/codec combinations already
exhaust full K=18 on freshly built graphs (12 or 9 candidates), while repaired
graphs return 13 or 9. Final tests retain that limitation, verify no new exhaustion
relative to controls, exact full-result oracles, and no fallback at K=7 across all
55 combinations. The performance workload's K=10 and ef grid were never changed.

## Original lifecycle cohort

All 18 serial workers completed: three corpora × three trials × two versions,
AB/BA/AB, fresh databases. Inputs remain 8,192 initial points, 819 updates,
205 deletions, original seeds, filters, K=10, 67 queries per mode and six ef values.
Initial/pre-close results, F64 score bits and stats agree across versions. Reopened
graph topology can differ, so every result is checked against live-ID/filter,
recall and independent F64 score oracles instead of requiring identical ANN IDs.

The cohort passes 28,944 ANN audits and 4,824 exact ID checks. Of 14,472 paired
queries, 9,585 have identical IDs and none have identical stats; all 131,586 common
ID score-bit comparisons agree. Cache CRC/header inspection confirms actual
reconciliation (inactive historical slots remain), and a second reopen preserves
the first reopen's IDs, bits and stats.

First query after update/reopen, milliseconds, with every trial retained:

| Corpus | Trial 0 before → candidate | Trial 1 | Trial 2 |
| --- | ---: | ---: | ---: |
| uniform-128 | 6,978.98 → 991.99 | 7,225.01 → 954.85 | 7,027.54 → 988.83 |
| uniform-1536 | 33,347.20 → 4,959.28 | 34,753.11 → 4,905.77 | 33,175.92 → 4,975.61 |
| real-1536 | 18,062.82 → 2,850.66 | 17,483.60 → 2,841.62 | 17,494.37 → 2,946.66 |

This saving has costs. Updated flush increases in all nine trials: uniform-128
25.40/25.91/43.56 → 78.46/78.44/80.50 ms; uniform-1536
60.23/114.36/65.10 → 213.26/205.39/183.94 ms; real-1536
72.46/62.97/58.04 → 203.16/208.40/205.44 ms. The second reopen's first query is also
slower in every trial. Initial graph building remains approximately 7/34/18 seconds.

Fixed-ef recall passes fall from **132/216 to 129/216**. All three regressions are
uniform-128 independent at ef=128: .95 → .934375. Every mode/trial can still reach
.95 somewhere on the unchanged grid, but that does not erase the regressions.
At each version's own first passing ef, **28/36** cells regress in QPS or p95.
All 216 fixed comparisons and first-common-ef diagnostics are in the archive.
`lifecycle-summary.json` correctly reports `QUALITY_REGRESSION` and exits 1.

## Filtered traversal radius defect and isolated refinement

The lifecycle work exposed an existing HNSW inconsistency: filtered search retained
inactive slots in its navigation radius, whereas unfiltered search excluded them.
At ef=1, an all-true filter could return nothing or stop before the nearest live
node when an entry/middle node had been deleted or replaced. Three deterministic
chain tests fail on production and pass with the isolated fix. The initial test
compile's Float64/Float32 conditional-literal error and corrected run are retained.

The refinement changes only the filtered navigation heap to retain current slots;
inactive slots remain traversable, while metadata-disallowed current slots still
contribute to the radius. It passes **128 unique targeted Mojo and 388 full Python**.
This refinement did not rerun C ABI/examples/crash or full Mojo; their earlier
results must not be relabeled as testing this binary. Its kernel is
`d439f24396e3e9a6b6963ae4c361e80820d6a37fadf62c0c348cd6d1df2dc5df`.

A second complete 18-worker cohort clones the exact saved reconciled graph for
both versions, checks its SHA before/after queries, and uses the same original
queries/filters/K/efs. The first-candidate results/bits/stats reproduce its first
cohort exactly. Both versions together pass 28,944 ANN audits and 4,824 exact ID
checks; 12,804/14,472 paired ID lists and 3,957 stats match, and all 142,221 common
ID score-bit comparisons agree.

Fixed recall passes improve **129/216 → 135/216**, with six fail→pass and zero
pass→fail. Relative to the original rebuilt graph there are no remaining
pass→fail cells. Uniform-128 independent ef=128 becomes .9578125 in all three
trials; correlated also reaches .95 at ef=128 instead of 256. Every mode/trial
reaches .95 on the original grid. Nonetheless **20/36 selected timing cells**
regress relative to the first candidate. `TARGET_REACHED` in this diagnostic
means its recall criterion only; it is not an M6 performance pass.

The next step is to validate this one-file search correctness fix independently
of cache reconciliation, including the original default warm/mixed boundaries.
The larger cache candidate remains isolated pending its performance decision.
There is no new HTTP, distributed, sustained-nonresident, memory-limit, Linux,
GPU or ASan result here. No available native Linux runner has been assumed.

## Immutable evidence and reproduction

[Text evidence archive](results/2026-10-04-named-cache-reconcile.json.gz):
**777 entries / 10,661,316 bytes**, SHA-256
`c59c1d3dc99b376b887d29cb52033058a3709ab95c6083af133a4b4319dde1f3`.
Gzip readback and every embedded file hash were verified. It includes copied
source/package files, regression cases, original failed attempts, commands,
validation logs, specs/oracles, binary/source identities and every timing sample.
Compiled binaries and database/corpus payloads are identified by hashes rather
than embedded; the existing fixed `cost-plan-*` workload files remain the inputs.

The temporary workspace is `.build/2026-10-04-named-cache-reconcile`.
Mojo is 1.0.0 (`ed45d567`), target Apple M4 with the existing Metal:4 wrapper.
`before-src`, `after-src` and `live-radius-src` and their Python packages are
separate. Child compiles inherit the isolated wrapper and `.build/compiler-bin`;
pytest uses `-o pythonpath=` plus import-path/kernel-hash guards. Production kernel
and native worker hashes remain unchanged.

Read the saved drivers before reproducing in a new output directory. The writing
drivers intentionally refuse existing outputs; do not overwrite frozen samples.
Relevant driver names are `baseline.py`, `candidate-first.py`, `phase1.py`,
`phase2-retry.py`, `extended-coverage.py`, `phase3.py`, `python-tests.py`,
`postvalidate.py`, `lifecycle.py`, `live-radius-test.py`, `live-radius-validate.py`,
`live-radius-python-tests.py` and `live-radius-curves.py`. Saved logs retain exact
commands and exits, including the repaired harness errors.

Read-only reassessment of completed local reports:

```sh
rtk proxy python3 .build/2026-10-04-named-cache-reconcile/summarize-lifecycle.py
rtk proxy python3 .build/2026-10-04-named-cache-reconcile/summarize-live-radius.py
```

The first exits 1 for retained recall regressions; the second exits 0 for the
fixed-graph recall diagnostic. Neither alters production or marks M5/M6 complete.
