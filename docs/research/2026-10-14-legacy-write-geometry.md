# Legacy write geometry and an unsuccessful pair cache

Two instrumented diagnostics locate most ordinary legacy write time in HNSW
insertion, especially adjacency planning and pruning. An isolated ordered-pair
distance cache passes **115 Mojo / 369 Python cases** but slows writes in all
nine fixed comparisons. It is **not adopted**. Its 54 native workers retain
seven query pass→fail cells; write+flush changes from 6/9 to 5/9 in this cohort.
Production remains `96e05e2c…`; M5/M6 remain incomplete.

## Locate the cost

The [bounded batch implementation](../plans/2026-10-02-bounded-batch.md) already
stages only affected IDs and publishes after one WAL envelope is synced. It does
not clone the whole MemTable. All three workloads use the legacy route, not the
typed PointStore branch.

The first diagnostic adds nested timestamps around binding conversion,
collection stages, WAL encode/append-sync, and HNSW insertion. Each corpus runs
one serial production/diagnostic pair with the original mixed plan: 32 blocks,
nine reads then eight upserts and flush per block. All 864 paired queries match
IDs, Float32 score bits, stats and execution decisions. Retained Arrow leases
and exact reopen oracles pass. There are 96 batches and 768 insertions.

Median times in milliseconds:

| Corpus | Conversion | Batch | HNSW | WAL encode | Append/sync | Insert search | Insert select | Insert connect |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Uniform 128 | .023 | 6.601 | 6.411 | .011 | .1245 | .1785 | .025 | .5815 |
| Uniform 1536 | .131 | 23.8465 | 23.4695 | .036 | .185 | .321 | .169 | 2.3705 |
| Real 1536 | .131 | 16.4275 | 16.0715 | .037 | .204 | .3595 | .104 | 1.486 |

Aggregate HNSW shares of batch time are 97.33%, 84.87%, and 97.91%; connection
shares of insertion time are 73.41%, 82.05%, and 75.06%. Uniform 1536 includes
an **append/sync interval of 141.251 ms**, retained in all totals. This measures
the whole append/sync helper, not an isolated fsync syscall; its cause is
unestablished. Nested intervals and medians cannot be added together.
Instrumentation/output perturb timing: these results locate costs and do not
establish performance acceptance or an uninstrumented cost census.

The second diagnostic retains those clocks and divides `connect_bidirectional`
into setup, adjacency copies, planning/pruning, publication and touched-level
validation. Another six workers preserve all 864 query pairs and both
lifetime/reopen checks. Each corpus records 267 connection calls. Aggregate
fractions of connection time are:

| Corpus | Setup | Copy | Plan/prune | Publish | Validate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Uniform 128 | .37% | 5.38% | 41.62% | 18.57% | 33.57% |
| Uniform 1536 | .10% | 1.42% | 83.75% | 5.18% | 9.42% |
| Real 1536 | .17% | 2.26% | 74.83% | 8.06% | 14.47% |

The fractions leave timestamp/control overhead. High-dimensional geometry is
the next target; reciprocal validation and failure quarantine remain required.

## Cache implementation and validation

Starting from frozen production without diagnostic clocks, only
`hnsw_core.mojo` changes. An existing Mojo `Dict[UInt64, Float32]` caches ordered
`(lhs << 32) | rhs` keys within one connection call, covering center/member
scoring and internal pruning. Its lifetime ends before the next connection;
vectors and dispatcher are fixed within it. Ordered keys do not assume
quantized symmetry. Public selection stays uncached. There is no approximate
arithmetic, graph ordering, query setting, format or dependency change.

The pinned Mojo 1.0 dictionary confirms `get` returns Optional. Local Qdrant
`graph_layers_builder.rs` at `74f3e85b9473c62560006c043e13737ce6b48412` reuses
ItemsBuffer across backlinks. This informs the temporary lifetime, not a claim
that Qdrant caches distance pairs. Both references are archived.

One new equal-distance rejection case fails on production: eight actual
computations instead of seven. The candidate passes with seven; a second call
adds seven again, proving cache lifetime does not cross calls. Adjacencies stay
unchanged and symmetric. Along with links, selection, invariants, mutation,
quantized, segmented, store, filtered and overlay coverage, **115 cases in ten
Mojo files pass**. All **369 Python tests pass**, with three existing warnings
and no skips. Build stats count actual computations; query stats stay exact.

The uninstrumented candidate completes **54 workers**: three rotating
production/candidate/Qdrant triples per corpus for warm and mixed phases. Fixed
ef, K, filters, corpora, plans and timing boundaries are unchanged. Every paired
ID, score bit, stat and execution decision matches; mixed lease/reopen checks pass.

| Phase | Quality before / after | Strict speed before / after | Pass→fail / fail→pass |
| --- | ---: | ---: | ---: |
| Warm | 36/36 / 36/36 | 26/36 / 24/36 | 3 / 1 |
| Mixed | 36/36 / 36/36 | 22/36 / 21/36 | 4 / 3 |

Strict speed requires QPS ≥ Qdrant and p95 ≤ Qdrant after Recall@10 ≥ .95.
Zero-based query trials changing from pass to fail:

- Warm: uniform-1536 correlated 0; real-1536 correlated 0 and all 2.
- Mixed: uniform-128 all 0 and correlated 1; uniform-1536 selective 0;
  real-1536 selective 0.

Write-only candidate/production QPS ratios are below one in every pair:

| Corpus | Trial 0 | Trial 1 | Trial 2 |
| --- | ---: | ---: | ---: |
| Uniform 128 | .6722 | .5857 | .7446 |
| Uniform 1536 | .6345 | .8706 | .8897 |
| Real 1536 | .9022 | .9277 | .8859 |

Akasha write acceptance includes WAL sync; Qdrant update durability completes
through separate flush. Combined write+flush is the matched durability gate:
**6→5/9**, losing uniform-1536 trial 0. That candidate's flush p95 is 221.488 ms
and combined p95 is 275.985 ms. Slow Qdrant flushes also remain. Their causes
are unestablished; no outlier or failed cell is removed. Counts from another
cohort cannot establish improvement here. The mixed driver exits 1 after all
nine triples finish because strict gates fail.

## Actual cache reuse

A counter-only build adds one output per connection. Three new workers reuse
the still-applicable frozen production controls from the link diagnostic,
without claiming cross-run speed comparison. All 864 query pairs, leases and
reopen oracles match. Ordered dimension/endpoint/level/proposal tuples match
all 801 earlier connections; computations equal cache entries in every call.

| Corpus | Logical comparisons | Actual computations | Hits | Hit fraction | Maximum entries per call |
| --- | ---: | ---: | ---: | ---: | ---: |
| Uniform 128 | 3,423,457 | 3,365,499 | 57,958 | 1.693% | 17,993 |
| Uniform 1536 | 4,457,137 | 4,390,345 | 66,792 | 1.499% | 24,429 |
| Real 1536 | 2,274,841 | 2,164,102 | 110,739 | 4.868% | 12,645 |

Few computations are eliminated while thousands of pairs are stored. Together
with nine slower writes, this rejects the cache. Do not add thresholds or
symmetric keys without new evidence. Next inspect batching of already-required
center/member scores during adjacency overflow, using existing four-row F32
arithmetic. Early-exit diversity tests must not gain speculative computations.

## Frozen evidence

The [archive](2026-10-14-legacy-write-geometry.json.gz) contains **1,268 files,
21,248,459 bytes**: four full source trees, production originals, patches,
references, scripts, build identities, tests, raw counters, all **69 workers**,
latencies and failed gates. Every embedded hash and each build's full Mojo
source inventory/binary hash were checked. Production source/binary match the
frozen parent. External fixed corpora remain at their original local paths,
identified by archived plans/checksums. Archive SHA-256:
`b1c7bdbdcfb7f84c0a6e088f119b6e78c8f8b46cdabae851ee80bb846bdf8283`.

| Python build | SHA-256 |
| --- | --- |
| Write phases | `47bacdefdd4083f1cec58c158199e1e8c045fdb9914e3fca559f87a8d1f92d51` |
| Link phases | `ca6ada6924778b1c6ce791a5d4fa24f01bc86967a9e736a5bf49c81b9db86adc` |
| Pair cache | `ff8f389de832f8042da27f76072e89610a22602a98c72cf33f67c97bf5185ff6` |
| Pair counters | `74e20b82f953a5408b82ea22eed3b58fadc102ff5cf4604dfba3ed74a5f9293b` |
| Production | `96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c` |

Builds, tests, workers and compression run serially on the native Mac. The two
phase builds retain one warning about an overwritten initial clock value.
No fresh Linux, capacity/nonresident, C ABI, crash or GPU acceptance is claimed
for these unadopted experiments. All M5/M6 requirements remain active.
