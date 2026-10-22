# Full mixed profiling does not reproduce the source-specialization regression

Keep deferred-ID and the [static-source rejection](2026-10-22-immutable-point-static-source.md).
The new full-plan captures and subsequent unsampled controls do **not** reproduce
the earlier 7–10% filtered CPU increase. They cannot identify its causal hotspot
or justify adopting the rejected candidate. The last strict mixed result for
retained remains **21/36**, production remains `a6822c3`, and every outstanding
M5/M6 gate remains open.

## Protocol and identity

Four serial 45-second macOS `sample` captures use a requested one-millisecond
interval. Retained/candidate order reverses in the second pair. Each worker
replays **eight complete frozen uniform-1536 mixed plans**, each on a fresh
database clone: all 32 blocks, 288 measured queries, interleaved updates/flushes,
retained Arrow lease, close and exact reopen. No native code is rebuilt or
instrumented. The Python measurement module is byte-identical to the prior
CPU/resource diagnostic and adds that diagnostic overhead.

The controller waits for the sampler's startup message before releasing the
worker. Every complete eight-plan window finishes within **15.65–16.21 seconds**,
before even the sampler's earliest possible 45-second deadline. Workers remain
alive until capture completion. Setup, warmups, writes, reopens and idle time
are present in the complete capture; these are not continuous-query profiles.

All **9,216 sampled-plan responses, 32 reopens and 32 leases** match retained.
The **96 warmup returns are not compared**. Repeated plans are diagnostics, not
independent acceptance trials. Native import identity is checked in each worker:

- Retained: `64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`.
- Candidate: `9150ec4049864cd20e1e22c65cf38f70caf686e53beb4e80c5c8b51d72ffb1d9`.

Both 132-file source inventories match their existing verified archives. Plans,
workloads and native binaries remain unchanged.

## Stack analysis and limits

The analyzer resolves **4,674 non-stub native frame records** against the exact
binary's symbol table and verifies every displayed PC/function-offset pair.
Full mixed captures expose more truncated Mojo names than the previous
two-query profiles: file/write generics can begin with `$1]]`, not just
`::AnyType`. The first parser stopped before output on that case. A second
attempt stopped on the candidate's explicit `Main Thread` label rather than
`com.apple.main-thread`. Both failed script versions and their corrections are
preserved; neither failure caused a worker restart.

Exclusive counts subtract immediate children; they sum exactly to each thread's
root count. Visible function ancestry identifies the mapped filtered search
subtree. Inlining and tail calls remove some other boundaries, so this is **not
an exhaustive accounting of base/delta/rerank phase time**. In particular,
unclassified collection frames and authoritative scoring outside visible
rerank frames are retained, not reassigned by guesswork.

The following percentages use only each capture's visible mapped filtered
search subtree as its own denominator:

| Capture | Observations | Mapped four-row | Mapped single-row | Source admission | Metadata | Search-loop self | Scorer self | Heap |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| First retained | 886 | 20.99% | 19.30% | 8.80% | 10.38% | 16.59% | 7.79% | 11.17% |
| First candidate | 863 | 18.42% | 22.25% | 5.56% | 10.43% | 18.08% | 6.95% | 12.86% |
| Reverse candidate | 786 | 18.45% | 21.12% | 7.00% | 11.20% | 16.92% | 7.76% | 11.70% |
| Reverse retained | 791 | 17.45% | 19.85% | 8.34% | 11.13% | 17.45% | 7.46% | 11.76% |

Admission share is lower in both candidate captures, but these small sampled
counts and changing denominators do not measure elapsed savings. Other group
shares move in different directions. The originally observed regression is
absent during capture, so none of these shifts explains its cause.

## Unsampled control and contradictory observations

Across the sampled plans, candidate/retained calling-thread CPU ratios are
**.9760/.9775** for first-order correlated/independent and **.9815/.9783** in the
reverse order. Every one of the eight corresponding per-plan filtered CPU
ratios is below one. This is the opposite direction from the previous diagnosis.

To distinguish sampling/repeated-plan effects from a currently unreproduced
regression, four further fresh processes run the previous **single-plan** CPU
protocol in both orders with no external sampler. Its worker and measurement
module are byte-identical to the earlier archived diagnostic. All **1,152
responses, four reopens and four leases** match; 12 warmup returns are not compared.

| Mode | First-order wall / thread CPU | Reverse-order wall / thread CPU |
| --- | ---: | ---: |
| all | .9740 / .9743 | 1.0004 / 1.0003 |
| correlated | .9561 / .9648 | .9959 / .9959 |
| independent | .9633 / .9634 | .9867 / .9867 |
| selective | .9891 / .9889 | 1.0247 / 1.0245 |

The unsampled control also fails to reproduce the earlier filtered increase;
sampling alone is therefore not an established explanation. Candidate
correlated mean CPU was about **1.320/1.362 ms** in the previous two single-plan
runs and is **1.212/1.206 ms** now. Candidate all-mode means remain near **2.43 ms**
in three of those four observations. These comparisons locate the changed
observation; they do not identify CPU frequency, address placement, cache,
scheduling, memory pressure or another mechanism as its cause.

Preserve both contrary datasets. Do not promote the candidate from this
diagnosis, erase its earlier full-comparison regression, or tune source code
against an unestablished hotspot. The reference remains pinned Qdrant's
filter-before-cap, reusable scoring buffer and internal-point checks. No new
Qdrant comparison or claim of equivalent work is made here.

Further performance work needs a reproducible failing execution under controlled
conditions before another local source edit. Meanwhile, the existing adoption
requirements still require verification of every candidate read consumer and
compiler include path; native binding identity alone does not prove that a
Python test's child Mojo compiler used the candidate source.

## Evidence

The [verified archive](2026-10-22-immutable-point-full-mixed-profile.json.gz)
contains **108 text artifacts, 2,845,584 bytes**, SHA-256
`fd4dd6bcfa1c3acb9aa6e23157a2362073e597513d9d7ac47b4a677fc26b142b`.
It includes all raw captures, symbol tables, 36 complete-plan reports, previous
CPU reports, baseline, native/source identities, controller records, failed and
corrected analyzers, pinned reference source/license and reproduction scripts.
The source archive chain is verified; binaries/databases are not embedded.

Independent archive-only replay exactly reproduces both the symbol analysis and
the evidence audit: **10,368 exact responses, 36 reopens, 36 leases**, capture
boundaries and all CPU summaries. **108 warmup returns are not compared**. All
108 artifact hashes verify. No product source changes or broad acceptance
claims are part of this diagnosis.
