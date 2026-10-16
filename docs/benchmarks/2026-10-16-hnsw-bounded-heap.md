# Bounded heap access: rejected probes and refreshed native profile

All three heap variants are **rejected**. Production source and the installed
Python kernel are restored to `3de6e1c`; three independent heap regression tests
are retained. No new performance gate is closed. The accepted native snapshot
remains warm quality 36/36, speed 7/36; mixed matched quality 33/36, speed 14/36;
combined write+flush 5/9. Fixed L2 remains 228/240 at unchanged ef. See the
[accepted rerank report](2026-10-16-hnsw-paired-rerank.md) for that snapshot and
the three Qdrant mixed recall failures.

## Evidence-driven variants

Pinned Qdrant uses Rust `BinaryHeap`. Local Rust 1.92.0 source at
`library/alloc/src/collections/binary_heap/mod.rs` bounds sift operations before
unchecked accesses and moves parents/children into the displaced item's position.
The [Rust source](https://doc.rust-lang.org/src/alloc/collections/binary_heap/mod.rs.html)
and [Mojo List API](https://mojolang.org/docs/std/collections/list/List/) informed
these probes; installed Mojo 1.0.0 compilation verified `unsafe_get/unsafe_set`.
The earlier checked-List movement probe was rejected. This experiment first
isolates repeated bounds work, then static-message guards, then movement.

Disassembly finds unconditional error-message descriptor stores before repeated
List checks inside the accepted heap loops, plus a `0x830`-byte stack reservation.
Formatting calls themselves are on failure paths, not normal-loop calls. Every
prototype keeps distance/ID/slot ordering, capacities, public errors, traversal
and ef. No global checks are disabled.

| Variant | Candidate sift-up | Candidate/result sift-down | Stack reservation |
| --- | ---: | ---: | --- |
| Accepted parent | 504 bytes | 936 bytes | `0x830` plus saved registers |
| Checked entry, bounded swaps | 368 bytes | 476 bytes | `0x830` plus saved registers |
| Static safe guard, bounded swaps | no standalone symbol | 292 bytes | 16 bytes of saved registers |
| Static safe guard, bounded moves | no standalone symbol | 316 bytes | 16 bytes of saved registers |

One checked entry establishes `0 <= index < count`. Sifts never change List
length or reallocate. Upward, `index > 0` proves the parent valid. Downward,
`index < count // 2` proves the left child valid and avoids signed child-index
overflow; the right child has its own bound check. All slots remain initialized.
The movement variant copies a parent/child into the current slot, then writes
the retained item once after the loop. It uses no raw pointer, uninitialized
hole, additional owner or cache.

The second and third prototypes use explicit `debug_assert[assert_mode="safe"]`
with a constant message. [Safe assertions](https://mojolang.org/docs/std/builtin/debug_assert/debug_assert/)
are enabled by default. Each prototype's default-compiled subprocess probe
confirms all 12 negative/out-of-range/empty cases terminate with the assertion
message, and four valid entries complete. There is no assertion-mode override.

## Saved-graph diagnostics

For each prototype, three serial alternating before/after pairs per corpus
replay identical saved graphs, workload, oracle and frozen ef, with 31 query
passes per worker. Both versions use the same thread CPU clocks. Each prototype's
36 paired cells preserve result digests, full recall arrays and every recorded
search statistic. No build, test or compression overlaps timing. Repeated passes
are not independent quality observations.

The first prototype improves low-dimensional median QPS by 0.7–2.8%, but all
three real unfiltered QPS pairs regress. Its remaining entry formatting cost
motivates the static guard. The static-guard variant improves low-dimensional
median QPS by about 2.6–2.7%, but mixed real independent QPS regresses in all
three pairs (.987, .979, .978). Both complete matrices remain in the archive.

The final movement prototype improves all nine ANN median QPS and p95 cells
in the saved-graph diagnostic. Individual regressions remain: uniform-128
correlated trial 2 p95 is 1.022, uniform-1536 all trial 2 p95 is 1.003,
and real all trial 2 p95 is 1.002. This alone does not establish mixed behavior
or Qdrant parity. Final-prototype after/before medians:

| Corpus | Filter | QPS | p95 |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.026 | 0.975 |
| uniform-128 | correlated | 1.032 | 0.962 |
| uniform-128 | independent | 1.027 | 0.967 |
| uniform-128 | selective | 1.002 | 0.998 |
| uniform-1536 | all | 1.012 | 0.980 |
| uniform-1536 | correlated | 1.014 | 0.983 |
| uniform-1536 | independent | 1.010 | 0.987 |
| uniform-1536 | selective | 1.005 | 0.987 |
| real-1536 | all | 1.022 | 0.978 |
| real-1536 | correlated | 1.027 | 0.969 |
| real-1536 | independent | 1.021 | 0.968 |
| real-1536 | selective | 1.001 | 0.979 |

## Mixed-write diagnostics and rejection

Static swaps and bounded moves each have 18 serial workers: three alternating
pairs per corpus, cloning the same accepted trial-0 graph and frozen mixed plan.
Each matrix preserves all 5,184 query response IDs, recall, oracle, execution
decisions and statistics; all 18 reopen oracles and 18 retained Arrow leases
pass. All 72 individual quality cells pass. Mixed reports do not contain score
bits; score digests are independently compared in the saved-graph diagnostics.

Final movement-prototype mixed medians:

| Corpus | Filter | QPS | p95 |
| --- | --- | ---: | ---: |
| uniform-128 | all | 0.982 | 0.995 |
| uniform-128 | correlated | 1.014 | 0.976 |
| uniform-128 | independent | 1.018 | 0.950 |
| uniform-128 | selective | 0.912 | 1.034 |
| uniform-1536 | all | 1.005 | 0.964 |
| uniform-1536 | correlated | 1.008 | 0.997 |
| uniform-1536 | independent | 1.006 | 1.002 |
| uniform-1536 | selective | 1.064 | 0.569 |
| real-1536 | all | 1.011 | 0.982 |
| real-1536 | correlated | 1.026 | 1.008 |
| real-1536 | independent | 1.029 | 0.966 |
| real-1536 | selective | 1.001 | 0.963 |

The final prototype's low-dimensional all-mode median QPS regresses 1.8%.
Low-dimensional selective QPS is below one in all three trials (.912, .966,
.708), with median p95 1.034. Uniform-1536 independent and real correlated median
p95 also rise slightly. The selective path is planned exact and the heap change
does not directly alter its query loop; these observations do not establish
that heap instructions caused its regression. They remain unexplained and are
not discarded or offset against faster cells. The small saved-graph gain does
not justify retaining another source of unresolved mixed regressions.

No fourth prototype, repeated-until-passing run, fresh Qdrant acceptance or
expanded suite is claimed for the rejected variants. Unexecuted final-validation
and acceptance drivers are retained as preparation only.

## Validation and restored state

The accepted parent passes all 13 heap cases, including the three added tests:
interleaved pop/refill across allocation and child boundaries, shrinking/growing
result capacities against an independent sorted model, and negative reserve
preserving existing entries. Every prototype passes the same 82 related Mojo
cases (heap, scratch, search layers, neighbor selection, cancellation, segmented
search and paired rerank) and all 98 extracted Qdrant fixtures on both scalar
and batched F32 paths. Those source fixtures cover single-entry primitives,
not the separate multi-entry query adaptation. All three Python extensions build.

Production heap source has an empty diff against the accepted parent. The
restored Python SHA-256 is
`0fc4b7268fd9f5ddc1df2dffed64f2c867b6b552806ba4850eb0db23ecb8ddb3`.
Previous accepted Python/C/quality validation remains applicable; it was not
rerun to imply validation of a retained optimization. New model tests were
already run against this unchanged parent before the experiment.

## Refreshed accepted-parent sampling

Five new serial ten-second native captures use the restored binary, saved
original graphs and original ef. All samplers/workers exit successfully.
All 335 pre/post query pairs preserve IDs, F32 score bits, recall and counters.
Non-main threads have no Akasha frames; collapsed leaf counts below use main
samples as denominator. Functions with fewer than five samples are omitted by
the native collapsed report. These are localization observations, not exact
time attribution or acceptance measurements.

| Corpus / mode | Samples | Graph four-row | Graph mapped single | Graph owned single | Authority pair | HNSW heaps | Mapped byte read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform-128 / all | 7,693 | 7.46% | 0.70% | 1.75% | 2.83% | 16.59% | 6.17% |
| uniform-128 / correlated | 7,696 | 1.56% | 0.88% | 0.32% | 2.65% | 14.32% | 5.12% |
| real-1536 / all | 7,590 | 35.40% | 5.19% | 20.58% | 8.23% | 4.43% | 1.00% |
| real-1536 / correlated | 7,610 | 12.00% | 15.41% | 4.73% | 21.01% | 7.70% | 2.17% |
| real-1536 / independent | 7,643 | 14.34% | 12.55% | 5.93% | 20.69% | 6.75% | 1.62% |

The accepted paired authority kernel still accounts for about 21% of real
filtered leaf samples. Low-dimensional correlated `Bitmap.contains` alone has
593 / 7,696 = 7.71%; source shows logical index validation followed by a checked
List word read. Its current 312-byte symbol also reserves `0x830` bytes for the
List failure path. The next bounded investigation is this bitmap lookup and
its caller eligibility work, with public invalid-index errors preserved. No
bitmap change is made in this commit. Heap speedups are too small and inconsistent
to close the remaining roughly twofold low-dimensional warm gap by themselves.

Native Linux, concurrency, sustained nonresident and full type/capacity/lifecycle
requirements remain open. The pending push decision is not treated as approval.

## Frozen evidence

[Complete evidence](results/2026-10-16-hnsw-bounded-heap.json.gz) retains all three
candidate source snapshots and patches, assembly, test logs, raw paired timings,
profile traces and audits, drivers and restoration hashes. Large graphs, datasets
and binaries are identified rather than embedded. Mixed vector plans retain
hashes and deterministic regeneration inputs. All embedded file hashes verify.

Archive: 414 files, 7,631,318 bytes. SHA-256:
`85c4cdd59ba9ad33a6bfbb28a76f2b7bbf6a4a1434db14716db62f30fca95575`.
