# Complete Database Capabilities Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Complete the previously identified Qdrant, LanceDB, general database and product-operation capabilities from upstream source ports, then resume the existing performance gates without weakening them.

**Architecture:** Keep one authoritative Mojo data/storage/query engine and thin protocol/SDK/UI boundaries. Port pinned upstream algorithms and lifecycle rules; use durable migrations for richer data, schemas and transactions. Deliver working vertical slices while keeping every unfinished capability in this ledger.

**Tech Stack:** Mojo 1.0.0, Python/FastAPI, C/Arrow, pinned Qdrant/Lance/LanceDB/RocksDB/raft-rs, source-backed SQL and web/protocol dependencies selected at their implementation stage.

---

## Rules and completion evidence

- User authorized report, plan and implementation on 2026-10-30. Continue without a second start approval.
- Use the existing clean main workspace following consolidation; avoid duplicate environments/reference trees and unnecessary worktrees. Never push without authorization.
- Work sequentially; no subagent delegation. Heavy builds/test workers are serial.
- Feature correctness, recovery and usable public API come before performance work.
- `implemented` requires source provenance, a real Mojo execution path, exposed API, relevant docs, regression tests, and independent/upstream oracle evidence. A helper alone is `in_progress`.
- `verified` additionally requires the complete capability acceptance below. All rows must be verified before the optimization phase; no totals inferred from checked boxes in older plans.
- Every newly discovered upstream operation/option adds a ledger item; retain unsupported ones explicitly. A route name or a copied schema is insufficient.
- Freeze upstream version/hash per port. A later baseline upgrade gets its own compatibility audit.
- Preserve Akasha public formats and behavior unless a specified new API changes them; Qdrant-compatible APIs must convert IDs/scores/errors as required and pass official clients.
- A functionality bug found during validation is fixed immediately. Profiling, tuning, benchmark-driven layout changes and optimization experiments wait for F-stage completion.

Report: [capability assessment](../research/2026-10-30-product-capability-report.md).

## Master ledger

All entries below start pending unless explicitly changed with evidence. Existing related
components do not satisfy the unimplemented public behavior.

| ID | Functional deliverable | Upstream / intended area | Required acceptance |
| --- | --- | --- | --- |
| F00 | Pinned source/API inventory, provenance and licenses | reference Git + OpenAPI/proto/SDK | Reproducible hashes; every public operation classified; license notices |
| Q01 | DBSF and weighted fusion alongside RRF | Qdrant `segment/common/score_fusion.rs`, `reciprocal_rank_fusion.rs` | Native oracle, empty/constant/overlap scores, API/Arrow, filters/reopen/rerank |
| Q02 | Query by ID, positive/negative recommendation strategies | Qdrant recommendations and query scorers | All strategies, IDs/vectors, lookup, exclusions, errors, native fixtures |
| Q03 | Discovery/context and MMR | Qdrant query scorers | Context semantics, diversity, tie/limit/budget cases, public APIs |
| Q04 | Nested prefetch, query plan, sampling, score formula/boosting/feedback | Qdrant universal query | Multi-stage plan, cancellation, filters, independent source fixtures |
| Q05 | Scroll, count, ordering, grouping, facet, search matrix | Qdrant read/query paths | Stable cursor/ties, projections, concurrent changes, API oracle |
| Q06 | Full metric/datatype/quantization matrix | Qdrant spaces/quantization, Lance index | Manhattan, Turbo16/Turbo8/Turbo4 and other current documented modes, native and persistence fixtures; keep Akasha extras |
| D01 | Rich payload values, nested objects/arrays/null | Qdrant payload + Lance Arrow schema | Versioned codecs, migration, typed traversal, Unicode/depth/size limits, corrupt/torn recovery |
| D02 | UUID/numeric IDs and key/value type semantics | Qdrant types + DB types | No ID collision/loss; native/indexed/HTTP/backup/reopen equality |
| D03 | Nested/array/geo/datetime/UUID filtering and indexing | Qdrant condition checker/field indexes | Direct vs indexed oracle, null/missing, per-array-element semantics |
| D04 | Full-text tokenizer, phrase/fuzzy/boolean text and BM25 | Qdrant full-text, Lance FTS | Upstream token/score fixtures, incremental IDF/index, restart and hybrid API |
| D05 | Complete payload/vector CRUD, batch and filter mutations | Qdrant update handlers | Replacement vs patch, atomic boundaries, absent/default values, interrupted writes |
| C01 | Collection list/info/create/drop/update/aliases | Qdrant collection management | Durable metadata, actual deletion vs close, aliases atomicity, restart |
| C02 | Dynamic named-vector and table schema evolution | Lance/LanceDB schema evolution | Add/rename/cast/drop/backfill, stable IDs, old readers, crash/reopen |
| L01 | Table version history, checkout, restore, tags and branches | Lance `dataset/refs.rs`, transaction/table | Durable history and GC, reproducible old reads, restart/rollback |
| L02 | Lance file/table read/write interoperability | Lance format/readers/writers | Bidirectional native fixtures, versions, indexes, updates and corrupt inputs |
| L03 | Durable IVF-PQ/IVF-HNSW and documented index variants | Lance index + existing Akasha | Reference recall/score correctness, persistence, incremental writes and filters |
| L04 | S3/GCS/Azure-compatible storage abstraction | Lance object store/commit | Conditional publication, retries, concurrent writers, partial failures, actual backends |
| L05 | Blob/multimodal columns and lifecycle | Lance Blob implementations | Bytes/URI/range reads, versions/GC, missing objects, backup/restore |
| L06 | Embedding/reranker provider and training/data integrations | LanceDB embedding/Arrow/PyTorch | Real provider contracts, batching/failures, versioned training reads |
| L07 | Namespaces/catalog and external dataset integrations | Lance namespace/SDK | Durable discovery, table identity, pandas/Arrow/DuckDB compatible boundaries |
| R01 | SQL lexer/parser/binder/expression and type system | Pin PostgreSQL/DataFusion sources first | Reference queries and errors; no Python SQL evaluator substituting for Mojo |
| R02 | Relational scans/filter/project/sort/limit | Same SQL source + current scan | SQL/API equality, null/ordering, spill/resource bounds |
| R03 | JOIN, grouping/aggregates, subqueries/CTEs/window operations | Same relational source | Differential SQL datasets including null/duplicates, multi-collection plans |
| R04 | BEGIN/COMMIT/ROLLBACK, isolation and conflicts | Mature transaction implementation | Read-your-writes, atomic rollback, anomalies/conflicts, crash/uncertain commit |
| R05 | Cross-collection transactions and durable catalog | Mature transaction/log protocol | All-or-none restart, failures at every publication step, no partial visibility |
| R06 | UNIQUE/CHECK/NOT NULL/foreign key constraints | PostgreSQL constraint semantics | Race/deferred checks, batch rollback, update/delete referential behavior |
| R07 | Views, triggers and stored procedures | PostgreSQL source semantics | Dependency invalidation, transactional execution, recursion/errors/permissions |
| A01 | Full Qdrant-compatible REST | OpenAPI inventory + handlers | Official qdrant-client, CRUD/query/admin/security/error contract suite |
| A02 | Qdrant gRPC/protobuf | Qdrant proto/server | Official gRPC clients and REST equivalence, cancellation/limits/status |
| A03 | Complete native Python/C/Arrow boundaries and SDK distribution | Existing ABI + upstream clients | All new core features reachable, ownership/lifetime, versioned packaging |
| A04 | SQL/FlightSQL and data-tool integration | LanceDB/DataFusion/Arrow public spec | Native query path, schema/results/errors, real supported clients |
| U01 | Management Dashboard | Pin Qdrant web-ui source | Browser flows: list/create/delete/configure, points/payload, pagination |
| U02 | Search/SQL console and visualization | Qdrant UI + DB UI source | Actual query/results, named/multi-vector, filter/rerank, errors and execution stats |
| U03 | Operations/security/backup/cluster UI | Qdrant UI/public platform contracts | Real backend actions, auth boundaries, restore/failure/upgrade status |
| S01 | API keys, TLS/mTLS, identity and fine-grained authorization | Qdrant auth/security | Positive/negative access tests, key rotation, per-collection scope |
| S02 | Quotas/admission control/audit and telemetry | Qdrant strict mode/telemetry | Bounded work, redaction, metrics export, audit integrity, alert examples |
| X01 | Production multi-host transport, process ownership and membership | Qdrant peer/shard + raft-rs | Real network nodes, identity/TLS, crash/restart and partitions |
| X02 | Raft topology/catalog and recovery | raft-rs/Qdrant consensus | Published state-machine tests, elections/snapshots/compaction, member changes |
| X03 | Configurable read/write consistency, ordering and replication | Qdrant replica set | Quorum/partition/catch-up oracle, duplicates/retries, cross-client history |
| X04 | Shard placement/transfer/rebalance/reshard/multitenancy | Qdrant transfer/Cloud public contracts | Online writes, cancellation/rollback, node removal, no missing/duplicate points |
| O01 | Complete backup/snapshot/migration tooling | Qdrant/Lance + existing backup | Local/object-store, versions/cluster, independent restore tests and official-format import |
| O02 | Installable server/SDK, containers and Kubernetes | Upstream packaging/operator references | Clean-host install/start/upgrade/uninstall; supported architecture artifacts |
| O03 | Production monitor/alerts, rolling upgrade and disaster recovery | Public upstream operations | Actual metrics/dashboard, mixed-version cluster, recovery drills |
| O04 | Managed/Hybrid/Private deployment control plane | Public APIs + suitable open-source operators | Provision/scale/upgrade/backup/restore, tenant isolation, documented source boundaries |
| O05 | Dataset curation/feature jobs/training management | LanceDB public feature engineering contracts | Durable job/retry/version semantics, actual data reads and derived outputs |
| V01 | Full functional/recovery/platform acceptance | All rows above + historical fixtures | CPU/Python/C/HTTP/gRPC/UI/crash/distributed; GPU actual device where changed; native Linux remains deferred, not passed |
| P01 | Resume M5/M6 quality, QPS, p95, memory/concurrency/lifecycle | Existing retained benchmark contracts | Only after all functional rows verified; fixed per-engine params, all cells, raw evidence |
| P02 | Optimize verified source ports | Source-backed profiling | Same behavior/correctness gates; retain failed runs; no regression waived |

## Execution order and dependency boundaries

1. **F00 + independent query vertical slices Q01–Q03.** These add source-backed
   usable capabilities on the existing read root without a speculative storage rewrite.
2. **D01–D05, C01–C02, Q04–Q06.** Rich data and catalog migrations support complete
   query/service behavior. Freeze durable invariants before editing codecs.
3. **L01–L07 and R01–R07.** Versioned tables, storage/Blob/index interoperability,
   general query and transactions. Design shared commit/catalog boundaries together;
   do not bolt history onto reclaimable read leases or cross-table commits onto
   separate collection fsyncs.
4. **A01–A04, U01–U03, S01–S02.** Expose functionality at each slice; finish full
   protocol compatibility, UI and security after core contracts are complete.
5. **X01–X04 and O01–O05.** Production cluster and operation/control plane paths.
6. **V01 then P01/P02.** Correctness and function acceptance precede optimization.

The first group is an implementation sequence, not a reduced product goal.
Rows requiring unavailable external hardware/cloud remain open with exact missing
evidence. Development can proceed on the other rows without relabeling those gates.

## First executable slice: Q01a DBSF

Detailed file-by-file steps and tests: [DBSF source port](2026-10-30-dbsf-source-port.md).
Weighted fusion, universal REST/gRPC exposure and full Q01 acceptance remain separate
unchecked work after this slice; do not mark Q01 complete from DBSF helpers alone.

## Progress

- **D01b rich payload / D03a scalar-condition coexistence implemented.**
  [Source-port plan](2026-10-30-rich-payload-source-port.md) adds owned native
  objects/arrays/null/UInt64, source get/set/remove/merge operations, independently
  versioned payload v2 with v1 migration, Python/existing HTTP/backup/NDJSON v2,
  and one-level array/null/MatchExcept checks alongside scalar indexes.
  2,088 value and 110 filter source cases, 171 tests across 27 native modules,
  and full Python **3,060 passed / 1 optional skip**; 26 new Python cases.
  Nine crash modules / 24 tests and the rebuilt C ABI checks also pass.
  Recovery/ABI results and initial compatibility failures are retained in the
  [validation report](../research/2026-10-30-rich-payload-validation.md).
  D01/D03 remain in progress: rich Arrow with missing/null semantics, collection
  path mutation APIs, top-level arbitrary keys, nested formula/filter values,
  dedicated indexes and full C/distributed/REST/gRPC contracts remain. Next
  shared-data work connects these public paths before Lance/SQL layers; all
  other master-ledger tasks and existing quality/platform gates stay open.
  No optimization phase has started.
- 2026-10-30: report and full work ledger created. Read clean source pins, installed
  compiler and live query/SDK paths. No performance experiment resumed.
- F00: in progress. `docs/upstream/source-lock.json` records 7 clean source pins;
  `qdrant-rest.json` records 69 pinned REST operations, all explicitly compatibility
  unverified. Protobuf/Lance/SQL/UI inventories and older attribution audit remain.
- Q01a: implemented and verified for core/Python/Arrow. Upstream Rust fixtures:
  114 rankings / 3,706 scores; 15 native cases across 5 modules and 254 Python
  cases pass. [Evidence](../research/2026-10-30-dbsf-validation.md).
- Q01b: weighted RRF implemented and verified for core/Python/Arrow. Both upstream
  functions compiled verbatim for 300 position / 50 fusion reference cases;
  19 native cases and 315 distinct Python cases passed, including length/finite
  validation, zero-weight retained points, filters, rerank, ANN/IVF, reopen,
  snapshots and conversion-close boundaries.
  [Plan](2026-10-30-weighted-rrf-source-port.md) /
  [evidence](../research/2026-10-30-weighted-rrf-validation.md).
  Q01 remains in progress; universal REST/gRPC and C ABI exposure are still pending.
- Q02a: native stored-point lookup and pre-Top-K exclusion implemented for
  matching native kind/scalar/dimension, exposed on snapshot/collection/Python/Arrow.
  52 unedited Rust reference cases, 18 native cases and 410 distinct Python cases
  passed, including HNSW/IVF, shadowed roots, selective exact fallback, source
  snapshots across close/reopen/symlinks and callback-close boundaries.
  [Plan](2026-10-30-point-query-source-port.md) /
  [evidence](../research/2026-10-30-point-query-validation.md).
- Q02b work: [all recommendation strategies](2026-10-30-recommendation-source-port.md).
  Source read: `collection/recommendations.rs` (average vector/lookup/exclusion)
  and `segment/vector_storage/query/reco_query.rs` (best score/sum scores).
  Q02a typed point lookup alone did not prove recommendation or preprocessing
  requirements. The exact implementation below adds that path; remaining
  datatype, storage, ANN and protocol gates still keep Q02 open.

- Q02b exact: implemented all three strategies in Mojo with raw/ID/mixed examples,
  source-field preprocessing and pre-Top-K exclusions. Native snapshot/collection,
  Python and Arrow expose the exact query. Independent portable Rust oracle:
  336 F32 queries and 24 reductions from 14 verbatim functions.
  [Evidence and remaining gates](../research/2026-10-30-recommendation-validation.md).
  At this exact-query stage, custom ANN scorer integration, complete F16/U8 source
  oracle and low-precision canonical-storage audit/migration, universal query and
  protocol exposure were required next (see Q02c progress below). BF16/I8 are native extensions, not proven
  Qdrant datatype compatibility. No performance gate was run.
- F00/Q06: current official vector documentation includes Turbo16/Turbo8 beyond
  the pinned v1.19.0 source. Keep these explicit in Q06 and pin/compare the newer
  upstream source when implementing them; do not count the older pin as full parity.
  Source: <https://qdrant.tech/documentation/manage-data/vectors/> (checked 2026-10-30).
- Q02c dense ANN: all three recommendation strategies now score graph candidates
  through the shared HNSW query-scorer boundary. Exact and indexed paths reuse
  the prepared transforms/reducers. Native/Python/Arrow expose the actual path
  and planner fallback reasons. The default-graph repeated-vector recall
  diagnostic remains open; complete-graph source-score integration tests do not
  establish a quality/performance gate or change production parameters.
  [Evidence](../research/2026-10-30-recommendation-ann-validation.md).
  Q02 stays in progress: sparse/multivector indexed modes, full F16/U8 source
  oracle, canonical-storage audit/migration and universal/C/REST/gRPC exposure
  remain. P01 retains this quality diagnostic alongside historical M5/M6 failures.
- Q02d sparse execution: average recommendation now uses source-derived plain/
  batched/final-posting search; custom best/sum follows upstream full scoring.
  Mojo/Python/Arrow expose actual paths, including path-specific zero scores.
  138 Rust reference cases, 6 native cases and 1094 distinct Python cases pass.
  [Plan](2026-10-30-sparse-recommendation-source-port.md) /
  [evidence and correction](../research/2026-10-30-sparse-recommendation-validation.md).
  The earlier blanket sparse-zero omission was not full source parity. Sparse
  recommendation exact/approx now share source dispatch; ordinary native nearest
  contracts still need their complete migration;
  configurable sparse thresholds, IDF/input/planner/service parity, multivector
  HNSW and the existing datatype/storage/protocol gates keep Q02 open.

- Q02e shared sparse nearest: [implementation plan](2026-10-30-sparse-nearest-source-port.md).
  Named/default nearest, sparse approx/point lookup, hybrid retrieval, PointStore,
  mutable index and candidate reranking now share the source postings execution.
  Obsolete dictionary/flat and per-run sparse search copies removed. Separately
  rounded F32 products fix a compiler-contraction mismatch found by the extended
  Rust oracle. 214 source fixtures, 87 native cases, 1693 distinct Python cases
  and C ABI checks pass (1 optional Qdrant Edge skip);
  [evidence](../research/2026-10-30-sparse-nearest-validation.md).
  Full sparse settings/IDF/planner, multivector, datatype/storage and protocol
  acceptance still keep Q02 open. No performance gate resumed.

- Q03a MMR: [source-port plan](2026-10-30-mmr-source-port.md) implemented in
  native named/ID nearest search and Python/Arrow. The source selection keeps
  original candidate scores, last-wins insertion/swap-removal ties and directional
  MaxSim. 192 reduction and 112 vector oracle cases pass; fractional cosine
  fixtures exposed compiler contraction in shared portable scoring, corrected
  with an explicit product-rounding boundary. 26 native cases, 1743 distinct
  Python cases (1 optional Qdrant Edge skip), Python build and C ABI checks pass;
  the final validation correction separately passed 50 MMR and 521 index cases;
  [evidence](../research/2026-10-30-mmr-validation.md).
  Discovery/context, nested prefetch/fusion MMR, full datatype/storage and
  protocol gates keep Q03 and the full plan open.

- Q03b discovery/context: implemented and verified for native/Python/Arrow exact
  dense/sparse/MaxSim and dense two-stage HNSW. Context selects up to 10 entry
  candidates; discovery uses the highest-level eligible entry with last ties.
  Shared custom execution/input resolution replaces duplicated recommendation
  plumbing. Source oracle exposed and fixed signed-zero rank differences.
  336 unedited-source cases, 42 native tests and the full Python suite
  (2005 passed, 1 optional skip; 262 new discovery cases) pass.
  [Plan](2026-10-30-discovery-source-port.md) /
  [evidence and remaining gates](../research/2026-10-30-discovery-validation.md).
  Q03 remains open for universal/nested prefetch/fusion MMR, discovery batch,
  offset/projection and full protocol exposure. Q02/Q06 datatype/storage,
  multivector HNSW and quality gates remain; proceed with Q04 functionality
  before performance work. All other master-ledger deliverables are retained.

- **Q04a native universal query tree implemented and verified.** Postorder native
  planner/executor now exposes ordered nested prefetch, nearest/recommendation/
  discovery/context rescoring, RRF/weighted RRF/DBSF, root/nested/leaf MMR and
  bounded ID-ordered no-vector queries through Mojo/Python/Arrow. Ancestor filters
  apply before leaf selection; all target-collection ID references are excluded
  globally; candidate unions stay within one retained target root. Native limits,
  deadlines, cancellation and post-conversion owner checks cover the whole tree.
  The pinned unchanged Rust planner/validation functions produced 103 source
  cases; 14 relevant native tests and full Python 2115 passed / 1 optional skip.
  [Plan](2026-10-30-universal-query-source-port.md) and
  [validation](../research/2026-10-30-universal-query-validation.md).
  Q04 remains open for sampling/formula/boosting/feedback; Q03/Q05 retain batch,
  projections, full cursor/order/group/facet/matrix and protocol work. Datatype/
  storage, source graph planner and complete nonfinite behavior remain under
  Q02/Q06. Existing recall/performance failures and native Linux deferral remain.

- **Q04b numeric formulas implemented and verified.** The source F32/F64
  evaluator, short circuits, defaults, conditions and three decay functions now
  rescore ordered prefetch score maps over the visible candidate union. Native,
  Python and Arrow share this path and retained target root. Formula/default
  nodes share the plan's structural budget; native recursive evaluation checks
  cancellation/deadlines. Filter binding recursion is bounded before allocation.
  A release Rust oracle compiles eight unedited source functions: 309 cases,
  57 expected errors. Nine relevant native tests and full Python
  **2461 passed / 1 optional skip**, including 346 new formula cases.
  [Plan](2026-10-30-formula-source-port.md) and
  [validation](../research/2026-10-30-formula-validation.md).
  Full JsonPath grammar/typed values, date/geo/rich defaults remain with D01/D03;
  this is not full formula or REST/gRPC parity. Q04 sampling/feedback and all
  remaining master-ledger deliverables, quality/performance failures and native
  Linux deferral remain open. Continue functionality before any optimization.

- **D01a/Q04c shared JSON paths implemented and verified.** Ports source grammar,
  canonical display, prefix/wildcard/pattern operations and formula variable
  parsing. Rust 1.97.1 Unicode 17 source data generates native classification;
  the host classifier is exhaustively checked before the unchanged nom parser
  generates expected results. Quoted flat keys, Unicode raw keys and full UInt64
  score indexes now work through formula Mojo/Python/Arrow; parsed native
  `FormulaDefault` removes the unrelated persisted-field-name restrictions.
  548 source inputs, 81 operation pairs, exhaustive Unicode, eight native tests,
  1029 targeted Python tests and full Python **3034 passed / 1 optional skip**.
  [Plan](2026-10-30-json-path-source-port.md) /
  [validation](../research/2026-10-30-json-path-validation.md).
  D01 rich objects/arrays/null, actual traversal/mutation, versioned codecs and
  migration/recovery remain next data-layer work. D03 and Q04 date/geo/rich
  formula values and every other ledger requirement stay open. This grammar
  slice does not satisfy rich persistent data or authorize optimization.
