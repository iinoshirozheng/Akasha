# Mixed-query work and inactive delta history — 2026-10-04

Production `9bf69e0` is unchanged. Four new profiles and a 324-cell native history sweep support separating live-vector work from physical-slot inspection in the small-delta policy. This is diagnostic evidence for the [next isolated design](../plans/2026-10-04-delta-live-budget.md), **not an adopted policy or a new Qdrant pass**. M5/M6 remains incomplete.

## Current production profiles

The previous goal turn adopted combined cache encoding. Its complete original matrix remains warm 26/36, mixed 17/36 and write+flush 3/9 strict parity; matched recall passes. Real independent mixed QPS is 0.486–0.495 of Qdrant and p95 is 2.083–2.318 times Qdrant. Those original failures are not replaced by this investigation.

Four fresh closed-database clones execute all 32 original mixed blocks, with sampling inserted before blocks 0, 24 or 31. Each profile checks all 67 fixed queries against an evolving-state exact oracle and then repeats the 64 measured queries for seven seconds, with five seconds of native sampling. Every repeat matches that state’s reference IDs, F32 bits and all stats. The diagnostic timing interval includes result extraction and stats; it is not the acceptance timing boundary. The added replay also changes background-maintenance overlap, so it cannot establish the original tail-wait distribution.

Completed: **91,392 repeat audits**, 268 reference ANN audits, 268 exact-oracle checks, 1,152 original mixed query audits, four final reopen oracles and four retained Arrow leases. Every worker completes 32 write/flush blocks. No correctness failure or timeout occurred.

| Query / before block | Distance evaluations | Physical visits | Inactive rejections | Reranked | Mean thread CPU µs |
|---|---:|---:|---:|---:|---:|
| independent / 0 | 1769.86 | 2321.70 | 0.00 | 128 | 614.43 |
| independent / 24 | 1769.86 | 2513.70 | 192.00 | 128 | 616.72 |
| independent / 31 | 2473.48 | 2376.03 | 202.72 | 128 | 728.07 |
| selective / 31 | 249.59 | 249.59 | 0.00 | 10 | 109.95 |

Independent recall is .9859375 at all three states; selective recall is 1.0. Independent uses the fixed mixed ef64 and has no widening. Blocks 0/24 use delta scan; block 31 uses delta graph traversal after physical history crosses the bound. From block 24 to 31, average distance evaluations rise 39.76% and diagnostic foreground CPU rises 18.05%. The state and graph also evolve; this is not a controlled A/B performance claim.

| Exclusive query-boundary samples | Independent 0 | Independent 24 | Independent 31 | Selective 31 |
|---|---:|---:|---:|---:|
| Four-row distance | 36.14% | 38.72% | 42.01% | 0.00% |
| Single-row distance | 13.53% | 12.16% | 8.12% | 0.00% |
| Visit marking | 4.10% | 5.23% | 5.71% | 0.00% |
| Source + metadata admission | 3.27% | 3.52% | 2.60% | 0.00% |
| Checked scalar rerank/exact | 14.44% | 12.73% | 11.78% | 0.17% |
| Paired exact metric | 0.00% | 0.00% | 0.00% | 68.75% |

The parser subtracts child samples from each node and verifies totals against the main thread. It recognizes the adopted `_visit_epoch` helper and checked-pair metric by actual function names. Source/admission work remains a small share, so this evidence does not justify a new admission cache. HNSW distance work remains about half of ANN samples. Selective is a planned exact scan, dominated by its existing paired metric. No rejected kernel, raw-Span, prefetch, heap or prepared-rerank prototype was rerun.

## Controlled native history sweep

Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4. A copied source tree adds one explicitly invoked diagnostic scan method, copied from the current implementation without its policy-selection branch. Its validation, current/source checks, scalar scoring, heap and accounting remain. Production and its scan policy are unchanged. The first compile failed because the old probe used a positional generic argument; it was corrected to `backend_tag=backend`, with the original source/log/command retained. The corrected probe compiles.

Three original corpora supply the same 4,096-row vector tapes and 16-query tapes as the earlier native sweep, with hashes checked. Each fresh process builds 256, 819 and 1,024 live rows and replaces rows with the identical vectors to accumulate 0%, 25%, 50% and 100% extra physical history. Live values/IDs stay fixed. Every history state checks its physical/live counts. Efs are 10/32/128, three passes per query, graph/scan order alternates per query, and there are three fresh processes per corpus. Construction and query preparation are outside timing. This is a native delta-only cost probe, not public end-to-end or filtered performance.

All nine workers complete **15,552 graph/scan sample pairs** across **324 cells**. All scan ID orders equal independent NumPy Float64 top-10 oracles, across every history level. Scan recall passes in 324/324 cells; graph recall passes in 219/324 and all 105 failures are retained. Means, p95, every raw sample, IDs and distance counts are saved. Speed ratios are only reported when both algorithms meet .95 recall.

## Evidence for a bounded next policy

The proposed policy charges live rows for vector components, retains physical slots for traversal work, and limits physical history to max(1,024, twice the live count). Live rows stay capped at 1,024, so at most 2,048 headers are inspected; physical slots still cannot exceed ef×M0. It retains the 1,572,864 vector-component budget and requires a live base. No benchmark efs or user configuration change.

An offline predicate audit newly admits 72 sweep cells. Of these, 60 are matched quality and every one has lower scan mean and p95; the remaining 12 keep their graph recall failures and have no speed claim. Mean scan/graph ratios span 0.1639–0.9846; p95 ratios span 0.1648–0.8992. This predicate has not yet been implemented or publicly tested.

All three trial ratios for newly admitted groups follow; “low recall” preserves the excluded quality cells. Lower is faster.

| Corpus | Live / physical | Ef | Mean ratios 0 / 1 / 2 | p95 ratios 0 / 1 / 2 |
|---|---:|---:|---|---|
| uniform-128 | 819 / 1228 | 32 | 0.3244 / 0.3379 / 0.3361 | 0.3284 / 0.3607 / 0.3607 |
| uniform-128 | 819 / 1228 | 128 | 0.2064 / 0.2197 / 0.2179 | 0.1948 / 0.2292 / 0.2273 |
| uniform-128 | 819 / 1638 | 128 | 0.1735 / 0.1780 / 0.1639 | 0.1913 / 0.1944 / 0.1648 |
| uniform-128 | 1024 / 1280 | 32 | 0.3973 / 0.4061 / 0.3885 | 0.4068 / 0.4310 / 0.4138 |
| uniform-128 | 1024 / 1280 | 128 | 0.2630 / 0.2636 / 0.2508 | 0.2868 / 0.2794 / 0.2826 |
| uniform-128 | 1024 / 1536 | 32 | low recall / low recall / low recall | low recall / low recall / low recall |
| uniform-128 | 1024 / 1536 | 128 | 0.2314 / 0.2314 / 0.2251 | 0.2516 / 0.2532 / 0.2452 |
| uniform-128 | 1024 / 2048 | 128 | 0.1816 / 0.1847 / 0.1737 | 0.1959 / 0.2000 / 0.1762 |
| uniform-1536 | 819 / 1228 | 32 | low recall / low recall / low recall | low recall / low recall / low recall |
| uniform-1536 | 819 / 1228 | 128 | 0.3967 / 0.3982 / 0.3925 | 0.4024 / 0.4167 / 0.3944 |
| uniform-1536 | 819 / 1638 | 128 | 0.3077 / 0.3085 / 0.3084 | 0.3028 / 0.3129 / 0.3180 |
| uniform-1536 | 1024 / 1280 | 32 | low recall / low recall / low recall | low recall / low recall / low recall |
| uniform-1536 | 1024 / 1280 | 128 | 0.4865 / 0.4829 / 0.4821 | 0.4896 / 0.4919 / 0.4918 |
| uniform-1536 | 1024 / 1536 | 32 | low recall / low recall / low recall | low recall / low recall / low recall |
| uniform-1536 | 1024 / 1536 | 128 | 0.4190 / 0.4221 / 0.4161 | 0.4144 / 0.4342 / 0.4172 |
| uniform-1536 | 1024 / 2048 | 128 | 0.3228 / 0.3238 / 0.3177 | 0.3260 / 0.3324 / 0.3202 |
| real-1536 | 819 / 1228 | 32 | 0.7405 / 0.7492 / 0.7470 | 0.7143 / 0.7165 / 0.7054 |
| real-1536 | 819 / 1228 | 128 | 0.4185 / 0.4160 / 0.4108 | 0.4221 / 0.4073 / 0.4073 |
| real-1536 | 819 / 1638 | 128 | 0.3202 / 0.3233 / 0.3268 | 0.3249 / 0.3140 / 0.3239 |
| real-1536 | 1024 / 1280 | 32 | 0.9822 / 0.9772 / 0.9846 | 0.8908 / 0.8689 / 0.8992 |
| real-1536 | 1024 / 1280 | 128 | 0.5303 / 0.5211 / 0.5261 | 0.5277 / 0.5065 / 0.5232 |
| real-1536 | 1024 / 1536 | 32 | 0.8704 / 0.8812 / 0.8778 | 0.8296 / 0.7746 / 0.8015 |
| real-1536 | 1024 / 1536 | 128 | 0.4512 / 0.4527 / 0.4564 | 0.4416 / 0.4348 / 0.4505 |
| real-1536 | 1024 / 2048 | 128 | 0.3483 / 0.3482 / 0.3541 | 0.3435 / 0.3484 / 0.3437 |

The complete sweep also preserves scan regressions. For example, real 1,024-live/1,024-physical/ef10 has passing graph recall .95 but scan is slower; the existing physical ef×M0 condition excludes it. The previous 4,096-live/ef32 counterexample stays excluded by the live cap. No unconditional scan is proposed.

Local Qdrant `74f3e85` estimates scan vector work from available vector counts/bytes ([pinned source](https://github.com/qdrant/qdrant/blob/74f3e85b9473c62560006c043e13737ce6b48412/lib/segment/src/index/plain_vector_index/read_view/search.rs)); its source and hash are retained. This supports distinguishing live vector work, but does not supply Akasha’s numeric limits or prove its performance.

Next: implement the scoped predicate and overflow/behavioral cases in a fresh isolated tree, verify all native/owned/mapped/source/filter contracts, then rerun the unchanged complete public warm/mixed/Qdrant matrix. Actual changed paths/counters must be reported. There is no new full Mojo, Python, crash, C ABI, HTTP, Linux, GPU, ASan, nonresident or controlled-memory gate here. No Linux runner is available.

## Artifact identity and reproduction

Production Python SHA-256: `f33bdbf7734d2762450e9a5e9cb4234a46feee2a4b474907a9d6c3fb5ed2045d`. The production source and worker hashes are unchanged. The diagnostic probe is `cb3257bab1925be91f2add13914bdd1153a4975eb290c65cb0c6031eeced6b62`.

All profiles, builds and sweeps run serially, with no concurrent test/build/compression. Drivers create exclusive logs/fresh directories. Recover them into a fresh output tree and preserve recorded input/engine/compiler identities; do not rerun writing drivers over frozen evidence. `profile.py`, `build-sweep.py` and `history-sweep.py` retain exact RTK command arrays and environment. `parse_sample.py`, `summarize.py` and the JSON summaries describe the analysis.

[Immutable archive](../benchmarks/results/2026-10-04-mixed-query-work.json.gz): `a41b054f0390deabfee7e33c3abb81716173c3d10219722d91b976ff9649cbbb`, 177 text entries, 1,895,666 bytes. Every embedded text hash was verified after decompression. Config bytes are embedded as hex; large vector tapes/databases/binaries are represented by hashes.
