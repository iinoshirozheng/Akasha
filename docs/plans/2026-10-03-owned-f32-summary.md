# Owned F32 scoring summary experiment

Continue M5/M6 from `b29eca2`. This is an experimental design, not an adopted
optimization or a completed performance gate.

## Evidence and choice

The current exact scan recomputes each immutable candidate's finiteness and
cosine squared norm on every query. Query preparation already happens once.
Previous field-lookup simplifications and prepared HNSW reranking failed their
public performance assessment; do not repeat them as standalone changes.

Options considered:

1. Retain the checked pair loop: no new state, but repeat candidate reductions.
2. Cache norms on each read root: simple invalidation, but rebuild all summaries
   after small updates and retain a separate lookup structure.
3. Compute two derived scalars when an immutable F32 value takes ownership:
   finite status and the existing SIMD-ordered squared norm. Replacements get
   new values; unchanged fields retain the same owner and summary.

Prototype option 3. `VectorValue` already owns its numeric buffers and exposes
only immutable references. `PointField` shares that immutable value through
ArcPointer; PointState updates replace owners rather than mutate buffers.
Qdrant's ingestion-time preprocessing is the established pattern, but Akasha
must preserve its authoritative raw F32 bytes and established score arithmetic.

## Scope and invariants

- Add a nonthrowing F32 summary calculation using the existing SIMD width,
  reduction order and scalar tail. The checked query preparation reuses it.
- Store the summary with owned F32 numeric values. Other dtypes retain their
  own representation; summaries do not replace native authority.
- Legacy F32 construction still accepts raw nonfinite bits. It records invalid
  finite status without throwing. A selected invalid candidate raises during
  scoring; an unselected invalid candidate must not fail a filtered query.
- Exact collection scoring checks dimensions and cached candidate validity,
  then uses the existing dot/L2 accumulator ordering. Cosine uses the stored
  squared norm and the query's prepared norm with the same final division.
  Zero-norm rejection stays after finite validation.
- The summary contains no pointer or owner. It lives and dies with the vector;
  no global cache, field lookup table, public API, planner or format changes.
- HNSW traversal/reranking and FlatIndex remain controls in the first slice.
  Persistent codecs still serialize only authoritative data; recovery rebuilds
  derived summaries. Compile every changed Mojo module with Mojo 1.0.0.

## Validation and adoption

Use score-bit comparisons with the existing checked scoring implementation at
SIMD boundaries, tails, large dimensions, signed zero, subnormals, finite extrema,
NaN and infinities. Verify input ownership, default-field replacement/removal,
shared snapshots, filtered late invalid values and reopen. Existing exact-query
extreme tests and codec fixtures remain authoritative.

Measure preparation/ingestion cost, retained memory and public query latency.
Build the prototype from its copied binding entry point; test saved packages
with pytest's configured pythonpath disabled. Production artifacts remain at
the verified baseline until assessment.

The existing frozen-corpus strict speed assessment is the failing performance
test. Run baseline/candidate/Qdrant in serial independent processes with the
same selected ef, recall target, workload and all trials retained. Require
correctness first and assess every changed warm/mixed cell, including write,
flush, reopen and lease costs. A failed speed gate is not a failed runner.
Do not adopt on one microbenchmark or hide regressions behind another cell.
