# Immutable-value certificates for graph-score reuse

The new isolated candidate improves the same-batch mixed comparison from
**24/36 to 28/36** strict cells, with no pass-to-fail. Full fixed-graph warm
remains **12/36**, with one gain and one loss. All selected quality gates and
mixed write-plus-flush gates pass. Keep this candidate for further work;
production adoption and overall M5/M6 acceptance remain open.

## Reference and design

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d`
[uses vector storage for its HNSW scorer](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/hnsw_index/hnsw/read_view/search.rs)
and [requires quantization for its extra rescoring branch](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/vector_index_search_common.rs).
Akasha permits graph snapshots with values different from current authority.
The [previous experiment](2026-10-23-immutable-point-score-reuse-proof.md)
showed that comparing every vector's bytes on every query costs more than
recomputing. This implementation amortizes that proof across queries sharing
the exact immutable value owner.

Mojo 1.0.0 already provides
[WeakPointer](https://mojolang.org/1.0.0/docs/std/memory/arc_pointer/WeakPointer/)
in `std.memory.arc_pointer`. The versioned
[stdlib implementation](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/memory/arc_pointer.mojo)
keeps a weak control allocation after destruction of the value. `try_upgrade()`
and `ArcPointer` identity establish that the exact same value is still alive;
the certificate does not retain its vector buffer or mapped file. No raw address
or sequence number serves as the proof of value identity.

Only `index/segmented_hnsw.mojo` changes relative to the retained
[adjacency candidate](2026-10-23-immutable-point-neighbor-gather.md):

- Base candidates carry their already-computed scores through the same query.
  Only F32 Dot/L2 are eligible; delta, cosine and compact representations retain
  the existing authoritative scorer.
- Each immutable base slot lazily stores a weak value owner and an equality
  result. A new owner requires a bounded synchronous byte comparison and a
  finite-value check. Equal and unequal results both apply only to that owner.
  Replacing the base source resets certificates.
- Only pairs with two valid certificates reuse graph scores. Other pairs and
  single tails use the established scorer. Acquisition, candidate offering,
  first-error and partial-counter order remain unchanged.
- Query scores never persist in the cache. Public rerank statistics retain
  their logical candidate-count meaning; they no longer imply an equal number
  of arithmetic recomputations. A private counter records actual reuse.

No vector data borrow escapes the synchronous comparison. The source relies on
the existing immutable-base and immutable-value contracts; arbitrary private
graph mutation is not a supported publication path. Durable formats and public
APIs do not change.

## Correctness validation

The frozen candidate compiles with Mojo **1.0.0 (`ed45d567`)** and passes
**135 cases in 19 modules**. Eight new cases cover owned/mapped Dot/L2 across
dimensions 1, 3, 17, 64, 65, 128 and 1536; filtered and unfiltered score bits;
changing queries; replacement at the same ID/sequence; expired weak owners;
different/restored bytes; unsupported representations; and reused prefixes
followed by errors. Compaction owner exchange reclaims an old mapped file while
its weak certificates remain alive, then refreshes certificates on later queries.

A red test caught a real prototype defect: identical NaN bits were initially
accepted as proof. The final implementation validates finiteness before issuing
a positive certificate. It preserves the original error precedence and partial
lookup count, including an earlier successfully reused pair.

All initial compiler/fixture failures are retained. One validation driver was
still live when its source was corrected; a standalone test briefly overlapped.
That entire run was terminated and discarded, then all 19 modules reran
serially against the final frozen source. No timing worker overlapped builds,
tests or compression. The final native build and validation inventories match
all 132 source files. Broader CPU/Python/crash/C ABI/example validation has not
yet been repeated for this candidate; earlier parent results are not a new pass.

## Full comparisons and remaining failures

The authorized **Qdrant real-1536/correlated ef=128** is the sole parameter
change from the original benchmark contract. Akasha parameters and per-cell
Recall ≥ .95, QPS ≥ Qdrant, p95 ≤ Qdrant gates remain unchanged. Old ef=96
failures remain archived. No samples are removed or replaced.

| Same-batch version | Mixed quality | Mixed strict | Write + flush | Warm quality | Warm strict |
|---|---:|---:|---:|---:|---:|
| Production | 36/36 | 24/36 | 9/9 | 36/36 | 7/36 |
| Prior adjacency | 36/36 | 24/36 | 9/9 | 36/36 | 12/36 |
| Weak certificate | 36/36 | **28/36** | 9/9 | 36/36 | **12/36** |

Mixed adds uniform-1536 correlated/independent trials 1 and 2, with no loss
against either control. Its eight remaining failures are uniform-128 all,
correlated and independent trial 2; uniform-1536 correlated/independent trial 0;
and real-1536 correlated in all three trials.

Warm adds uniform-1536 independent trial 2 but loses uniform-128 selective
trial 1 against the prior candidate. The latter retains QPS/Qdrant **1.0363**
but p95/Qdrant **1.1225**. The selective exact scorer is unchanged; the cause of
the observed slowdown is unresolved. It remains a failed gate, not an excluded
outlier or a presumed noise result.

Ratios below compare candidate with the **same-batch prior adjacency** version.
They are three-trial medians for diagnosis, not substitutes for strict cells.
Higher QPS and lower p95 are better; all regressions remain visible.

| Corpus / mode | Mixed QPS | Mixed p95 | Warm QPS | Warm p95 |
|---|---:|---:|---:|---:|
| uniform-128 all | 1.0125 | .9688 | 1.0008 | 1.0189 |
| uniform-128 correlated | 1.0033 | .9798 | 1.0288 | 1.0137 |
| uniform-128 independent | 1.0122 | 1.0105 | 1.0421 | .9881 |
| uniform-128 selective | .9895 | 1.0007 | .8923 | 1.2078 |
| uniform-1536 all | 1.0162 | .9752 | 1.0256 | .9729 |
| uniform-1536 correlated | 1.0822 | .9177 | 1.0822 | .9621 |
| uniform-1536 independent | 1.0784 | .9202 | 1.0969 | .9520 |
| uniform-1536 selective | .9704 | 1.0287 | 1.0095 | 1.0276 |
| real-1536 all | .9860 | 1.0085 | 1.0105 | 1.0071 |
| real-1536 correlated | 1.0218 | .9991 | 1.0770 | .9455 |
| real-1536 independent | 1.0144 | 1.0544 | 1.0573 | .9419 |
| real-1536 selective | .9666 | 1.0779 | .9990 | .9369 |

Real correlated remains the clearest high-dimensional gap: candidate/Qdrant
QPS is **.7634–.8010** in mixed and **.6163–.6334** in warm; all six p95
comparisons also fail. Removing some duplicate scoring helps but does not close
this gap. Low-dimensional ANN and selective tails also need further diagnosis.

The paired mixed screen uses both process orders. Each full comparison uses
36 serial workers with three of four order rotations, not a fully balanced
four-trial design. Mixed reuses the frozen trial-0 graphs for all three trials;
warm uses each corresponding trial's frozen graph and the full 12-ef grid.
Neither reruns graph construction. Warm stores VM, swap and thermal snapshots;
this is not a zero-swap or nonresident capacity claim.

Across screen, mixed and warm, **84 workers / 124,416 measured responses**
preserve expected IDs, F32 bits, stats and routes. All 84 exact reopens and
39 retained Arrow leases pass. Warm additionally checks 9,648 exact preflight
responses and 5,184 warmup returns. The 144 mixed/screen warmup returns are
not compared. Auditors recompute latency summaries, quality and every selected
gate from retained raw samples.

## Evidence and continuation

The [archive](2026-10-23-immutable-point-score-certificate.json.gz) embeds
**560 artifacts / 37,828,273 compressed bytes**, SHA-256
`646e9979e60729ff2df1391273f794640b795c6a64e66d18f4c5429de7a41378`.
It includes the complete candidate source, parent difference, tests and failed
attempts, raw reports, input identities, reference source/licenses, decisions
and all auditors. Native binaries and database files are hash-identified rather
than embedded. Candidate native SHA-256 is
`5ae85379b8948276ac2aba0e0fa1fd86447989c499562cc57fa1411b50c936fc`;
prior adjacency is
`4835cc3b6929a82a36a0f42ed03488db6e13cdce2248c7e3e0b9d13922968ecf`.

Extract the archive's `files` text entries and run
`audit_archive.py ARCHIVE`. It verifies embedded hashes/source differences,
validation counts and all three timing audits, reproducing four audit outputs
byte-for-byte without engine binaries or databases. Timing reproduction scripts
require the original hash-matched inputs and the recorded Mojo environment.

Continue from this isolated candidate, first diagnosing the low-dimensional
selective regression and the remaining real filtered traversal cost. External
clients, sustained nonresident capacity, broader integration and complete
performance gates remain open. Native Linux is deferred by the user, not passed.
Production `src` remains at `a6822c3`; this report does not claim adoption.
