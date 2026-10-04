# Checked visit argument narrowing

Isolated candidate after `a984c3f`; production engine remains `ac48cda` and
kernel `80ddc239…`. The [traversal audit](../research/2026-10-04-traversal-work.md)
found 8.6–9.6% of named selective query samples in visited marking. Production
machine code passes/returns fields from the whole scratch even though normal
visit only changes one epoch word. This observation is not a speedup estimate.

Move the existing checked `visit` body to a private helper taking only mutable
`List[UInt32]`, epoch, prepared slot count and slot. The existing method delegates
to that helper. Keep every check, error string, branch, word operation and all
other scratch methods unchanged. No annotation, unsafe pointer/span, cache,
new type, configuration, narrower epoch or allocation is added.

First build the copied binding with the project Mojo 1.0.0 / M4 / Metal wrapper
and compare actual caller/callee machine code. Stop this candidate if the compiler
does not materially reduce unrelated argument/return movement. Do not force
inline to obtain the desired result.

Then verify scratch/layer/group/inactive-radius regressions. Existing tests cover
unstarted scratch, zero slots, invalid ef/count, hidden retained capacity, UInt32
maximum slot and epoch wrap, growth, repeated visits and heap reuse. Reuse these
behavioral tests; no implementation-shaped test is needed for the helper itself.
If machine code and narrow correctness support further work, broaden affected
HNSW checks and perform original fixed public queries and named curves with full
ID/bit/stat audits. Record all raw trials, regressions and failed starts. Run
integration checks appropriate to adoption only after a useful public result.

Production remains unchanged until validation and an explicit engineering adoption
decision. Strict original Qdrant gates are per cell/trial, Recall@10 ≥ .95,
QPS ≥ Qdrant and p95 ≤ Qdrant; no A/B sample exclusion or cross-cell compensation.
Keep benchmarks serial with no build/test/compression overlap, and freeze sources,
logs, identities and measurements from `.build/2026-10-04-visit-arguments`.

## Completed candidate and adoption

The helper and its mapped filtered caller shrink in compiled machine code without
new annotations. All 110 affected Mojo tests, 506 full isolated Python tests,
C ABI/client and three rebuilt examples pass. The initial child wrapper missed
absolute `src` includes; its first 506-test pass is retained with that limitation.
The corrected wrapper remaps and logs all 12 original-source includes, and the
complete 506-test suite passes again. Do not add the two runs together.

All 18 named workers finish: 14,472 paired IDs/F64 bits/stats match, fixed quality
stays 132/216, and every low-recall cell remains. High-dimensional selective QPS
and p95 improve in all six selected trials; 12/36 selected cells nevertheless
have some timing regression. Original three-way gates remain FAILED: warm
18→19/36, mixed 24→27/36, write+flush 3→3/9, recall 36/36 each. Four performance
pass→fail cells remain recorded. These independent gates are not combined.

Adopted as a local improvement based on preserved behavior, smaller call/return
work and repeated gains in the profiled workload. This is not a claim of general
parity. Production receives the exact validated one-file source and Python/C
artifacts; 11 Mojo / 143 Python repeat checks and C loader/client / examples pass
on the promoted paths. Worker stays unchanged. No new full Mojo/crash, HTTP,
Linux, GPU, ASan or nonresident gate. M5/M6 remains incomplete.
