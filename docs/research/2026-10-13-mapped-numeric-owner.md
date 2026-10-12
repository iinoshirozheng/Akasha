# Mapped numeric authority: capacity improvement, warm regression

The isolated candidate completes the mapped owner and consumer integration, but is
**not adopted**. Both 1536-dimensional workloads now finish the 128 MiB Linux QEMU
capacity diagnostic that previously OOMed. Native Mac warm speed gates regress
from **21/36 to 15/36**, with six pass→fail cells. M5/M6 remains incomplete.

Production source remains `6d01819`; the implementation started from the frozen
bounded reader under documentation HEAD `bf2d316`. No production binary changed.
The [implementation plan](../plans/2026-10-13-mapped-numeric-ownership.md) remains
the design contract. Work is isolated in `.build/m5-resume/mapped-numeric-owner`.

## Implementation and ownership

All 123 source files are retained; 36 differ from production. The three new modules
are `numeric_read_view`, `mapped_numeric`, and `mapped_vector_file`.

- Each immutable segment has a shared mapping owner with an exact source-file
  lease. Mapping uses a duplicate of the leased descriptor, so path replacement
  cannot switch the inode. Last-owner cleanup unmaps before trying reclamation.
- Native F32/F16/BF16/I8/U8 dense and multivector fields hold checked offsets and
  counts in that owner. Explicit public List getters still publish one stable
  immutable List under a lock. Non-raising legacy getters remain non-raising.
- Legacy and v4 recovery share existing validation/parsing. Public owned decoders
  remain independent of source files. CRC, catalog, sequence, shape and typed finite
  validation precede publication; no format or schema version changes.
- Typed checkpoints stage mapped numeric owners before manifest publication and
  publish them afterward. A local file owner must survive the commit even for a
  tombstone-only checkpoint. Payload, sparse and binary ownership is preserved.
- Exact/rerank, codecs, checksums, batch/parallel, named index projections, Python
  output, Arrow and GPU preparation use internal readers. No internal numeric
  consumer invokes the materializing public getters. HNSW construction still needs
  one transient owned F32 projection per row for its existing derived-index API.
- Parallel workers retain existing arithmetic and capture storage errors per work
  slot, rethrowing before any partial result is returned. Live List bounds and
  mapping-close checks remain in the read boundary.

Arrow preserves the documented single-row borrowing contract, including unaligned
mapped records. Its C Data owner retains the source root before publishing a buffer
address. Multi-row gathers allocate final export-owned buffers and account for them.
An intermediate alignment-copy implementation passed existing tests but contradicted
that documented contract; it was corrected and its source/results remain archived.
Unaligned addresses are permitted by the
[Arrow C Data specification](https://arrow.apache.org/docs/format/CDataInterface.html),
though consumers may choose not to support them. Tests verify PyArrow import/full
validation, exact source address, readonly zero-copy NumPy and surviving slices for
all five scalar types.

## Verification and retained failures

Final Mac Python binary:
`683bd385f6196442c36140e591a22f2eab61b537547d4d40c6eefa26a8be42a5`.
Final C binary:
`0a810e4846ab7d9520882e817c60562d8ec25086d12f7cb7f56c698c5dea7c9b`.

- Full **359 Python** tests pass against the rebuilt isolated package. Compiler
  child processes use the recorded wrapper to select isolated source.
- All **23 crash-recovery** cases pass against the final source, as does the C ABI
  build/test. These did not overwrite the production artifacts.
- Actual Metal validation includes seven existing GPU-cache cases, two GPU-snapshot
  cases and one new mapped-authority case. The new case covers dot/L2/cosine, 3/65
  dimensions, retained roots and zero public List materialization.
- Narrow storage/owner/consumer suites cover descriptors and leases, concurrent first
  List access, all numeric types, legacy/v4 fixtures, corruption/preflight, typed
  checkpoint rebasing, acquired snapshots, retirement and concurrent close. Four
  expected negative compile diagnostics preserve readonly/borrow boundaries.
- The ledger retains 355 runtime cases across 67 latest-passing suite paths, including
  crash and GPU cases. These are **stage-specific results**, not a claim that the
  entire CPU suite was rerun on the final source.

One original point-compaction test expected source files to disappear after a
generation unpin even while an open PointStore now owns mapped rows. The isolated
test explicitly checks the additional source lease, reads through it, then closes
the store and requires reclamation. Its first three cases are unchanged. The
unchanged original failure is retained; it is not reported as an original-suite pass.

A separate real bug found during that suite deleted a tombstone-only checkpoint
before manifest commit because Mojo eagerly destroyed the last local mapping owner.
The explicit post-commit last use fixes it. Earlier fixture/compile errors, the first
mixed-source retirement run and corrected wrapper runs are retained in the artifact.

## Linux capacity diagnostic

Same 123 source hashes compiled under the existing Linux x86-64 QEMU environment:
`f68718dcb7f0c8091a54ba7615c35f350aac735e5dc7e1c32c5e1a4ada46ff64`.
Each serial worker has one CPU, zero swap and its own fresh copied database in the
existing dedicated volume. The build container is stopped before worker execution.
No user container was changed.

| Corpus | Limit | Open anon MiB | After checks anon MiB | Result |
|---|---:|---:|---:|---|
| real-1536 | 6 GiB | 114.24 | 122.81 | Passed |
| real-1536 | 128 MiB | 104.66 | 112.98 | Passed; previously OOM |
| uniform-1536 | 6 GiB | 112.34 | 119.06 | Passed |
| uniform-1536 | 128 MiB | 104.50 | 112.80 | Passed; previously OOM |
| uniform-128 | 128 MiB | 84.47 | 92.72 | Passed |

Each worker checks 268 exact and 268 ANN queries: **1,340 of each in total**.
All ANN IDs, F32 score bits, recall, execution decisions and statistics equal the
prior successful diagnostic. Previously OOMing 128 MiB cases use the prior 6 GiB
result for that equality comparison. Fixed repeated queries are not independent
recall samples.

The previous instrumented 6 GiB controls opened with 162.61/162.45 MiB anonymous
memory for real/uniform-1536. These process-wide figures include Python, QEMU,
runtime and allocator behavior; the difference is not an allocation census. Total
RSS did not fall in the unrestricted real control: 231.45→238.93 MiB, because the
mapped file pages can remain resident. Capacity under pressure is the observed gain.

Residency now identifies committed numeric authority segments separately from the
derived HNSW file, using the committed manifest. After the 128 MiB checks, weighted
authority-file residency is **19.0% / 19.4%** for real/uniform-1536, and HNSW residency
is **0%** in both. These are whole-file page-cache snapshots, including metadata and
inactive records. They establish neither sustained working-set behavior nor a speed
gate. This diagnostic has no timed comparison or same-cap Qdrant worker and is not
native Linux performance evidence.

## Native warm comparison

The unchanged three corpora, oracle, filters, k, ef and timing boundary are used in
three rotating before/after/Qdrant triples per corpus: 27 serial workers. Both Akasha
versions pass quality in all 36 cells; their IDs, F32 bits and search statistics match.
The strict speed gate still requires QPS ≥ Qdrant **and** p95 ≤ Qdrant in every cell.

| Corpus | Trial | Mode | QPS after/before | p95 after/before |
|---|---:|---|---:|---:|
| uniform-128 | 0 | independent | 0.882 | 1.351 |
| uniform-128 | 2 | independent | 0.518 | 2.677 |
| uniform-128 | 2 | selective | 0.759 | 1.431 |
| uniform-1536 | 0 | selective | 0.874 | 1.164 |
| uniform-1536 | 1 | selective | 0.739 | 1.516 |
| real-1536 | 2 | all | 0.973 | 1.016 |

These are all six pass→fail cells; none is excluded as noise or offset by capacity
improvement. Uniform-128 full-scan QPS ratios are 0.647/0.660/0.634;
uniform-1536 full-scan ratios are 0.666/0.670/0.667. There is no mixed comparison yet.

Targeted disassembly records `_search_candidates` growing from 4,456 to 45,884 bytes.
Production also has twelve separately emitted score kernels; including those, the
selected code grows from 14,580 to 45,884 bytes. `_ensure_open` is already inlined at
these callsites. This is a lead for profiling, not proof that code size alone explains
the slowdown. The next optimization must preserve validation and arithmetic order.

## Remaining work and evidence

The candidate remains isolated. Legacy live WAL replacements stay owned until reopen;
legacy flush/compaction does not rebase the current table onto its new output. Exact
file owners can retain obsolete source files until their last use. Typed checkpoint
rebasing resets the read publisher, whose next-capture cost is not yet measured under
mixed load. Fixing warm regressions, completing those write/ownership paths, sustained
nonresident and same-cap comparisons, mixed/concurrent gates and final integration
remain required. No M5/M6 completion claim follows from this implementation.

[Raw source, tests, failures, reports and disassembly](2026-10-13-mapped-numeric-owner.json.gz)
contain 6,819 files, 38,819,921 compressed bytes, SHA-256
`b33ccbe7883d3d67b1080fc1843fb498d26d44301257077f8a1067549902fdfa`.
Compiled binaries and copied databases are excluded and identified by hashes;
compiler wrapper, pinned environment, complete source/package text and query inputs
are included. The final checkpoint is `checkpoints/final-borrow-contract`; earlier
checkpoints and build-first are deliberately retained as intermediate states.
