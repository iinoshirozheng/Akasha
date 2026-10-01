# Native named-field retrieval integration

The public point API now connects catalog-bound native authority, atomic writes,
snapshot reads, checkpoint/reopen, Python and Arrow to exact retrieval, per-field
HNSW, per-field sparse postings and multi-field RRF. This report covers that
integration; it does not declare the remaining M5/M6 performance goals complete.

## Implemented contracts

| Field | Authoritative values | Retrieval and score |
| --- | --- | --- |
| Dense | F32, F16, BF16, I8, U8 | Exact dot/L2/cosine; configured HNSW candidates with native F64 rerank |
| Sparse | Sorted unique nonnegative terms, finite nonzero F32 weights; empty allowed | Independent inverted postings, F64 dot; zero-score rows outrank negative matches |
| Binary | Packed bytes with checked logical bit dimension/padding | Native Hamming and Jaccard distance, including partial final byte |
| Multivector | Ragged native numeric rows with fixed component dimension | Exact MaxSim/late interaction; empty stored matrices remain present but do not score |
| Fusion | Any sequence of valid field queries | One captured root, filtered branch rankings, F64 RRF with ascending-ID ties |

Missing fields never acquire fabricated zero vectors. Payload/default/named field
updates share one point commit. Native storage and graph encoding are independent:
the HNSW graph can use F32/BF16/F16/I8 as permitted by its metric while the result
is always reranked against the selected field's own native buffers.

Root-owned graph/postings artifacts publish only after a complete build. Sibling
snapshots share a ready index, including concurrent first queries. A new root
starts with fresh states; old roots survive mutations, compaction and close.
Graph scratch is serialized per artifact; sparse queries use immutable postings
and private score accumulators. Neither builder holds the collection writer lock.

`search_field` defaults to exact and exposes explicit approximate ef/rerank
bounds. `search_fields` executes typed `FieldQuery` branches against one root and
fuses their ranks, never their incomparable raw metric scores. Both Python and
Arrow entry points share validation, limits, filters and native execution.
Native control checkpoints stop failed/expired builds before publication. Python
cancellation is sampled at synchronous call entry; deadlines remain native.

## Verification completed for this slice

- `test_named_hnsw.mojo`: 3 tests; independent field dimensions/encodings, F64
  exact equality when the candidate budget covers the corpus, missing fields,
  filters, shared build counts, concurrent queries, injected build failure,
  deadline/cancel, resource limits, fresh/old roots, close and reopen.
- `test_named_sparse.mojo`: 2 tests; F64 cancellation-sensitive arithmetic,
  empty/unmatched/negative scores, distinct fields, mutation visibility, RRF
  snapshot isolation through close, deadline/retry and concurrent first readers.
- `tests/python/test_named_vectors.py`: 58 passed after rebuilding the extension;
  includes 15 native dtype/metric ANN cells, Arrow result equality, query bounds,
  control errors, mixed-field rank oracles and reopen.
- Entire Python suite with the pinned optional Qdrant dependency available:
  **234 passed**, using
  `pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps pytest tests/python -q`.
- Entire crash suite: **23 passed**, using `pixi run test-crash`. The retained-base
  publication tests include 36 simulated disk states across legacy/point mode,
  preexisting/caught-up/v3-migrated bases and six interruption boundaries. Point
  migration/checkpoint has its separate ten-state publication test.
- Full Mojo regression: **123 files / 917 tests passed**. The first run exposed four old
  retirement-test assumptions that every small flush replaces its HNSW file.
  Those tests now explicitly rebuild and assert a distinct replacement before
  checking last-reader reclamation; all nine retirement tests pass. The retained
  base regression independently verifies that ordinary small flushes keep the
  current base instead. The passing prefix was retained; after rerunning the
  retirement file, the runner continued through every remaining file.
- The rebuilt C shared library passes the external C11 ABI test compiled with
  `-Wall -Wextra -Werror`. The Python extension and all three Mojo examples build;
  smoke, persistent collection and configured HNSW examples all run successfully.
  Existing unchanged HNSW quality gates are retained; the latest 11-cell,
  four-filter post-HNSW smoke run has recall 1.0 in every cell.

The existing independent Float64/bitset oracles also cover all five numeric
authority types for dense and multivector metrics, plus both binary metrics.
Arrow BF16 uses validated UInt16 bit patterns and schema metadata. The optional
`ml_dtypes` NumPy package is absent on this host, so its actual ndarray producer
has not been an executed gate; native BF16 list/Arrow paths are tested.

## Remaining boundaries

Named HNSW/postings are in-memory root artifacts, rebuilt on first use after root
change/reopen. They have no per-field durable sidecar yet. The default HNSW uses
the separately tested retained-base v5 recovery path. No cold named-index build
cost is presented as warm query time, and no named-index result proves Qdrant
speed parity. IVF and the remaining M5/M6 workload matrix require their own
implementation/measurement evidence. Final branch integration and commits remain
outstanding.
