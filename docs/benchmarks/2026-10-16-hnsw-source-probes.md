# Source lookup probes: fewer probes did not justify adoption

Both prototypes are **rejected**. Production source and the installed Python
extension are restored to `63794d6` (bounded bitmap reads). The first prototype
improves low-dimensional saved-graph ANN throughput but regresses mixed
correlated p95 in all three pairs. Keeping the admission function out of line
does not repair the overall result: both real-data filtered mixed cells regress
in every QPS and p95 pair. No speed acceptance gate closes.

## Hypothesis and compiler evidence

`_CurrentSourceLookup.source_for` first checks dictionary membership, then indexes
it. The parent machine code shares the hash calculation but has two probe chains.
An ordinary `Dict.get(id, 0)` preserves the source encoding: absent = 0, delta =
-1, base = positive slot+1. The existing MemTable lookup uses this pattern.
Pinned Qdrant `point_mappings.rs::internal_id_active` similarly obtains the
value and absence result with `get`; it uses a BTreeMap, not Akasha’s hash table.

Prototype A replaces those reads with one `get` and removes `raises` from
`source_for`. The parent has a 656-byte standalone `_SourceAdmission._allows_item`
symbol; A has no standalone symbol after compiler inlining. Prototype B keeps
the same lookup change and adds `@no_inline` to `_allows_item`. Its standalone
body is 528 bytes and contains one probe chain, retaining the existing base
bitmap bounds check. The first assembly helper incorrectly assumed both
binaries would contain the symbol; its assertion and corrected inspection
are retained. There was no compiler or runtime failure.

A parent standalone symbol does not mean every parent call site was outlined.
B forces outlining globally. These measurements establish different generated
code and different timings; they do not isolate inlining as the cause of any
specific regression. Neither prototype changes graph shape, planner thresholds,
ef, score kernels, source ownership, or durable formats.

## Fixed-input measurements

Both variants compare against the same accepted bitmap binary. Each runs
three serial alternating before/after pairs per corpus on the trial-0 graph
from the bitmap acceptance. Saved-graph timing uses 31 passes over all 67
queries per mode, including the three queries excluded by the formal warm
acceptance. Inputs, graph bytes and ef stay fixed; the extra CPU clock is the
existing diagnostic clock. This is not fresh-build or Qdrant speed acceptance.

Each mixed pair clones the same corresponding trial-0 graph and replays the
frozen bitmap mixed plan. All 36 paired warm cells per prototype preserve
result digests, recall and complete execution statistics. Each prototype’s
18 mixed workers preserve all **5,184 responses**, with identical IDs, recall,
oracle IDs, execution kind and statistics; all 18 reopen checks and 18 Arrow
lease checks pass. Warm digests include result scores; mixed reports do not retain score bits,
so mixed score-bit parity is not independently asserted. Every mixed quality cell passes.

Tables show median after/before QPS / p95 ratios across three pairs. Individual
raw ratios, including every regression and exact-control tail, remain archived.
QPS above 1 and p95 below 1 are improvements; there is no tolerance or cross-cell
compensation. No tests, builds, other benchmark workers, or compression overlap
with a timed worker.

## Prototype A: single lookup

| Corpus | Filter | Saved graph QPS / p95 | Mixed QPS / p95 |
|---|---|---:|---:|
| uniform-128 | all | 1.0708 / 0.9461 | 1.0296 / 0.9401 |
| uniform-128 | correlated | 1.0637 / 0.9225 | 0.9854 / 1.1093 |
| uniform-128 | independent | 1.0384 / 0.9604 | 0.9998 / 0.9835 |
| uniform-128 | selective | 1.0104 / 1.0144 | 1.0740 / 0.8652 |
| uniform-1536 | all | 1.0031 / 0.9984 | 1.0036 / 0.9849 |
| uniform-1536 | correlated | 1.0138 / 0.9908 | 1.0090 / 1.0224 |
| uniform-1536 | independent | 1.0200 / 0.9809 | 1.0078 / 0.9926 |
| uniform-1536 | selective | 0.9941 / 1.0042 | 0.9527 / 1.0863 |
| real-1536 | all | 0.9975 / 0.9995 | 1.0162 / 1.0012 |
| real-1536 | correlated | 1.0167 / 0.9837 | 1.0263 / 0.9608 |
| real-1536 | independent | 1.0018 / 1.0009 | 1.0374 / 0.9220 |
| real-1536 | selective | 1.0018 / 0.9838 | 0.9783 / 1.0433 |

## Prototype B: single lookup with forced outlining

| Corpus | Filter | Saved graph QPS / p95 | Mixed QPS / p95 |
|---|---|---:|---:|
| uniform-128 | all | 0.9970 / 0.9904 | 1.0125 / 1.0079 |
| uniform-128 | correlated | 1.0076 / 0.9708 | 0.9994 / 0.9868 |
| uniform-128 | independent | 0.9919 / 1.0193 | 1.0052 / 1.0224 |
| uniform-128 | selective | 0.9949 / 1.0378 | 1.1528 / 0.3798 |
| uniform-1536 | all | 0.9947 / 1.0083 | 0.9953 / 1.0036 |
| uniform-1536 | correlated | 0.9998 / 1.0040 | 1.0074 / 1.0107 |
| uniform-1536 | independent | 0.9976 / 0.9992 | 1.0056 / 1.0103 |
| uniform-1536 | selective | 1.0014 / 0.9914 | 1.0500 / 0.9025 |
| real-1536 | all | 1.0055 / 0.9946 | 0.9913 / 0.9862 |
| real-1536 | correlated | 1.0115 / 0.9933 | 0.9844 / 1.0472 |
| real-1536 | independent | 1.0100 / 0.9872 | 0.9800 / 1.0462 |
| real-1536 | selective | 0.9956 / 1.0145 | 0.9829 / 1.0368 |

A’s uniform-128 mixed correlated p95 ratios are **1.1048, 1.1355, 1.1093**.
Uniform-1536 mixed selective QPS ratios are **.9726, .9527, .9075**.
B’s real correlated mixed QPS/p95 medians are **.9844 / 1.0472** and
independent **.9800 / 1.0462**; every one of those six pairs regresses in both
metrics. B also loses the low-dimensional warm gains. Exact-control variation
is reported without declaring it noise or attributing it to the lookup change.

## Validation and restoration

A passes **60 distinct Mojo cases** across seven files, **98 source-search
fixtures on both scalar and batched F32 paths**, the Python extension build,
**387 Python/distributed tests** (one skip, three existing warnings), the rebuilt
C client, all four fixed quality checks and both quality smoke tasks.
The source oracle covers single-entry production primitives; it excludes
upper-seed query reuse, native Edge, construction and performance acceptance.
B passes **27 targeted Mojo cases** (source admission and concurrency), both
98-fixture source-search paths and the extension build. Its additional broad
validation script was prepared but not run after the timing rejection.

The source file was restored byte-for-byte against `git show 63794d6:<path>`;
Python binary restoration was checked by SHA-256 (`restored-identity.json`).
The C artifact was rebuilt
from restored source and its client test rerun. Previously applicable parent
validation remains applicable; no fresh full Mojo, crash, GPU or Linux suite
is claimed here. No production code change or new test is retained.

Parent/restored Python SHA-256:
`df71664362253188ef32828dc9d28f315a97eee2a82d76fe0fca43c0396839bb`.
Prototype A: `61b93b8902d892b2fabad45b66bb0e2c7f8c067c12a82ca8a6c853ff67067fcf`.
Prototype B: `54c92c39c48c1d5d9329d0d4a76934f4e28038cd5bb5282db89a7e9b39036242`.

The [separate refreshed concurrent matrix](2026-10-16-concurrent-current.md)
uses the restored parent binary: quality 72/72, strict speed 6/36 for one
client and 12/36 for four. Latest accepted warm speed remains 6/36 and mixed
speed 15/36. Concurrent, platform, capacity/type and sustained nonresident
requirements stay open.

The artifact contains both patches/source snapshots, assembly, raw paired
reports, exact jobs, drivers, source-oracle outputs, validation logs and restore
identities. Large mixed plans, input database files and binaries are identified
by hashes rather than embedded; plan regeneration uses the recorded warm
inputs and deterministic workload. Inputs are the current bitmap snapshots,
not the older graphs used by previous heap experiments.

[Complete artifact](results/2026-10-16-hnsw-source-probes.json.gz), 289 files,
SHA-256 `f7145dbd64ba71668f680dc3cda9089da2ca336584d1ec786ba198e6f49d9d0e`.
