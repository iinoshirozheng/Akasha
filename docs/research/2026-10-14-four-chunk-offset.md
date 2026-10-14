# Grouped mapped chunk checks — not adopted

The [filtered ANN samples](2026-10-14-filtered-ann-native-sample.md) identified
mapped four-row HNSW scoring as 33–35% of main-thread top-of-stack observations.
Its emitted SIMD iteration contained four separate range guards. This isolated
experiment groups the four copied loads while keeping the mapping closed-state
check, every range bound and the original distance arithmetic.

The parent is production `96e05e2c`, without mapped authority. Only
`hnsw_view.mojo` and `mapped_file.mojo` change. No pointer escapes the mapping
operation, and no query, slot, finite-value or durable validation is removed.
Owned graph kernels, other scalar backends and the existing scalar tail remain
unchanged. Neither revision below is adopted.

| Revision | Mac binary SHA-256 | Validation | Measurement |
| --- | --- | --- | --- |
| Initial four-offset bounds | `ac4f3bd3f4538b74cdebead7486ef9c9eb95811f37ab6d21b54800248e3a720e` | 70 Mojo, 369 Python | Assembly only |
| Explicit common offset | `0222c55c628aae080f5d7f26f14d3208580ac5971994da196a2c06b5911c3f9c` | 70 Mojo, 369 Python | Complete 54-worker warm/mixed matrix |

The initial method checks the minimum and maximum of four complete byte offsets.
It passes the new tests, but emitted min/max compare-selects remain inside every
SIMD iteration. That source, binary, tests and assembly were frozen before any
whole-query timing; a separate revision makes the common relative offset explicit.

For chunk width in bytes `B`, mapping length `L`, relative offset `O`, and fixed
row bases `b0…b3`, the final method checks:

```
mapping is open
min(b0…b3) >= 0
O >= 0
B <= L
O <= L - B
max(b0…b3) <= L - B - O
```

Each `bi + O` load is therefore bounded without overflowing the addition. The
method returns four copied SIMD values. Original independent accumulators,
widths, reduction order and scalar tails are retained. The compiler hoists the
fixed min/max operations: the cosine SIMD loop drops from **61 to 54
instructions**, retaining 16 vector FMAs. Symbol size changes 2,068→2,032 bytes.
This is a code-generation observation, not a measured speed gain.

Four new tests first fail because the method is absent, then pass. They cover
unaligned/repeated groups, each position's negative/Int.MIN/Int.MAX/truncated
range, empty mappings, closed-owner error precedence, copies surviving close,
and relative-offset boundaries. The nine existing relevant suites contribute
66 cases, including all three metrics, 14 dimensions, owned/mapped bit agreement,
slot bounds, graph close, search ordering, dispatch, stats and filtering. Each
revision also passes the complete current 369 Python tests with its own rebuilt
extension. These are 70 cases per revision, not 140 distinct cases. Compiler
arguments and source/binary identities are retained. No Linux, C ABI or new
capacity check was run for the rejected optimization.

All 54 workers in the final fixed comparison complete. The parent remains
`96e05e2c` throughout; fixtures, efs, K=10, plans, timing boundaries, oracles and
the three rotating triples per corpus are unchanged. All IDs, F32 score bits,
stats and execution choices match. Mixed reopen and Arrow lease checks pass.

| Phase | Quality, each version | Parent strict speed | Candidate strict speed | Pass→fail | Fail→pass |
| --- | ---: | ---: | ---: | ---: | ---: |
| Warm | 36/36 | 21/36 | 21/36 | 4 | 4 |
| Mixed | 36/36 | 19/36 | 22/36 | 1 | 4 |

Warm pass→fail cells are selective uniform-128 trial0, uniform-1536 trials0/1,
and real-1536 trial1. Mixed retains a selective uniform-128 trial0 pass→fail.
Every one remains a failure; additional passes do not offset them. These exact
cells do not execute the changed kernel, so the cause of their fluctuations is
not established. None are excluded. Write+flush stays3/9 for each version.

The intended real filtered ANN paths also lack a consistent gain: warm correlated
QPS ratios are1.027/1.014/.876 and independent .979/.984/1.014. Their p95 ratios
are1.027/.977/1.165 and .962/1.063/1.019. Mixed retains both faster and slower
trials. Reduced instruction count alone does not justify adoption. Production
source and both Python/C artifacts remain unchanged; M5/M6 remains unresolved.

Next separate base-graph scoring from delta scans before selecting a traversal
change. `search_layer` scores first-seen graph bridges before result admission;
the delta scan filters before distance calculation. The merged public rejection
counter cannot be interpreted as a fraction of wasted graph scoring. An isolated
counter diagnostic at the existing source-merge boundary can answer this without
changing traversal. It must preserve the frozen query results and is not a
performance gate.

[Both source revisions, all validation, assembly and the complete fixed matrix](2026-10-14-four-chunk-offset.json.gz)
contain952 files and4,200,001 compressed bytes. SHA-256:
`7dd8f4a30d90d4b1f4bf7c9bc37b94fb450a989c44de91ae20c871f310ad198a`.
The archive and every embedded file hash were verified.
