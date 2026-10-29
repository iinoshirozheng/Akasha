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
| Q06 | Full metric/datatype/quantization matrix | Qdrant spaces/quantization, Lance index | Manhattan and current documented modes, native and persistence fixtures; keep Akasha extras |
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

- 2026-10-30: report and full work ledger created. Read clean source pins, installed
  compiler and live query/SDK paths. No performance experiment resumed.
- F00: in progress. `docs/upstream/source-lock.json` records 7 clean source pins;
  `qdrant-rest.json` records 69 pinned REST operations, all explicitly compatibility
  unverified. Protobuf/Lance/SQL/UI inventories and older attribution audit remain.
- Q01a: implemented and verified for core/Python/Arrow. Upstream Rust fixtures:
  114 rankings / 3,706 scores; 15 native cases across 5 modules and 254 Python
  cases pass. [Evidence](../research/2026-10-30-dbsf-validation.md).
- Next: Q01b weighted RRF from upstream `position_score`/`rrf_scoring`, including
  source fixtures, length validation, zero-weight retained points, and API/Arrow.
  Q01 remains in progress; universal REST/gRPC exposure is still pending.
