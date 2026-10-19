# Mapped numeric consumers: validated, with failed speed gates retained

The isolated candidate now reads mapped numeric owners through Arrow export,
Python value conversion, GPU upload and legacy recovery without filling public
List caches. It also fixes retry of deferred PointStore file cleanup on a no-op
flush. This extends the [live compaction layer](2026-10-20-immutable-point-live-compaction.md).
Production remains `a6822c3`; the candidate is **not adopted**. Fresh mixed tests
pass 18/36 candidate quality-plus-speed cells versus 25/36 for production, with
nine production passes becoming candidate failures. M5/M6 remain open.

## Qdrant source and implementation

The reference remains Qdrant commit `21db2f3ff95d50de3a2b88a741312c056fd1762d`:

- [`appendable_dense_vector_storage.rs`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/dense/appendable_dense_vector_storage.rs#L81)
  exposes dense values as `Cow` and borrowed batch callbacks.
- [`read_only/read_ops.rs`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/chunked_vectors/read_only/read_ops.rs#L51)
  checks ranges before reading and supports borrowed/owned results and batch access.

The exact files, their hashes and Apache license are archived. Akasha applies the
borrowed-read boundary to its existing immutable owners and Mojo origins. This
does not implement Qdrant's entire chunked-storage or asynchronous read pipeline.
Seven source files change from the verified live-compaction parent:

- Single-row Arrow numeric exports acquire the read root before publishing the
  checked source address, including unaligned mapped values. Multiple-row exports
  gather directly into the final budgeted Arrow allocation. No alignment-copy
  fallback or ownerless public pointer API is added.
- Python conversion allocates the requested Python result directly from numeric
  readers; GPU upload fills its required device buffers through the same reader.
  Existing SIMD norm calculation order is retained.
- Legacy preflight maps each immutable segment once through the existing shared
  parser and the collection's exact-file lease registry. Both migration branches
  forward that registry; supplied directory/dimension mismatches are rejected.
  Newer WAL values stay owned. Migration checks finite values without an eager
  public List allocation. Public owned segment decoders and v4/v5 bytes remain
  unchanged.
- PointStore retries its retired-file queue during checkpoint preparation,
  including when no new writes require a checkpoint. Previously that queue was
  retried only when a checkpoint completed, leaving a failed last-owner cleanup
  pending indefinitely across no-op flushes.

The 130-file source audit finds no materializing numeric getter calls outside the
public getter implementation. It records 16 explicit owned-result/index projection
sites rather than calling the entire engine zero-copy. Public document results,
HNSW/IVF projections, final Arrow gathers and GPU buffers still allocate.

## Validation and failure investigation

Mojo `1.0.0 (ed45d567)` compiles the candidate. The final source inventory is shared
by the CPU/recovery checks, rebuilt Python/C libraries and mixed workers:

- **151 distinct cases in 34 selected CPU modules**. The first 23 modules pass in
  the aggregate; the process lease module passes standalone and the remaining
  ten modules pass in a continuation runner. No duplicate runs add coverage.
- **23 checkpoint/WAL recovery cases** in eight modules.
- **379 Python cases**, with the candidate library verified in all four launcher
  processes, including spawned clients. The pinned Qdrant adapter is included.
  Static repository-source probes still inspect repository source; the separate
  C build below establishes candidate ABI behavior.
- **Candidate C ABI**: shared-library build, strict C11 compile and execution pass.
- **12 actual Metal cases in four GPU modules**, covering mapped uploads and
  existing cache/snapshot/flat-scan behavior. This successful run predates only
  the subsequent PointStore cleanup-retry change; GPU/reader sources and its test
  hashes are unchanged, so the applicable result is reused.

Three export test cases cover all five numeric types, dense/multivector Python
results, 40 typed Arrow combinations and four legacy Arrow combinations. They
check exact source addresses, deliberately unaligned offsets, final gather bytes,
budget rejection, full PyArrow validation, read-only NumPy views, surviving slices
and zero materialization. These combinations are not counted as additional cases.

The five new legacy recovery cases cover mapped segments versus newer owned WAL
rows, migration/replacement writers, held rows and snapshots, sparse corruption
before WAL repair, registry identity, mixed typed-WAL reopening and cleanup retry.

Retained failures distinguish product changes from harness corrections:

1. Export and GPU tests first detect unwanted List materialization; legacy
   preflight tests first detect owned recovered rows. Borrowed readers and shared
   mapped preflight resolve those failures.
2. A copied graph test uses an obsolete private call signature; it now supplies
   the current gathered rows without changing its behavioral assertions.
3. The cleanup fixture initially allows Mojo to destroy an unused owner before
   manifest corruption. Reading the held row after injection establishes the
   intended lifetime. That exposes the actual no-op-flush retry defect; adding
   the queue retry makes the original diagnostic/preservation/deletion assertions
   pass. Both failing fixture versions and logs are retained.
4. The aggregate process-lease test restarts `argv[0]`, which points to the entire
   aggregate and omits its include paths. Compiling the original standalone test
   against the candidate lets both reader and writer execute that same binary.
   All nine module cases then pass; the failed aggregate remains archived.

Python library SHA-256:
`6d79488ed304611ad02c502f123c0108a435e25198ee5e74c25fbdd34e404ba2`.
C library SHA-256:
`0d942c7744bf1c6acd100aa014647827350e08493ea98d04afee4e4d4c03bb68`.

## Fresh fixed mixed comparison

The unchanged three-corpus plans run in 27 serial workers: production, candidate
and pinned native Qdrant Edge 0.8.0, with rotating engine order across three trials.
Every worker executes 32 blocks of nine reads, eight point updates and a flush.
No builds, tests, profiling or compression run alongside timed workers. Workloads,
ef values, oracles and the zero-tolerance per-cell gates are unchanged.

All **7,776 responses**, **27 exact reopens** and **18 retained Arrow leases** pass
their audits. Production/candidate pairs match IDs, F32 score bits, query statistics
and execution decisions. All 36 cells for each Akasha variant meet Recall@10 ≥ .95.
Matched quality passes 33/36: Qdrant's real-1536 correlated recall is 0.945833 in
each trial versus Akasha's 0.980556. Those three cells remain failed; their samples
are not removed or retuned.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 25/36 | 9/9 |
| Candidate | 33/36 | 18/36 | 9/9 |

Candidate/production median ratios within this batch follow. QPS is better above
1; p95 is better below 1. These summaries do not replace any individual trial.

| Corpus | Mode | QPS ratio | p95 ratio |
| --- | --- | ---: | ---: |
| uniform-128 | all | 0.864 | 1.016 |
| uniform-128 | correlated | 0.944 | 0.986 |
| uniform-128 | independent | 0.936 | 1.015 |
| uniform-128 | selective | 0.585 | 0.948 |
| uniform-1536 | all | 0.989 | 1.014 |
| uniform-1536 | correlated | 0.984 | 1.018 |
| uniform-1536 | independent | 0.962 | 1.013 |
| uniform-1536 | selective | 0.970 | 1.075 |
| real-1536 | all | 0.838 | 1.324 |
| real-1536 | correlated | 0.960 | 1.006 |
| real-1536 | independent | 0.964 | 0.892 |
| real-1536 | selective | 0.702 | 0.986 |

The nine pass-to-fail cells, with zero-based trials, are uniform-128 trial 0
all/correlated/selective, trial 1 all/correlated, trial 2 all; uniform-1536 trial 0
selective; real-1536 trial 0 selective and trial 1 all. Two failures become passes
(uniform-128 trial 1 selective and real-1536 trial 0 independent); they do not
offset those regressions. Historical results from other timing batches remain
separate.

Combined update-plus-flush passes all nine trials for both Akasha variants.
Candidate flush-time median ratios are 1.031/1.019/1.011 versus production.
Individual update calls are not durability-equivalent: Akasha accepts after WAL
fsync, while Qdrant Edge synchronizes WAL/segments in its separate flush. This is
serial resident evidence, not a sustained-maintenance or concurrent-client gate.

A post-hoc diagnostic retains 53 candidate queries taking at least 1.5 ms longer
than their production counterparts. They occur in blocks
4/7/10/13/14/16/19/22/25/28/31; several add about 2 ms. No sample is excluded.
Background publication and writer-lock contention are hypotheses to measure next,
not proven causes. The source still stages read-run ownership under writer during
live compaction; compare its measured lock duration with the previously archived
Qdrant publication design before changing that path.

## Remaining work and evidence

The consumer/lifetime layer has relevant functional validation, but the candidate
still fails performance acceptance. Next isolate publication stalls and mapping
costs, then rerun the unchanged strict cells. Full warm/concurrent validation,
sustained nonresident capacity under equal caps, remaining integration/example
checks and native Linux performance remain open. Native Linux requires native
hardware; Docker/QEMU evidence cannot satisfy it. No production adoption or full
M5/M6 completion is claimed.

The [evidence archive](2026-10-20-immutable-point-consumers.json.gz) contains the
complete candidate, patch against the verified parent, all failure/success logs,
test/source inventories, Python sources, Qdrant reference files, protocol plans,
27 raw worker reports and per-trial failed gates. It excludes native binaries and
copied databases. All embedded hashes and the parent inventory were verified:
572 text artifacts, 16,871,020 compressed bytes, SHA-256
`5b6d420c18da13c8f358f94ae240bcd508b8d380730778c31ef04b39206f6a7b`.
