# Refresh existing slots in private named cache reconciliation

Follow-up to `debebad`. The current cache candidate remains unadopted. Its complete
post-radius-fix cohort has no fixed-ef recall regression but 30/36 warmed timing
regressions. Common-ef distance counts grow 10–13%; high-dimensional selective
profiles attribute approximately 79–86% of query samples to HNSW work.
[Evidence](../benchmarks/2026-10-04-named-cache-final.md).

## Choice and boundaries

Evaluate replacement of an existing slot's prepared vector plus deterministic
local-neighborhood repair **only on the private decoded cache index**. Additions
continue through existing upsert, deletions through existing delete, and the
existing inactive/rebuild policy remains. Public `HnswIndex.upsert` must retain
its tested append/new-current-slot/replaced-history contract.

Full rebuilding retains the measured first-query cost. A separate persistent
base/delta artifact would introduce new coverage/merge/serialization state.
Private repair can reuse existing metric preparation, candidate heaps, neighbor
selection, graph scratch, checked pair distances and optional cache publication.
It must be measured because repairing neighbors can cost more than insertion.

[Hnswlib updatePoint](https://raw.githubusercontent.com/nmslib/hnswlib/master/hnswlib/hnswalg.h)
provides a reference: update the existing vector, repair one/two-hop neighborhoods,
then search/reconnect the point. Akasha's graph contract additionally requires
symmetric adjacency, so all removed links must lose their reverse links and all
new links use the existing bounded `connect_bidirectional` operation. Directly
assigning upstream-style directed neighbor lists is incompatible with that contract.

## Intended implementation

- Factor existing prepared-vector encoding into a storage helper, preserving its
  validation/order and exact bytes. Reuse it for a private same-slot overwrite;
  validate all input encoding before the first vector-tape write. F32/BF16/F16/I8
  and the I8 scale tape must all retain their existing representation.
- Add a narrow private index refresh boundary. It requires an existing current
  slot, prepares/validates the new vector once, keeps slot/ID/level/lifecycle flags
  unchanged and dispatches to the established metric backend.
- For each owned level, snapshot the old one-hop neighbors and their two-hop
  candidate pool. Deterministically order/deduplicate current candidates. For
  each current one-hop neighbor, retain at most the original `ef_construction`
  closest candidates, select its bounded diverse neighbors, remove dropped
  reciprocal edges and connect proposals with existing symmetric pruning.
- Search from the existing entry through upper/base levels using the original
  construction ef. Exclude the refreshed slot from its own result neighbors,
  then replace its adjacency via the same reciprocal-link operations.
- Retain exact build counters. Any failure after mutation quarantines the private
  graph. Existing cache-load failure handling may rebuild from authority; no
  partially repaired artifact may become reader-visible or be saved.
- Use refresh only when stale-cache reconciliation finds an existing ID with a
  changed prepared vector. Source checksums, field identity, kind-5 payload,
  native F64 rerank, snapshots, locks, cancellation checkpoints and publication
  behavior remain as already specified. No new setting, ef adjustment, durable
  authority format or public compatibility path is introduced.

## Verification and decision

First demonstrate on the current cache prototype that replacements add slots;
new tests require unchanged slot count for same-ID cache refresh, no added inactive
slot, correct current vector/results, deterministic graph structure and symmetric
bounded links. Cover entry refresh, sole live point, historical deleted bridges,
repeated updates, native/graph scalar combinations, invalid inputs before mutation,
post-mutation failure quarantine, snapshot and save/reopen behavior. Existing public
mutation tests must still pass unchanged.

Compile and run the smallest affected tests before broader cache, query, codec,
Python/C validation. Keep baseline and candidate source/binaries isolated, use
copied binding entries and saved-package import guards, and retain every failure.
Measure actual repair work and cold/update cost before considering adoption. If
promising, rerun the original full fixed corpus/seed/filter/K/ef/trial lifecycle
curves and relevant public gates. No dropped samples, relaxed recall, changed
thresholds or cross-cell compensation are allowed. A faster first query alone
cannot establish M5/M6 completion. No Linux/nonresident result is available here.
