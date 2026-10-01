# Official heap suitability: retain the existing heaps

#61's evaluation is complete. The pinned official `BinaryHeap` does not pass
the current adoption gates, so `BoundedTopK`, `CandidateMinHeap` and
`ResultMaxHeap` remain unchanged. The benchmark candidate is not a production
fallback. This is an evidence-backed rejection of this API adaptation, not a
claim that the existing heaps are optimal or that M5/M6 performance is complete.

## Top-K semantic and storage probe

The [compiled candidate](../../benchmarks/mojo/heap_bench.mojo) uses only the
official constructor, `push`, `pop`, `peek`, `clear` and length for operations.
Its Comparable entry contains a public ID and a canonical Float32 key. For
larger-is-better queries, negation on admission and output preserves score
bits, including signed zero and infinities, without enlarging the 16-byte entry.
The existing smallest-ID tie rule is retained.

Sixty cases compare both implementations with an independent insertion-sorted
oracle. They cover both score directions, k=1/2/10/32/1024, empty/partial/full
heaps, overflow admission, negative IDs, ties, finite extremes, ±infinity and
signed-zero bits. Repeated drain/refill and eight explicit clear/refill rounds
preserve backing address and capacity. The official and existing entries are
both 16 bytes, and neither heap grows after its initial reservation in this
bounded workload. Both drain operations allocate an output List. Private
backing-list access is used only for this measurement, not as an implementation
of a missing public operation. NaN scores are not part of this ordered-domain
probe, and no production comparator contract changes.

## Top-K latency gate

The matrix contains 32 paired cells: two score directions, four capacities
(1/10/64/1024), and random/ascending/descending/equal-score inputs. Each process
constructs the same 100,000 inputs, warms once, then measures ten rounds while
reusing heap storage. Three fresh-process trials alternate implementation
order, yielding 192 runs. Construction, input generation, output checksum and
result destruction are outside the timer; offers and draining have separate
timestamps. Every paired checksum matches, and every refill produces the same
output. The host is interactive macOS ARM64, with no fixed affinity/frequency.

The official candidate is faster in **28 of 32 median cells**. For example,
random inputs at k=64 take about 0.33–0.35 of the existing time, and at k=1024
about 0.70–0.74. These are heap-only costs, not database-query speedups.

The four replacement-heavy k=1 cells regress. A second, larger measurement
uses one million inputs and twenty measured rounds per process, five trials,
and alternating implementation order. The regression persists in every paired
trial (40 additional runs):

| Score direction / input | Existing ns/offer | Official ns/offer | Official / existing |
| --- | ---: | ---: | ---: |
| Min / descending scores | 2.302 | 2.619 | 1.138 |
| Min / equal scores, descending IDs | 2.302 | 2.627 | 1.141 |
| Max / ascending scores | 2.309 | 2.603 | 1.127 |
| Max / equal scores, descending IDs | 2.330 | 2.662 | 1.142 |

The normalized times include the measured drain stage. At k=1 it contributes
one result per round and does not explain the difference. The source shows why
this case is unfavorable: the original replaces the root directly, while the
official public API requires a pop followed by a push. This source comparison
is an explanation of the measured result, not a separate attribution profile.
The full input data and candidate use the same rank order; no recall or result
semantics are traded for speed.

The task requires no latency regression before deleting the old implementation.
That gate fails. Retaining a second singleton implementation, accessing private
heap storage or adding a selection policy would add complexity outside this
direct-API adaptation. The measured wins remain recorded for later profiling
or an official API with efficient root replacement.

## HNSW API gate

The exact
[Mojo 1.0 official source](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/collections/binary_heap.mojo)
has constructor-time capacity, push/pop, immutable peek, clear and length.
It has no public method to reserve an existing heap, report its retained
capacity, or replace its root. Three negative compile probes confirm the
missing `reserve`, `capacity` and `replace_root` attributes on compiler
**Mojo 1.0.0 (ed45d567)**. Their expected exit code is 1; exact source and
diagnostics are retained in the raw artifact.

These are concrete local requirements:

- `HnswSearchScratch.begin()` clears and reserves the existing candidate,
  traversal-result and optional filtered-result heaps. Widening/narrowing
  rounds retain real allocated capacity; the filtered heap reports it.
- `CandidateMinHeap.reserve()` supports growth without losing the existing
  candidates; push/pop preserve distance/ID/slot ordering.
- `ResultMaxHeap.offer()` handles a changed bound and replaces a full heap's
  root with one sift. Its capacity reports feed scratch-allocation tests.
- Empty operations raise Akasha Errors. The official heap aborts on empty,
  which would need wrapper checks if the other gates passed.

A larger adapter could reconstruct heaps, maintain reservation bookkeeping or
use private `_data`, but it would no longer be a direct replacement with the
same reserve/reuse behavior and complexity. The HNSW heaps are therefore
retained at this API gate; no HNSW latency claim is made from the Top-K numbers.
The existing nine HNSW heap and eleven scratch tests pass, including tertiary
slot ties, filtered-capacity accounting and repeated-query reuse. Four existing
Top-K tests also pass: **24 tests total**.

## Reproduction and evidence

```sh
pixi run mojo run -I src benchmarks/mojo/heap_bench.mojo
pixi run mojo build -I src benchmarks/mojo/heap_bench.mojo -o .build/heap-bench
.build/heap-bench existing 1 min 1000000 descending 20
.build/heap-bench official 1 min 1000000 descending 20
pixi run mojo run -I src tests/mojo/test_topk.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_heap.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_scratch.mojo
```

[Raw results](results/2026-10-01-official-heap.json) include all 232 timing runs,
32 paired summaries, 60-case semantic/reuse validation, 24 existing test
results, negative compile probes, exact benchmark/driver/engine sources and
SHA-256 hashes. These changes add only the evaluation and evidence; the engine
source hash remains the #60 value
`0382203bab2012e2546d64ea8575ee1e0d6208d5375d8ddb9d6d71008cea700e`.
The #60 full build and 118 Python tests remain applicable. No unchanged
crash/GPU/full-CPU suite was rerun for this benchmark-only decision.

The evidence remains uncommitted. #62/#63, typed fields, M5/M6 warm/cold
performance and final integration still require completion.
