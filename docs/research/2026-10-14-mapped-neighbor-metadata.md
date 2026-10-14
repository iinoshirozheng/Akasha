# Reuse mapped adjacency metadata within a range lookup — not adopted

An isolated prototype reuses one validated node record and count base within
`HnswGraphView.neighbor_range`. It passes **88 Mojo and 369 Python tests**, and
all **54 native warm/mixed workers** finish with identical results and stats.
It is not adopted: warm strict speed changes from 29/36 to 27/36, mixed from
19/36 to 23/36, with **four pass→fail cells** retained. Write+flush remains
3/9 for both versions. Production stays `96e05e2c…`; M5/M6 remain incomplete.

## Scope and evidence

The existing [adjacency-range design](../plans/2026-10-02-hnsw-neighbor-ranges.md)
already locates the edge range once per expanded node. This experiment addresses
repetition *inside* that lookup. At source level, production `neighbor_range`
locates the same node three times, plus twice for every preceding level, through
`neighbor_count`, level validation and the edge-base read. Each node lookup
checks the open owner and slot; readiness also checks mapping byte zero.

Local Qdrant `graph_links/view.rs` at
`74f3e85b9473c62560006c043e13737ce6b48412` computes a level's offset index once
before obtaining its link iterator. That pattern fits local metadata reuse;
it is not evidence about the measured Qdrant Edge 0.8.0 implementation. The
reference file and prior Akasha design are retained in the archive.

The candidate at `.build/m5-resume/mapped-neighbor-metadata` starts from frozen
production, without the rejected visited-mask or earlier reader variants.
Only the `neighbor_range` body in `src/akasha/index/hnsw_view.mojo` changes:

- Preserve negative-level rejection, then validate the slot and obtain its node
  record once. Read the node's maximum level and reject an excessive level.
- Read count base once, then obtain current and preceding counts directly
  through the existing checked copied scalar readers.
- Preserve current-level capacity, edge-ordinal overflow, edge-section
  alignment and full range bounds checks in the original order.
- Keep individual edge reads through `neighbor_at_offset`, including owner/open
  and mapping bounds validation. No pointer escapes, lease change or new cache.

The graph algorithm, adjacency order, source admission, vector arithmetic,
scratch, single-edge API, public bindings and persisted bytes are unchanged.
No new dependency or format migration is needed.

Mojo 1.0.0 (`ed45d567`) emits a standalone range method of 800 bytes / 200
instructions, compared with 688 / 172 before. Its two direct `neighbor_count`
call sites, one in the prior-level loop, disappear; checked scalar-reader calls
remain. The increased method size includes code previously reached through
helpers. These observations establish the emitted change, not a timing cause.

## Validation and all fixed comparisons

The eight targeted Mojo files pass **88 cases**: neighbor ranges 2, mapped
view 9, store 18, v1 compatibility 3, mapped vectors 4, filtered 8, segmented
18 and persistent HNSW 26. Existing tests cover occupied/empty levels, owner
close, invalid offsets, overflow extremes, corruption/truncation, native scalar
storage, source replacement, reopen and owned/mapped equivalence. All **369
Python tests pass**, with three existing warnings and no skips. All 23 compiler
invocations route project source arguments to the isolated copy.

The same frozen corpora, ef, K, filters, oracle, mixed plans and timing boundaries
are used in three rotating before/after/Qdrant triples per corpus and phase.
Builds, tests, benchmarks, assembly inspection and compression run serially.
Every paired ID, Float32 score bit, statistic and execution decision matches;
mixed reopen-oracle and retained Arrow lease checks pass. All samples remain.

| Phase | Quality before / after | Strict speed before / after | Pass→fail / fail→pass |
| --- | ---: | ---: | ---: |
| Warm | 36/36 / 36/36 | 29/36 / 27/36 | 3 / 1 |
| Mixed | 36/36 / 36/36 | 19/36 / 23/36 | 1 / 5 |

Strict speed requires QPS ≥ Qdrant **and** p95 ≤ Qdrant after Recall@10 ≥ .95.
The following zero-based trials change from pass to fail:

- Warm real-1536 all: trials 1 and 2.
- Warm real-1536 correlated: trial 1.
- Mixed uniform-128 selective: trial 0.

All other failing cells remain outstanding; mixed improvements do not offset
warm failures. Write+flush stays **3/9 before and after**.

Real filtered after/before ratios show every trial:

| Phase / mode | QPS ratios | p95 ratios |
| --- | --- | --- |
| Warm / correlated | 1.034 / .690 / 1.128 | .869 / 1.646 / .837 |
| Warm / independent | 1.175 / .593 / 1.028 | .826 / 2.190 / .757 |
| Mixed / correlated | 1.008 / 1.014 / .984 | .984 / 1.024 / .943 |
| Mixed / independent | 1.029 / 1.007 / .983 | 1.046 / .909 / .975 |

Large variations also affect unchanged exact paths: warm uniform-1536 selective
trial 2 has QPS ratio 2.757 and p95 ratio .307; mixed uniform-128 selective trial
0 has QPS .735 and p95 3.170. Their causes are not established. No favorable
sample is generalized into an overall speedup and no unfavorable sample is
discarded. The full matrix does not establish acceptance.

## Frozen evidence and next investigation

Candidate Python SHA-256:
`956228760c53d7f194173e472d54438cda1cfc1c0a4f55ffff0420a74a5b0fbf`.
Production source bytes and Python binary remain unchanged:
`96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c`.

The [raw archive](2026-10-14-mapped-neighbor-metadata.json.gz) contains **779
files, 3,891,252 bytes**, with every embedded hash verified. It includes complete
candidate source, production view, patch, reference, build/validation commands,
compiler audit, assembly, all 54 workers and their raw latencies. The mixed
driver exits 1 only after completing the matrix with failed strict gates.
SHA-256: `9003d62faf223167202709a15c1eb922f263d462c07d788f27a1f806baaa92c4`.

No fresh Linux, capacity/nonresident, C ABI, crash or GPU gate was run for this
unadopted prototype. The [October 2 inline-only archive](../benchmarks/results/2026-10-02-hnsw-neighbor-ranges.json.gz)
already contains forced-inline `validate_search_ready`, ID/level accessors,
neighbor count/access, slot/node/level helpers and u16/u32/u64 readers; its
[reported result](../benchmarks/2026-10-02-hnsw-neighbor-ranges.md) was not adopted.
Do not repeat broad accessor inlining without new evidence. Next investigate
the persistent write/flush gap using existing phase measurements and prior
maintenance experiments before choosing another implementation. All query,
mapped-ownership, HTTP and nonresident requirements remain active.
