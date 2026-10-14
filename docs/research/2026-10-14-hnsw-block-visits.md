# Block-stamped HNSW visits — not adopted

An isolated prototype reduces retained visited payload for 8,192 slots from
**32,768 to 2,048 bytes**, preserving the UInt32 query epoch and O(1) normal
reset. It passes **111 Mojo and 369 Python tests**, and all **54 native
warm/mixed workers** complete with identical results and statistics. It is
not adopted: warm speed changes from 22/36 to 21/36, with two pass→fail cells;
mixed improves from 18/36 to 21/36 but does not offset those failures.
Production remains `96e05e2c…`; M5/M6 remain incomplete.

## Evidence and implementation

The prior [native sample](2026-10-14-filtered-ann-native-sample.md) attributes
264 of 7,559 production correlated main-thread samples to scratch visits
(about 3.49%). This is diagnostic sampling, not a predicted speedup.
Production stores one UInt32 epoch per slot. Local FAISS
`613e0acac507c7593ff14dee2c6204a83a539acb` uses a reusable byte generation array
in `faiss/impl/VisitedTable.h`; local Qdrant
`74f3e85b9473c62560006c043e13737ce6b48412` similarly uses byte counters in
`lib/segment/src/index/visited_pool.rs`. Those sources establish the reusable
generation pattern, not this block scheme or the internals of measured
Qdrant Edge 0.8.0. Both reference files are embedded in the archive.

The prototype at `.build/m5-resume/hnsw-block-visits` starts from the frozen
production result-ownership package, with no earlier rejected optimization.
Only `src/akasha/index/hnsw_scratch.mojo` changes:

- Replace per-slot epochs with blocks holding one UInt32 epoch and one UInt64
  mask for 64 slots. Mojo 1.0.0 (`ed45d567`) emits a 16-byte block.
- The first visit in a new epoch replaces the entire block mask. Later visits
  check/set their own bit. Traversal order, result admission and stats are
  unchanged.
- Normal `begin` still increments the UInt32 epoch without scanning storage.
  Wrap invalidates all retained block stamps, including hidden capacity.
  No shorter counter or more frequent wrap is introduced.
- Same-query growth preserves existing marks. Bounds use the current prepared
  slot count, so partial blocks and retained capacity never expose extra slots.
  The positive-count block formula avoids adding 63 to a potentially large Int.

No public API, persistent format, graph construction, distance arithmetic,
heap policy or dependency changes. The existing Bitmap provides the local
UInt64 mask idiom; it is not reused as a query eligibility adapter or cleared
on every search. Mapped prefetch remained research only and is absent here.

Separate compiled layout probes report the actual List capacities:

| Representation | Entry bytes | Entries / capacity | Retained payload |
| --- | ---: | ---: | ---: |
| Production slot epochs | 4 | 8,192 / 8,192 | 32,768 bytes |
| Block epochs and masks | 16 | 128 / 128 | 2,048 bytes |

These figures exclude List headers, heaps and allocator overhead; they are
not total process memory or nonresident evidence. The emitted standalone
`visit` symbol grows from 496 bytes / 124 instructions to 560 / 140, including
error paths. This observation does not establish the cause of timing changes.

## Validation and complete matrix

Five new semantic cases first pass on the unmodified production scratch,
then pass on the prototype. They exercise all bits and block boundaries,
same-query growth, stale tails after shrink/regrowth, wrap with hidden blocks,
and 120,000 operations against a simple dense reference model over 300 queries.
The 11 existing scratch cases retain their behavior checks with storage
assertions adjusted to blocks; one added case checks compiled payload size.

The complete targeted suite passes **111 cases in 12 Mojo files**: five new
semantic cases, 12 scratch cases, search layer 14, filtered 8, segmented 18,
delta scan 5, mapped view 9, mutation 12, neighbor selection 15, group order 1,
widening 9, and live radius 3. All **369 Python tests pass**, with three existing
warnings and no skips. The 30-entry compiler audit retains the original
semantic run, explicit production layout probe, candidate builds and Python
child compilations. No project-root source argument leaks into a candidate run.

Both benchmark phases use three frozen corpora and three rotating
before/after/Qdrant triples, with unchanged ef, K, filters, oracle, plans and
timing boundaries. Builds, tests, benchmarks, assembly inspection and
compression run serially. Every paired ID, Float32 score bit, statistic and
execution decision matches. All mixed reopened-oracle and Arrow lease checks
pass. Raw warmups, latencies, slow samples and failures are retained.

| Phase | Quality before / after | Strict speed before / after | Pass→fail / fail→pass |
| --- | ---: | ---: | ---: |
| Warm | 36/36 / 36/36 | 22/36 / 21/36 | 2 / 1 |
| Mixed | 36/36 / 36/36 | 18/36 / 21/36 | 0 / 3 |

Strict speed requires both QPS ≥ Qdrant and p95 ≤ Qdrant, after Recall@10 ≥ .95.
Mixed write+flush remains **3/9 before and after**. The two pass→fail cells are
**real-1536 warm all and selective, zero-based trial 2**. All other failing
cells also remain failures; improvements elsewhere do not compensate for them.

Real filtered after/before ratios, with all three trials shown:

| Phase / mode | QPS ratios | p95 ratios |
| --- | --- | --- |
| Warm / correlated | .966 / .937 / .871 | 1.034 / 1.081 / 1.142 |
| Warm / independent | 1.009 / 1.035 / .915 | 1.023 / .984 / 1.069 |
| Mixed / correlated | 1.016 / .997 / .934 | 1.015 / 1.009 / 1.214 |
| Mixed / independent | 1.021 / 1.013 / .966 | 1.056 / .927 / .934 |

Uniform-128 mixed independent QPS is .940/.891/.930 of baseline and p95 is
1.629/1.621/1.618. Warm real trial 2 also regresses on the unchanged selective
exact path. No causal explanation for cross-path variation is established,
and that trial is not discarded or reclassified. The smaller visited array
does not establish consistent end-to-end improvement.

## Frozen evidence and remaining work

Candidate Python SHA-256:
`f693af420b8ea00306fff82d7350d8b9e94799fbd24b70641509882bbb1c9d3d`.
Production source bytes and Python binary remain unchanged:
`96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c`.

The [raw archive](2026-10-14-hnsw-block-visits.json.gz) contains **797 files,
3,885,259 bytes**, with every embedded SHA-256 verified. It retains the complete
candidate source, production scratch, patch, reference code, commands, compiler
audit, tests, layout probes, assembly and all 54 workers. The mixed driver's
exit code 1 records the failed strict gate after every worker completed.
Archive SHA-256:
`da5a368100c54094badb013c0cc7eb74972be17c663df61bab04e3214dc34803`.

No fresh Linux, capacity/nonresident, C ABI, crash or GPU validation is claimed
for this unadopted prototype. Do not repeat this block representation solely
because it saves scratch bytes. Next inspect mapped adjacency metadata access;
the existing u16/u32/u64 readers already use checked copied scalar loads, so
there is no byte-assembly loop to eliminate. Mapped ownership, HTTP,
nonresident and native-Linux performance requirements remain unresolved.
