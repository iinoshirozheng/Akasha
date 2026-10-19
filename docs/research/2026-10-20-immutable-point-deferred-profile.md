# Reprofile the retained deferred-ID candidate

The [deferred-ID candidate](2026-10-20-immutable-point-deferred-id.md) remains
the implementation to carry forward. This diagnosis changes no product source,
native binary, workload, ef or acceptance gate. Its last strict mixed result
remains **25/36**, with eight speed failures and three quality failures.
Production remains `a6822c3`; the candidate is not adopted into production.

## Method and identity

Four serial macOS `sample` captures run for five seconds each at a requested
one-millisecond interval. Correlated runs use Akasha then Qdrant; independent
runs reverse that order. Each worker clones the frozen uniform-1536 initial
database and repeats its two initial-state queries, ordinals 3 and 4. There are
no interleaved updates during these captures. Request construction and search
are inside the repeated loop; stats collection is outside it.

All four workers and samplers exit successfully. **Eight preflight and eight
postflight responses** match the corresponding frozen IDs, F32 score bits and
available stats. Repeated requests are not independent performance or quality
samples, and their returned values are not individually audited. There is no
new mixed, concurrent, sustained-capacity or platform result here.

The unchanged 132-file candidate inventory matches its prior evidence archive.
Both the initially imported Python extension and explicit native override use
SHA-256 `64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`.
The Qdrant runtime remains
`746ce4acdbb56db68aaba805bddf52961a083c5ed5da19f16b5ba500114c788d`.
The prior native captures use query-lock binary
`4d71aec5b11193be99034bd87ccdc163d63526d464c84351bc44c7ddf1b4f96e`;
their raw bytes match the [source-phase archive](2026-10-20-immutable-point-source-phases.md).

## Correcting missing function names

Some Mojo constrained-generic names in Apple's sample output begin with
`::AnyType` instead of their actual function name. Matching function prefixes
alone therefore omitted the new `_allows_slot` frames. The initial analysis
reported admission shares of **.37%/.60%**; those values are incorrect and are
retained only under `analysis-prefix-only` in the evidence.

The corrected analyzer resolves those unnamed frames against `nm -n` from the
exact native binary. It subtracts the captured image base and verifies every
displayed program-counter/function-offset pair against the resolved symbol.
All addresses displayed for one frame must resolve to the same symbol. This
recovers 57 current and 56 prior frame records, including `search_level`,
`score_points` and both source-admission wrappers. Named functions retain their
original sample labels. An initial attempt to resolve every native frame also
encountered dynamic-linker stubs absent from the text-function symbol table;
it stopped before writing output, and its correction is recorded.

Akasha grouping matches the actual function prefix, never a type mentioned in
another function's generic arguments. Exclusive observations are inclusive frame counts
minus immediate children. Every thread's exclusive counts sum exactly to its
root count. Both old and new captures use this same corrected analyzer.

## Thread-local observations

Percentages below use Akasha's main thread as each row's denominator. They are
sample observations, not elapsed-time attribution, operation counts or predicted
speedup. Four short captures do not establish causation or statistical
significance, and code generation can shift work between frames.

| Capture | Observations | Mapped four-row scorer | Mapped single-row scorer | Authoritative pair scorer | Metadata access | Source admission | Heap |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Prior correlated | 3,784 | 13.40% | 12.66% | 14.53% | 13.95% | 7.37% | 7.61% |
| Current correlated | 3,774 | 13.88% | 13.43% | 15.08% | 9.80% | 8.35% | 7.66% |
| Prior independent | 3,804 | 14.01% | 12.96% | 14.04% | 11.88% | 8.07% | 7.73% |
| Current independent | 3,824 | 13.96% | 12.74% | 14.83% | 9.78% | 7.98% | 8.45% |

Metadata observations are lower in both modes. Source admission remains around
eight percent; it has not disappeared. Current `search_level` and `score_points`
account for another **10.78%/6.94%** in correlated and **10.56%/6.20%** in
independent captures. Complete symbols and all thread tables remain in the
archive; the table is a selected grouping, not an exhaustive cost model.

Qdrant uses its separate `edge-search-0` denominator:

| Current mode | Observations | Dense raw scorer | Appendable raw scorer | Filter partition | Batched filter check | Graph-link accessor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Correlated | 3,707 | 54.33% | 4.21% | 12.71% | 6.58% | .24% |
| Independent | 3,694 | 51.30% | 4.25% | 15.05% | 7.20% | .35% |

The engines' different inlining, responsibilities and denominators prevent
interpreting these shares as a ratio of equivalent work. In particular, a
larger Qdrant raw-scorer share does not mean slower vector scoring.

## Source basis and next step

The archived Qdrant sources and license are byte-checked against commit
`21db2f3ff95d50de3a2b88a741312c056fd1762d`, rather than the checkout's current
HEAD. This remains the reference-first workflow:

- `FilteredScorer::score_points` filters the batch, applies the cap and reuses
  score storage. Akasha retains that ordering and its slot-based candidate
  buffer; the last change removed unused public-ID reads in base admission.
- `MetricQueryScorer::score_stored_batch` passes internal point offsets to dense
  storage and scores each supplied vector slice against its prepared query.
  `DenseVectorStorageImpl::for_each_in_dense_batch` delegates to storage's batch
  reader. This provides a concrete comparison for Akasha's mapped score path.
- Akasha's mapped scorers call checked `MappedFile.load_scalars` for each SIMD
  chunk. Its authoritative pair scorer also preserves candidate finite-value
  checks and error precedence. Those are source-level facts; this sampling does
  not isolate their individual runtime cost or show which checks the compiler
  removes.

Next inspect the exact candidate's generated mapped-score loops before choosing
a bounded-read change. Keep F32 reduction order, required authoritative rerank,
closed-owner behavior, bounds checks and error precedence. Qdrant's Rust slice
lifetimes cannot simply be replaced by a raw pointer borrowed from an explicitly
closeable Mojo mapping. Previously rejected raw-borrow, copied-node-buffer and
broad-inlining probes remain rejected. No new scoring optimization is claimed
by this diagnosis.

Existing candidate correctness checks remain applicable because source and
native identities are unchanged. All open M5/M6 warm, concurrency, nonresident
capacity, integration/example and native Linux requirements remain open, along
with the strict mixed failures. The Qdrant real-correlated recall failures are
neither excluded nor repaired by changing ef.

[Verified sampling and analysis evidence](2026-10-20-immutable-point-deferred-profile.json.gz):
**83 text artifacts, 725,566 bytes**, SHA-256
`0f5e9346c8af6ddca2487eeebace29293a9e62683cbe6c53c0ddc73e00292aa7`.
It includes all four new and four prior raw captures, both exact native symbol
tables, corrected and initial analyses, all pre/postflight reports, sampled
query excerpts, source/native/workload identities, relevant unchanged candidate
source excerpts, verified upstream sources/license, drivers and audit. Complete
candidate source and prior mixed evidence remain in the linked parent archive.
