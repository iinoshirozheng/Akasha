# Non-raising mapped current predicates — both variants rejected

Keep [deferred-ID](2026-10-20-immutable-point-deferred-id.md) as the retained
implementation. A bounded Boolean byte predicate removes error construction
from current-slot checks, but neither its automatic-inline form nor a fixed
outlined control gives a consistent improvement in the outstanding mixed cells.
Production `src` remains `a6822c3`; the last strict mixed result remains **25/36**.
These screens do not close any M5/M6 gate.

## Source basis and change

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d`,
`lib/segment/src/vector_storage/raw_scorer.rs`, implements `NotDeletedChecker`
with bounded bit lookups. It checks vector deletion before point deletion, with
different defaults for absent vector and point flags. Its `check` wraps the
Boolean result in `Ok`; it does not construct an error for a missing flag.
`point_scorer.rs` applies this deletion check before its optional payload filter.
Neither function substitutes a declared live count for individual flags.

Akasha's retained `HnswGraphView.is_current` instead calls a raising bounded
scalar load and catches the error to return false. The exact retained native
function reserves **144 stack bytes** and includes error-stack construction and
an Optional-unwrapping panic path. This establishes a concrete code-generation
opportunity, not its elapsed cost.

Both isolated candidates start from all **132 deferred-ID source files** and
change only `storage/mapped_file.mojo` and `index/hnsw_view.mojo`:

- A private, inlined `MappedFile._byte_equals` returns false for a closed owner,
  negative/out-of-range byte offset or absent base pointer. Otherwise it returns
  exact equality of the copied byte. No pointer or borrow escapes.
- `is_current` preserves the original early open/slot check before computing the
  record address, then calls the bounded predicate with `_CURRENT_FLAG`.
- The outlined variant adds only `@no_inline` to `is_current`. No other source
  byte differs from the final automatic variant.

The change adds no fields, caches, source-bitmap substitution, dependencies,
configuration, formats or scoring changes. Validation order, current/deleted/
replaced classification, public owned getters, query locks and file ownership
remain intact. The mapped-view docstring is corrected to describe bounded reads
rather than claiming every access uses `byte_at`.

## Verification and code generation

Each final variant passes the same **89 distinct CPU cases in 12 modules**.
This is 89 unique cases, not 178. Coverage includes all 256 current-flag bytes,
all byte-value/expected-value combinations, slot/byte bounds, empty and closed
mappings, move/close ownership, misleading declared live counts, search/stats,
mapped vectors, filtered delta admission, and v1/v2 sidecar compatibility.
The six current-flag contract cases also pass against unchanged deferred-ID.

The first validation invocation omitted an existing test helper from the
isolated directory; its compile failure is retained. Copying the unchanged
`test_deferred_id.mojo` helper fixes it. An intermediate revision passed 88
cases; inspection then restored the original early-open ordering and added its
explicit contract case. All 89 cases were rerun on each final source. Intermediate
and repeated runs do not increase the unique count.

Exact-binary disassembly confirms the intended differences:

| Observation | Deferred-ID | Automatic predicate | Outlined predicate |
| --- | ---: | ---: | ---: |
| Standalone `is_current` instructions | 95 | Inlined | 23 |
| Linear instructions through its first return | 25 | — | 21 |
| Its stack reservation | 144 bytes | — | 0 |
| Calls to it in mapped filtered F32-dot `score_points` | 1 | 0 | 1 |
| Instructions in that scorer instantiation | 1,000 | 993 | 1,000 |
| Explicit `sub sp` reservation in that scorer | `0x9d0` | `0x9e0` | `0x9d0` |

The automatic scorer contains the flag load and bounds checks inline. The
outlined function has no calls, stack-pointer instructions or error-stack
construction. The 95→23 total includes cold/error paths; it is not a claim that
72 instructions disappear from every successful read. Static shape alone does
not identify the cause of either whole-query timing result.

## Fixed mixed screens

Each variant runs the original three corpora in both serial orders against the
same retained parent: **12 workers / 3,456 timed responses**. Across both variants,
all **6,912 responses, 24 exact reopens and 24 retained Arrow leases** pass.
Every response preserves baseline IDs, F32 score bits, stats, route, recall and
oracle. The **72 warmup return values are not compared**. Builds, validation and
workers run serially, with no measurement overlap.

Each worker imports the selected native binary explicitly and verifies the
Python facade resolves that exact module. All source/native/workload/plan
identities are checked. Independent recalculation from every raw latency
reproduces reported QPS, nearest-rank p95, pair ratios and medians. Replaying
both latency auditors from the final archive alone produces identical results.

Median candidate/parent ratios below retain all controls and both orders.
Higher QPS and lower p95 are better.

| Corpus / mode | Automatic QPS | Automatic p95 | Outlined QPS | Outlined p95 |
| --- | ---: | ---: | ---: | ---: |
| uniform-128 / all | .9835 | 1.0347 | .9842 | 1.0247 |
| uniform-128 / correlated | .9749 | 1.0278 | .9963 | 1.0231 |
| uniform-128 / independent | .9769 | .9950 | .9990 | 1.0026 |
| uniform-128 / selective | 1.0139 | .9301 | .9927 | 1.0068 |
| uniform-1536 / all | .9858 | 1.0061 | 1.0087 | .9952 |
| uniform-1536 / correlated | .9692 | 1.0200 | 1.0160 | 1.0145 |
| uniform-1536 / independent | .9685 | 1.0284 | 1.0121 | .9783 |
| uniform-1536 / selective | 1.0089 | .9539 | 1.0191 | .9681 |
| real-1536 / all | .9816 | 1.0199 | .9963 | .9910 |
| real-1536 / correlated | .9814 | 1.0229 | .9926 | 1.0049 |
| real-1536 / independent | .9809 | 1.0033 | 1.0003 | .9726 |
| real-1536 / selective | .9987 | .9960 | .9916 | .9174 |

The automatic form lowers uniform-1536 correlated/independent QPS and raises
both p95 values in **both orders**. The outlined control improves target QPS,
but its reverse-order target p95 ratios are **1.0657 / 1.0485**. Its uniform-128
all QPS falls in both orders, while real ANN QPS changes sign by order. The
outlined results do not establish a stable gain in both target metrics.

**Reject both variants.** No fresh strict Qdrant comparison, full Python/crash/C
suite or Linux/GPU gate is claimed for these rejected screens. No ef adjustment,
dimension exception, sample exclusion or threshold relaxation is introduced.
The remaining eight speed failures, three Qdrant real-correlated quality
failures and all other open M5/M6 requirements remain.

Next inspect repeated admission checks and Qdrant's query-local filtering
implementation before choosing another change. Preserve rejection counters,
cancellation/error precedence and current-source semantics. Do not repeat
these two byte predicates, copied node metadata, or the rejected level-skip
probe without new evidence.

## Reproduction evidence

The [verified archive](2026-10-22-immutable-point-current-predicate.json.gz)
contains **542 text artifacts, 2,161,696 bytes**, SHA-256
`459372123f84619a4a571b7aacb77784ca4b850160f78081d9c4cc94796fab1f`.
It includes both full source/package trees, tests and logs, all 24 raw reports,
baseline responses, native-symbol/disassembly records, pinned reference sources
and license, drivers and decision audits. Frozen plans are verified byte-for-byte
against the existing head-projection archive rather than duplicated; their
archive/key/hash references and workload hashes are retained. Binaries and
database copies are excluded and identified by hash.

Native hashes:

- Parent: `64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`
- Automatic: `b5495958063c4233eb369e294286fca87713f4c1a4a97d5be2b028f6e5b4b260`
- Outlined: `97c8c31662e634806ebed13a884080ec0383b3f8300147a128a0c7e528261a89`

The previously running outlined driver was confirmed terminal with exit code
zero when work resumed on October 22. No timed worker was restarted for the
resume, archive audit or this report.
