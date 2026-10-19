# Initialized-prefix batches: local gains, failed mixed acceptance

The initialized-prefix buffer lowers the three 128-dimensional rerank aggregates
by 3.1–5.6% relative to List batches, but does not improve strict mixed acceptance.
Fresh results are **19/36 production, 17/36 prior candidate and 14/36 prefix
candidate**, with six production and three prior pass-to-fail cells retained.
Do not adopt or carry this candidate forward. Continue from the verified
[HNSW List-batch source](2026-10-20-immutable-point-hnsw-batch.md). Production
remains `a6822c3`; the full M5/M6 objective and all remaining gates stay open.

## Reference and implementation

After rejecting the [Array-of-Optional variant](2026-10-20-immutable-point-fixed-batch.md),
this experiment returns to the prior List-batch source. It follows Qdrant's pinned
[`maybe_uninit_fill_from`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/common/common/src/maybe_uninit.rs)
initialized-prefix protocol and
[`for_each_in_batch`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/dense/immutable_dense_vectors.rs)
local buffer. The maximum remains 64 borrowed rows represented as 32 original
score pairs. Query parameters, pair grouping and arithmetic are unchanged.

Exactly three files differ from the List-batch base. A private `_DenseScoreBatch`
in `compute/dense_batch.mojo` owns a fixed Array of `UnsafeMaybeUninit` pair
descriptors and their initialized count. Both HNSW rerank methods and selective
exact scoring use it. Append constructs a complete pair before incrementing the
count; indexed access checks that count before exposing a reference. Clear and
destruction destroy only initialized descriptors. Moving the buffer transfers
the initialized prefix. It has no per-slot outer Optional or batch List allocation.

Rows remain borrowed from the same immutable owner. The pair gains `Copyable`
because the compiler's Array fill requires it; only empty uninitialized wrappers
are copied during fill. Compile-time checks require the pair to remain trivially
copyable and movable. No owner clones, vector materialization or untracked-origin
casts are introduced. The getter names its actual nested storage origin, keeping
the compiler's borrow checks intact. Existing acquisition-error precedence,
source/filter checks and partial lookup counters are unchanged.

The implementation uses the installed **Mojo 1.0.0 (ed45d567)**
[`UnsafeMaybeUninit` API](https://mojolang.org/docs/std/memory/unsafe_maybe_uninit/UnsafeMaybeUninit/).
Initial compiler rejections exposed the missing `Sized` conformance, an overly
broad getter origin and the pair's missing copy conformance. Each rejected
source and diagnostic is retained. No numeric owner, persisted format, public
getter, mutation or durability contract changes.

## Validation and sanitizer limitation

- **114 unique CPU cases in 15 modules** pass: the inherited three-case rerank
  reference, one new prefix lifecycle/bounds case, and 110 broader query cases.
  The four selective/mapped-row screening cases also run in the broader matrix
  and are counted only once. Coverage includes exact F32 bits, all metrics,
  multiple batches and tails, missing fields, error precedence, lookup counters,
  mapped-owner lifetime and unchanged public materialization caches.
- The new case verifies empty/out-of-prefix/negative reads, rejected overflow
  without losing existing entries, moving a full buffer, repeated clear, reuse
  with a shorter paired batch and correct final scores.
- **379 Python cases** pass, with exact candidate native identity verified in
  four launcher processes. Repository-source probes remain distinct from
  candidate-library execution. Candidate **C ABI** build, strict C11 compilation
  and execution pass.
- All product builds/tests use the frozen 132-file inventory. No new crash,
  actual-GPU, sustained-capacity or native Linux validation is claimed.

AddressSanitizer **does not pass**. The default build cannot resolve the expected
`__asan_version_mismatch_check_v8`; Xcode's installed runtime exports an Apple-
specific version instead. The installed Homebrew LLVM 21.1.8 runtime exports the
required symbol. Building with `--sanitize address --external-libasan` succeeds
and its library/binary hashes are retained. An initial attempt combining this
with `--shared-libasan` is rejected because the flags are mutually exclusive;
that diagnostic is also retained.

The resulting executable spins before `main`. A live one-second stack sample
shows ASan shadow-memory initialization entering macOS 26.5.2 dyld/malloc
callbacks, then recursively entering ASan and spinning on its initialization
mutex. The verified test PID is terminated after sampling; the wrapper exits
143. No test case executes in this run. The exact command is recorded in
`validate_sanitizer.py` and `sanitizer-results.json`; the local driver command is
`rtk proxy pixi run python .build/qdrant-alignment/immutable-point-prefix-batch/validate_sanitizer.py`.
Compiler constraints, normal lifecycle tests and the broader suites are the
available substitutes, not equivalent sanitizer coverage. No runtime check is
disabled or reported as successful.

Python native SHA-256:
`5498b39cbfdd458de2934176dc8d269db358813eaca462517b9aeb40c140b410`.
C native SHA-256:
`e301636005d30825d520634f7e80c463b4c680501a03e2da8f1de0b31986f22d`.

## Balanced phase diagnosis

The prior diagnostic binary is reused after its reconstructed source inventory
matches the parent exactly. The candidate uses identical instrumentation.
Twelve serial workers run prior/candidate then candidate/prior for each corpus.
All **3,456 timed responses, 12 exact reopens and 12 Arrow leases** match frozen
IDs, score bits, statistics, recall and routes. All 36 warmups are separately
retained; no timed samples are dropped. The 2,592 ANN calls rerank once each;
the 864 planned-exact calls do not rerank.

Microseconds below are medians of two trial medians. Negative reduction is a
regression and is retained:

| Corpus | Mode | List rerank | Prefix rerank | Reduction | List core | Prefix core |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | all | 31.50 | 29.75 | 5.6% | 369.75 | 367.50 |
| uniform-128 | correlated | 58.50 | 56.25 | 3.8% | 417.00 | 412.00 |
| uniform-128 | independent | 57.25 | 55.50 | 3.1% | 412.25 | 406.25 |
| uniform-1536 | all | 353.75 | 351.50 | 0.6% | 2542.50 | 2521.75 |
| uniform-1536 | correlated | 255.00 | 252.00 | 1.2% | 1249.25 | 1238.75 |
| uniform-1536 | independent | 261.25 | 258.50 | 1.1% | 1255.00 | 1244.50 |
| real-1536 | all | 24.00 | 24.25 | -1.0% | 323.00 | 325.00 |
| real-1536 | correlated | 165.50 | 164.00 | 0.9% | 723.25 | 718.25 |
| real-1536 | independent | 91.75 | 92.50 | -0.8% | 456.50 | 452.00 |

The two uniform-128 all/correlated trial medians decrease; independent is equal
in the first trial and lower in the second. The six high-dimensional aggregate
changes range from -1.0% to +1.2%, including the two recorded regressions.
These diagnostics do not establish end-to-end acceptance or eliminate the
earlier unbatched baseline's regression; that baseline is not part of this pair.

Selective exact core medians change 21.75→22.00, 72.25→71.00 and 78.25→78.75 µs.
Total selective writer waits over 144 timed queries per variant/corpus change
1995→1749, 1802→2473 and 1879→1352 µs. Clock resolution is 1 µs; zero phase
medians are not zero cost. Writer waits and core time remain separate costs.

## Fixed mixed acceptance

Thirty-six serial workers compare production, prior List batches, this candidate
and native Qdrant Edge 0.8.0 using unchanged plans, seeds, ef, oracle and mixed
read/upsert/flush schedule. Three of four order rotations are used, so order is
not fully balanced. Builds, tests, profiling and compression never overlap
timed workers; the sanitizer process is terminal before these workers start.

All **10,368 responses, 36 exact reopens and 27 Akasha Arrow leases** pass their
audits. Akasha IDs, score bits, statistics and execution match exactly, and all
36 Akasha recall cells pass. Matched quality remains 33/36 because the unchanged
real-correlated Qdrant cells have recall .945833 versus Akasha's .980556. No ef
retuning, exclusions or pending calibration decision are assumed.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 19/36 | 9/9 |
| Prior List batches | 33/36 | 17/36 | 9/9 |
| Prefix batches | 33/36 | 14/36 | 9/9 |

Median within-batch ratios; QPS improves above 1, p95 below 1. Individual trial
gates remain authoritative:

| Corpus | Mode | QPS / production | p95 / production | QPS / prior | p95 / prior |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.967 | 1.001 | 0.981 | 1.017 |
| uniform-128 | correlated | 0.971 | 0.975 | 0.978 | 1.017 |
| uniform-128 | independent | 0.950 | 1.209 | 0.993 | 1.001 |
| uniform-128 | selective | 0.930 | 1.100 | 0.987 | 1.044 |
| uniform-1536 | all | 1.008 | 0.988 | 0.996 | 1.020 |
| uniform-1536 | correlated | 1.003 | 1.009 | 0.997 | 1.021 |
| uniform-1536 | independent | 0.991 | 1.053 | 1.008 | 1.024 |
| uniform-1536 | selective | 0.880 | 1.034 | 1.092 | 1.053 |
| real-1536 | all | 1.005 | 0.976 | 1.009 | 0.982 |
| real-1536 | correlated | 0.998 | 0.972 | 1.003 | 1.000 |
| real-1536 | independent | 0.962 | 1.555 | 0.962 | 1.548 |
| real-1536 | selective | 1.067 | 0.854 | 1.116 | 0.893 |

Six production pass-to-fail cells remain: uniform-128 trial 2 correlated and
independent, uniform-1536 trials 0 and 1 selective, and real-1536 trials 0 and 1
independent. Three prior pass-to-fail cells remain: uniform-1536 trial 1 selective
and real-1536 trials 0 and 1 independent. The proper same-batch prior is 17/36;
historical counts are not substituted. Combined write-plus-flush retains the
durability-relevant comparison, rather than raw update calls with different
acknowledgement semantics.

## Decision and next investigation

Keep this source as evidence only. Both fixed-buffer attempts fail to improve
the required mixed gates; stop buffer-layout tuning. The unchanged prior source
still performs point-by-point authority/projection validation and numeric-owner
replacement inside `finish_live_compaction` while holding writer. Both foreground
and background callers take that lock. Read-run construction is already outside
it, so it would be redundant to repeat that optimization.

Next split and measure the remaining locked work: live-owner staging, read-head
staging, durable manifest publication and live-owner/root exchange. Compare that
protocol with pinned Qdrant optimizer/segment-holder ownership before changing
it. The current measurements do not prove which of those stages causes a
particular uninstrumented tail. Preserve complete preflight, newer writes,
legacy cutover, cancellation/conflict retry and file-lease reclamation.

Full warm/concurrent performance, sustained nonresident capacity under equal
limits, integration/example and native Linux gates remain open. No production
adoption, exception to a failed cell or M5/M6 completion is claimed.

The [evidence archive](2026-10-20-immutable-point-prefix-batch.json.gz) includes
complete product/diagnostic sources, implementation diff, new/inherited tests,
compiler rejections, all validation logs, native/runtime hashes, sanitizer stack
sample and termination evidence, 36 mixed and 12 diagnostic reports/logs,
phase/rerank traces, and seven pinned Qdrant files including LICENSE. An initial
archive check expected an empty sanitizer log; it now requires precisely RTK's
termination notice. The failed check and correction are retained without rerunning
workers. Parent identities and all embedded text hashes are verified; binaries
and copied databases are excluded. The archive has **880 text artifacts,
3,242,002 compressed bytes**, SHA-256
`eea12c861afeac94878a59fc6a6317ca658b31a8949250859de9fd00f9cbf8ce`.
