# Phase 12 Quantization, CPU Parallelism, and Persisted Indexes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add deterministic SQ8/PQ search, single-query CPU parallel scan, and rebuildable persisted HNSW/metadata caches without changing AkashaDB's authoritative WAL/segment semantics.

**Architecture:** Quantized indexes are immutable derived views built from a read snapshot. SQ8 stores per-dimension affine ranges and byte codes; PQ stores a versioned deterministic k-means codebook and subvector codes. Approximate scores produce candidates and optional exact rerank uses the snapshot's Float32 vectors. Parallel flat scan uses fixed ordinal ranges, one bounded heap per range, and an ordinal-ordered merge. HNSW and metadata cache files contain a versioned header, source generation/sequence fingerprint, bounded payload, and CRC32; load failure or mismatch rebuilds from authoritative collection state and atomically republishes the cache.

**Tech Stack:** Mojo 1.0 stable, `max.algorithm.parallelize`, Akasha binary codec/CRC32/filesystem primitives, Pixi, Mojo test framework.

---

### Task 1: SQ8 codebook and codec

**Files:**
- Create: `src/akasha/index/quantization.mojo`
- Modify: `src/akasha/index/__init__.mojo`
- Modify: `src/akasha/__init__.mojo`
- Test: `tests/mojo/test_quantization.mojo`

**Steps:**
1. Add failing tests for dimension validation, finite inputs, deterministic byte codes, constant dimensions, encode/decode error bounds, and version identity.
2. Run `mojo run -I src tests/mojo/test_quantization.mojo`; confirm missing symbols fail.
3. Implement `Sq8Codebook` with per-dimension minimum/scale arrays and `Sq8Index` with stable point IDs and row-major `UInt8` codes.
4. Add dot, squared-L2, and cosine approximate scoring with deterministic Top-K ties.
5. Run focused tests and commit.

### Task 2: SQ8 exact rerank and public snapshot surface

**Files:**
- Modify: `src/akasha/index/quantization.mojo`
- Modify: `src/akasha/api/snapshot.mojo`
- Test: `tests/mojo/test_quantized_search.mojo`

**Steps:**
1. Add failing oracle tests for all metrics, candidate expansion, exact rerank, empty collections, and stable ties.
2. Prove RED with the focused test.
3. Build SQ8 from owned snapshot entries and expose `search_sq8_*` methods with `rerank_k >= k` validation.
4. Exact rerank only the approximate candidate IDs using original Float32 values.
5. Run focused tests and commit.

### Task 3: Product quantization

**Files:**
- Modify: `src/akasha/index/quantization.mojo`
- Test: `tests/mojo/test_product_quantization.mojo`

**Steps:**
1. Add failing tests for subquantizer divisibility, centroid bounds, deterministic training, code range, all metrics, rerank, and malformed configuration.
2. Prove RED.
3. Implement deterministic bounded-iteration k-means per subvector, empty-cluster preservation, row-major codes, and asymmetric query lookup tables.
4. Reuse exact rerank and deterministic Top-K ordering.
5. Run focused tests and commit.

### Task 4: Deterministic single-query parallel flat scan

**Files:**
- Create: `src/akasha/query/parallel_scan.mojo`
- Modify: `src/akasha/api/snapshot.mojo`
- Test: `tests/mojo/test_parallel_scan.mojo`

**Steps:**
1. Add failing differential tests comparing 1/2/4/auto workers to scalar results for all metrics, filters, tail ranges, and ties.
2. Prove RED.
3. Partition stable live-entry ordinals into fixed contiguous ranges, score one local heap per range through `parallelize`, and merge heaps in range order.
4. Expose exact parallel methods on `ReadSnapshot`; preserve scalar validation/error behavior.
5. Run focused tests plus the existing batch suite and commit.

### Task 5: Checksummed derived-cache format

**Files:**
- Create: `src/akasha/storage/index_cache.mojo`
- Modify: `src/akasha/storage/__init__.mojo`
- Test: `tests/mojo/test_index_cache.mojo`

**Steps:**
1. Add failing tests for v1 header round-trip, generation/sequence/source checksum, payload bounds, truncation, bad magic/version/kind/CRC, and atomic publication.
2. Prove RED.
3. Implement a generic cache envelope with distinct HNSW/metadata kinds, little-endian bounded lengths, CRC32, temp-file fsync, rename, and directory fsync.
4. Add `try_load` semantics that classify any derived-cache failure as a cache miss while explicit inspector decode remains strict.
5. Run focused tests and commit.

### Task 6: Persisted HNSW cache

**Files:**
- Modify: `src/akasha/index/hnsw.mojo`
- Modify: `src/akasha/storage/index_cache.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Test: `tests/mojo/test_persisted_index_cache.mojo`

**Steps:**
1. Add failing reopen tests proving cache hit preserves results and avoids rebuild, plus mismatch/corruption/truncation tests proving authoritative rebuild and republish.
2. Prove RED.
3. Add bounded HNSW graph payload encode/decode including config, entry point, node vectors, levels, and neighbor ordinals.
4. Key cache validity to collection generation, accepted sequence, dimension, and authoritative live-state checksum.
5. Integrate lazy load/rebuild into approximate search without making cache publication part of write acknowledgement.
6. Run focused and existing persistent HNSW tests; commit.

### Task 7: Persisted metadata cache

**Files:**
- Modify: `src/akasha/index/metadata.mojo`
- Modify: `src/akasha/storage/index_cache.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Test: `tests/mojo/test_persisted_index_cache.mojo`

**Steps:**
1. Add failing cache hit/rebuild tests covering typed fields, tombstones, ordinal reuse, and filtered-query parity.
2. Prove RED.
3. Encode stable ID/tombstone/field columns; decode them through `build_metadata_index` so secondary posting structures remain derived.
4. Invalidate on generation/sequence/source checksum mismatch and atomically replace bad/stale cache after rebuild.
5. Run focused metadata/filter tests and commit.

### Task 8: Phase 12 benchmarks and completion gates

**Files:**
- Create: `benchmarks/mojo/phase12_bench.mojo`
- Create: `docs/benchmarks/phase12.md`
- Modify: `pixi.toml`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/query-model.md`
- Modify: `docs/consistency-model.md`

**Steps:**
1. Add deterministic datasets and correctness gates for scalar, parallel, SQ8, PQ, rerank, build, memory estimate, cold reopen, and warm reopen.
2. Require recall@10 >= 0.80 for SQ8 and >= 0.70 for the compact PQ fixture; require reranked results to match the scalar oracle when the oracle IDs are inside the candidate set.
3. Add `pixi run bench-phase12`, run it, and record machine-specific observations without treating them as portable guarantees.
4. Document cache authority, rebuild behavior, quantization error, rerank semantics, and CPU worker selection.
5. Run `pixi run test`, `pixi run test-crash`, `pixi run build`, smoke examples, Phase 12 benchmark, and `git diff --check`.
6. Commit only after every gate exits zero.
