# HNSW single-probe dictionary lookups — not adopted

Two isolated variants replace three contains-then-subscript patterns with the
existing `Dict.get(key, default)` API. Both pass **40 affected Mojo cases and
369 Python tests**, preserve every measured result and statistic, and complete
all **54 native warm/mixed workers**. Neither is adopted: the first retains
three mixed pass→fail cells; preserving the original admission call boundaries
retains six warm/mixed pass→fail cells. Production remains `96e05e2c…` and
M5/M6 remain incomplete.

## Evidence and implementation

The production `HnswEligibility.allows` assembly contains two successive table
probe loops: one checks membership and the other retrieves the ordinal. The
[official Mojo 1.0.0 dictionary source](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/collections/dict.mojo)
provides `get` with a default through one lookup. The current documentation
index is already 1.1.0, so this experiment uses the pinned 1.0.0 source and the
project's installed compiler. The downloaded source hash is
`0833323f7c56cf343d83176d4ace3d11badbc0596ee8ada6dc11fd8a2ec7a428`.

The first variant, `.build/m5-resume/hnsw-single-lookup`, changes only:

- `HnswIdOrdinalLookup.ordinal_for`: preserve missing ordinal `-1`.
- `HnswEligibility.allows`: fetch the ordinal once; preserve missing-ID rejection.
- `_CurrentSourceLookup.source_for`: preserve missing source `0`.

Stored ordinals are already validated nonnegative. Source values remain a
positive base slot plus one or delta `-1`; public IDs may still be negative or
zero. There is no cache, new state, package, format, graph or query change.

Both admission methods become inlined in the first binary. The separate
`.build/m5-resume/hnsw-single-lookup-outlined` variant adds `@no_inline` only to
`HnswEligibility.allows` and `_SourceAdmission._allows_item`, preserving their
previous call boundaries. Its emitted eligibility method shrinks from 560 to
492 bytes (140 to 123 instructions); the source method shrinks from 560 to
440 bytes (140 to 110 instructions). A further source-method `_REMOVED_ARG`
clone also has 440 bytes. These are code-generation observations, not evidence
that inlining caused the measured regressions.

The initial assembly script assumed one symbol per method and rejected the
compiler-generated clone. Its failure and original script are retained. The
corrected script inspects every matching symbol. It does not rebuild or alter
the measured binary.

## Validation and complete comparisons

Each variant freshly passes filtered HNSW (8), segmented HNSW (18), delta scan
(5), mapped graph view (9), and all 369 Python cases. Existing tests cover
missing/negative/zero IDs, ordinal validation, bitmap translation, source
replacement/delete/reinsert, historical bridges and mapped/owned readers.
No new implementation-mirroring tests were added. Each compiler audit contains
19 invocations with every project source argument routed to the isolated copy.

Each full experiment uses the frozen three corpora, three rotating
before/after/Qdrant triples per phase, fixed ef/K/filters/oracle and original
timing boundaries. Builds, tests, benchmarks and compression are serial. IDs,
F32 score bits, stats and execution match on every paired query. All reopened
exact-oracle and retained Arrow lease checks pass. No slow trial is excluded.

| Variant / phase | Quality before / after | Strict speed before / after | Pass→fail / fail→pass |
| --- | ---: | ---: | ---: |
| Get / warm | 36/36 / 36/36 | 19/36 / 23/36 | 0 / 4 |
| Get / mixed | 36/36 / 36/36 | 22/36 / 19/36 | 3 / 0 |
| Outlined / warm | 36/36 / 36/36 | 30/36 / 27/36 | 3 / 0 |
| Outlined / mixed | 36/36 / 36/36 | 20/36 / 21/36 | 3 / 4 |

Each row has its own contemporaneous baseline. Counts cannot be compared
between experiments or used to offset failing cells. Strict speed requires
both QPS ≥ Qdrant and p95 ≤ Qdrant after Recall@10 ≥ .95. Both variants' mixed
write+flush gates remain 3/9 before and after.

All pass→fail cells remain outstanding:

| Variant / phase | Corpus, mode and zero-based trial |
| --- | --- |
| Get / mixed | uniform-128 selective 0 and 1; real all 1 |
| Outlined / warm | uniform-128 selective 0 and 1; real all 2 |
| Outlined / mixed | uniform-128 all 2 and correlated 2; real selective 1 |

The get-only version improves real warm correlated and independent QPS in all
six pairs, but that gain does not persist in mixed queries. Selected real
ratios below are medians with the complete three-trial range.

| Variant / phase / mode | QPS after/before | p95 after/before |
| --- | ---: | ---: |
| Get / warm / correlated | 1.033 (1.015–1.038) | .934 (.912–.979) |
| Get / warm / independent | 1.025 (1.012–1.054) | .966 (.952–1.010) |
| Get / mixed / correlated | .999 (.995–1.009) | 1.020 (.965–1.037) |
| Get / mixed / independent | .988 (.985–1.008) | 1.027 (.990–1.088) |
| Outlined / warm / correlated | 1.024 (.980–1.105) | 1.000 (.947–1.083) |
| Outlined / warm / independent | 1.029 (1.022–1.049) | .915 (.896–.930) |
| Outlined / mixed / correlated | 1.049 (.964–1.054) | .968 (.908–1.017) |
| Outlined / mixed / independent | 1.039 (.949–1.043) | 1.044 (.990–1.070) |

Other regressions are also retained. Get-only mixed uniform-128 selective QPS
is .872/.781/.717 of baseline, and its real all-mode QPS is .964/.941/.950.
Outlined mixed uniform-128 independent QPS is .901/.850/.898. The cause of
variation on unchanged exact paths is not established; those samples are not
reclassified as successful or discarded.

## Frozen evidence and limits

Get-only Python SHA-256:
`78c6765869e1d5e37270137f936cd05c3023697562f378c78a1e40706c729b21`.
Outlined Python SHA-256:
`6dcb59635de2839501032d0d28b8beb6d792315f5ace11655c0b88ae23ba3f88`.
Production source bytes and Python SHA-256 remain unchanged:
`96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c`.

The [raw archive](2026-10-14-hnsw-single-lookup.json.gz) retains both complete
sources/deltas, upstream API evidence, commands, hashes, assembly, compiler
audits, tests and all 108 native workers. Mixed driver exits of 1 represent
failed strict gates after all workers completed. There is no fresh Linux,
capacity, C ABI, crash or GPU validation for these unadopted variants.
Archive: **1,515 files, 7,737,599 bytes**, with every embedded hash verified.
SHA-256: `9e2398eaaf9006233d265136fe32e0aa9c53c94691719a64939d0ca0494545f3`.

Return to the dominant mapped scoring and adjacency data-access costs before
another dictionary variation. The prior mapped-ownership, HTTP, nonresident
and native-Linux performance requirements remain unresolved.
