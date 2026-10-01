# Reuse the checkpointed HNSW delta on reopen

Phase timing on the fixed three post-mutation corpora attributes about 0.59 / 1.46 /
1.11 seconds to overlay reconstruction. It dominates resident reopen; SIMD row loading
and checksum changes cannot remove this graph construction work.

Reuse the existing AKIC derived-cache envelope and HNSW snapshot v1/v2 codec.
A new cache kind 3, `hnsw-overlay.cache`, contains the complete mutable delta graph
(including inactive slots). The envelope binds dimension, latest sequence and retained base checksum; its
generation must not exceed the recovered generation, allowing compaction without
vector changes. The inner snapshot binds full HNSW config and retained base sequence. No authoritative manifest/WAL/segment format changes.
Existing readers reject the unknown derived kind as a miss.

Publish best-effort after a successful checkpoint, for legacy and point authority.
Recovery validates the entire graph, then verifies exact current delta ID coverage
and prepared vector representation against authority before adoption. Reconstruct
base deletions/source bindings from authority. Missing, stale, truncated, corrupt,
wrong-base/config/ID/vector caches follow existing authority replay. Cache bytes are
bounded before reading; backup/restore correctness does not depend on the cache.
No cache is published as part of recovery preflight.

Validation: first prove the existing code rebuilds delta on reopen, then cover cache
reuse with replacements/deletes/reinsertions, both authorities, native graph scalar
identities, WAL after checkpoint, damaged/unknown cache bytes, forged valid CRC
payloads, failed cache publication, compaction and backup. Run affected snapshot,
recovery, checkpoint/crash, Python and C gates. Measure paired resident reopen and
mixed workloads including the extra checkpoint write cost; retain every slow sample.

Local reference: Qdrant `lib/segment/src/index/hnsw_index/graph_layers.rs` loads
persisted graph links and uses atomic graph artifact publication. Akasha's existing
snapshot codec provides the matching validation and native representation contract.

The first prototype bound the full physical MemTable checksum and exact generation.
Its isolated reopen improved but all mixed-workload reopens missed after compaction:
row order/tombstone removal and background generation changes invalidate that key.
A new regression reproduces it. The final key instead uses the retained base CRC,
latest sequence and full delta coverage/vector checks; compaction can preserve a
valid older-generation cache. The initial prototype and all timings remain archived.


The additional checkpoint write has a measurable cost. A serial encoding probe
retained every structural/vector/CRC check and compared complete output bytes.
Bulk copying the validated F32 tape reduced 1536D encoding from about 15–16 ms
to 10–12 ms. The production change applies only to F32: `BinaryWriter.write_f32s`
copies native bytes on little-endian targets and uses the prior scalar encoding
on big-endian targets. Compact vector serialization is unchanged. The independent
writer test includes signed zeros, subnormals, infinities and a NaN payload; codec
validity checks still reject invalid graph values before this byte copy.


Mixed measurement after fixing the key confirms cache hits through compaction,
but flush latency still increases. Compaction's second publication was encoding
exactly the same delta again. Record only a successfully published sequence/base
sequence/base CRC in the collection, reuse it through compaction, and leave a
failed attempt retryable. A regression first verifies the previous envelope was
rewritten solely to change generation, then requires byte-identical reuse.
