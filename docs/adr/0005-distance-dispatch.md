# ADR 0005: Distance backend selection boundary

- Status: Accepted
- Date: 2026-09-07

## Context

HNSW construction and traversal evaluate distance inside dimension and neighbor
loops. Rechecking the collection metric and compact scalar representation in
those loops adds avoidable branches and makes backend reporting ambiguous.
Akasha also must not describe one compiler-selected SIMD width as runtime
multi-ISA dispatch.

The pinned toolchain is Mojo 1.0.0 (`ed45d567`). On the implementation host,
Darwin 25.5.0 arm64 on Apple M4 Pro, `simd_width_of[DType.float32]()` is 4. A
compiler probe rejected storing `def(Float32, Float32) -> Float32` in a struct
field with `struct fields do not support trait types; use a concrete type or
compile-time generic`. This rules out a safe stored function value for the
required ownership boundary on this compiler.

## Decision

`distance_backend_tag(metric, scalar)` is the single authoritative mapping from
an enabled identity to its small integer tag. `DistanceBackend` construction
rejects a mismatched or unknown tag, and every injection or rebind validates
the tag, dispatcher metric/scalar/dimension, and reported backend name before
mutating an index or view. `select_distance_backend(config, counters)` uses
that mapping and records one selection when an owned or mapped index is
constructed.

One recorder seam distinguishes selection, public-boundary, and hot-loop
locations. Public insert and search boundaries record the boundary, switch on
the tag once, and invoke a core parameterized by the metric/scalar combination.
Specialized storage, core, and view entry points receive the tag as a compile-
time parameter. Dimension loops and HNSW neighbor traversal contain only
compile-time branches and never call the recorder. A negative instrumentation
test deliberately records a hot-loop event to prove that its zero is measured,
not hard-coded. Counters live on each index/view rather than in global mutable
state, so instrumentation does not couple concurrent indexes.

A segmented index owns one backend and one counter set. Its constructor selects
once and injects that backend into the closed mapped placeholder, owned
placeholder, and mutable delta. Adoption constructors also select once without
first running a selecting default constructor, then rebind the adopted base to
the aggregate backend. Each segmented filtered or unfiltered search switches at
the outer public boundary and calls no-reswitch parameterized entries on both
base and delta. Owned, mapped, and segmented paths retain canonical
lower-is-better HNSW distance and existing public score conversion.

The portable implementation reports `portable-simd-<width>`, where `width` is
the actual compiled Float32 SIMD lane count. This means compile-time native SIMD
for the current binary. It does not mean the binary detects or switches among
multiple instruction sets at runtime.

The existing exact/parallel scan and GPU planner remain the execution-policy
layer. They continue to own CPU/GPU eligibility, batch sizing, and fallback
reasons. The HNSW backend is a distance-kernel layer beneath that policy; it
does not recursively invoke either planner.

Exact batch and parallel scan provide reported wrappers without changing their
existing result APIs. A separate scalar exact reported API supplies a reference
backend labeled `scalar-f32`. GPU batch results carry the same execution-stat fields.
Those paths and HNSW therefore expose compatible backend, metric, scalar,
fallback reason, ef, visited, and distance-evaluation vocabulary. Exact and
parallel ef values are zero; GPU fallback retains the planner's reason. A true
GPU execution reports `gpu`, while a heterogeneous filtered batch reports
`mixed` rather than claiming a CPU or GPU backend exclusively. Deterministic
stats-construction tests cover both labels without claiming an actual-device
run; compile-time-disabled GPU fallback remains covered end to end.

## Consequences

- Backend, metric, and scalar labels in HNSW stats and distance/HNSW benchmarks
  identify the real compiled portable backend.
- The distance benchmark times the selected packed-storage kernel after one
  outer runtime switch for both F32 and I8, reports real per-owner dispatch
  counters and a checksum, and verifies the selected result against the scalar
  prepared-value reference.
- Exact, parallel, GPU, and HNSW execution reports can be compared without
  transferring ownership of CPU/GPU policy to the distance dispatcher.
- One index/view/segmented construction performs one measured backend
  selection. Each public tag switch is measured, while neighbor distance
  evaluation performs none.
- All eleven enabled metric/scalar pairs traverse owned, mapped, segmented,
  widening, and score-parity test paths.
- Adding a backend requires an explicit tag, compile-time kernel, validation,
  and parity/quality tests rather than a runtime string switch.

## Future work

A future NumKong or plugin backend may be added only after its build and
packaging model proves true runtime capability detection. Validation must cover
every metric/scalar pair, scalar-reference parity, unsupported-ISA behavior,
owned/mapped/segmented equivalence, HNSW recall, and honest selected-ISA
reporting. No NumKong/plugin interface or runtime multi-ISA backend is
implemented by this decision.
