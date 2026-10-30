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

- **D01c4d native Number/parsed-path Display verified.** Source jsonb decimal splitting/padding and path text/parentheses are ported; ethnum's 256/128 division supplies exact decimal splitting and existing zmij supplies floats. 88,716 Number inputs (79,658 exact texts, 9,058 mapped source panics), 8,525 parser cases (4,238 exact Display outputs), and 11,692 original division results pass. **21 native tests**, rebuilt Python kernel and full Python **3,681 passed / 1 skip**; fixtures/metadata/lock reproduce byte-for-byte. The selector and formatter share the relocated, behavior-identical AST validation. [Evidence](../research/2026-10-30-jsonb-display-validation.md). Lance consumers, remaining conversions, collection filters/projections/indexes and all full-product/platform/performance gates remain open; no optimization.

- **D01c4c complete parsed JSONB selector and Python value-query API verified.** Six original modes preserve traversal/order/duplicates, scoped expressions, unknown comparison, arithmetic errors and serde Number output. 64,856 source cases produce 389,100 mode outcomes: 368,799 exact successes, 20,300 original errors and one source success rejected by the existing codec depth bound; six parse rejection/panic cases are separate. **22 native**, **52 new Python**, full Python **3,681 passed / 1 skip**; rebuilt kernel and byte-identical fixture/metadata/lock reproduction pass. WAL/checkpoint reopen, owned results and errors without writes are covered. [Evidence](../research/2026-10-30-jsonb-selector-validation.md). Source Display, Lance consumers, collection filters/projections/indexes, remaining protocol boundaries and all full-product/platform/performance gates remain open; no optimization.

- **D01c4b native JSONB Number arithmetic/comparison verified.** All six variants preserve source integer casts, overflow/error messages, Decimal scale promotion/release wrapping/float fallback, ordered NaNs, signed zero and canonical codec boundaries. Original jsonb/ethnum supplies 8,495 unary cases, 94,213 pairs × five operations plus comparison, 2,404 wide products, 256 powers and 4,709 original/legacy numeric bodies. Seventeen native tests and byte-identical fixture/provenance/lock/license reproduction pass. [Evidence](../research/2026-10-30-jsonb-number-validation.md). Full selector modes, source Display, public query/index boundaries and every remaining product/platform/performance gate remain open. Python runtime unchanged; no optimization.

- **D01c4a complete native JSONB path grammar dependency verified.** Ported jsonb/nom's full path and expression syntax to owned Mojo ASTs, preserving alternative order, numeric type/bits, whitespace/escape/cut behavior and source quirks while keeping Qdrant paths separate. All 8,525 original-source cases match: 4,238 ASTs, 4,275 rejections and 12 source panics mapped to errors. All 18 node kinds, 14 binary operators, both unary operators and six literal categories are exercised. Seven native tests and source/fixture/lock/license reproduction pass. [Evidence](../research/2026-10-30-jsonb-path-parser-validation.md) / [full query plan](2026-10-30-jsonb-path-source-port.md). Numeric comparison/arithmetic, selector modes, source Display, public query boundaries and indexes remain; this dependency is not JSONB query completion. Prior application results remain applicable; no optimization.

- **D01c3j native Arrow JSON interchange verified.** Both ingress APIs and scanner C Data output accept `arrow.json` Utf8/LargeUtf8/StringView and `lance.json` LargeBinary, recursively through Struct/List/LargeList/FixedSizeList/Map. Checked native values preserve storage null versus JSON null; binary projections retain exact bytes, text uses the source writer. Original Lance conversions produce 12 cases / 36 IPC files; all 40 fixture/provenance files reproduce. Public paths match 20,757 source text acceptance/body results and 28,901 writer binary/text pairs. **24 native**, **183 targeted Python**, full Python **3,629 passed / 1 skip**. [Evidence](../research/2026-10-30-arrow-json-validation.md) records C Data Map-name normalization, metadata, null masks, atomic rejection, WAL/checkpoint reopen, ownership and output/cancellation limits. Native JSONB path query/index support, arbitrary top-level keys, remaining C/distributed contracts and all full-product/platform/performance rows remain open; no optimization.

- **D01c3i native/Python JSONB text output verified.** The actual RawJsonb/serde compact and pretty paths cover every existing JSONB scalar/container/extension, decimals through source F64 conversion, jiff calendar/offset formats, legacy bodies and original key order. 29,003 unique source bodies match both native/Python outputs or errors (28,901 output pairs, 102 source panics mapped to errors). Three native tests, 74 distinct targeted Python tests and full Python **3,485 passed / 1 skip**; build and source reproduction pass. [Evidence](../research/2026-10-30-jsonb-writer-validation.md). Output expansion, native bounds, WAL/checkpoint reopen and read-only errors are covered. Next: full Arrow JSON ingress/export with nullable slots and nested metadata. D01/query/index/protocol and all remaining product/platform/performance rows stay open; no optimization.

- **D01c3h zmij F64 formatting dependency verified.** Ported the pinned source fast conversion, Schubfach fallback, portable BCD writer and notation/special-value rules. All 70,662 source text outputs match; 70,640 nonzero finite cases also match both intermediate conversion paths, and 70,642 finite texts round-trip to identical bits through native fast-float2. Four native tests pass; source fixture, metadata, lock, license and original Rust-generated tables reproduce. [Evidence](../research/2026-10-30-zmij-validation.md). The RawJsonb/serde_json writer still needs decimal/extension formatting and integration before full Arrow JSON. This standalone dependency leaves D01 and every remaining product/platform/performance requirement open; no optimization.

- **D01c3g jsonb text parser and Python factory verified.** Ported the actual standard/extended grammar into owned Mojo JSONB values with native resource bounds; Python `JsonbValue.from_json` delegates parsing to Mojo. All 20,757 source inputs match accepted body bytes/rejection in both native and Python APIs. **29 native tests**, **61 targeted Python** and full Python **3,472 passed / 1 skip**; fixtures/provenance/lock reproduce. [Evidence](../research/2026-10-30-jsonb-reader-validation.md). Next: RawJsonb/serde_json writer and its numerical formatting dependency, then complete Arrow JSON. Source Value::Display is a different path and is not the Arrow output contract. Full D01 and all product/platform/performance rows remain open; no optimization.

- **D01c3f fast-float2 F64 numeric dependency verified.** Ported the pinned source short/disguised, binary-product and 768-digit long-mantissa paths, prefix grammar and special values. All 15,191 source inputs match full/partial bits and consumption, including 801 long-path inputs and 12,162 forced long-path comparisons. Three native modules / 18 tests pass; source fixtures, lock, license and literal tables reproduce byte-for-byte. [Evidence](../research/2026-10-30-fast-float-validation.md). This dependency preserves the existing serde_json numeric contract. Actual jsonb grammar, source serializer, full Arrow JSON and all complete product/platform/performance rows remain open; no optimization.

- **D01c3e JSONB Python/HTTP/NDJSON boundaries verified.** Native validation backs the immutable Python binary carrier; point/document/batch and payload-update APIs support nested JSONB. Explicit typed HTTP/NDJSON v3 preserves source bodies and null distinction without marker-key collisions; frozen v1/v2 imports remain. All 6,331 source bodies pass public and logical round trips; **46 new Python**, **17 native**, **120 targeted Python** and full Python **3,457 passed / 1 skip**. [Evidence](../research/2026-10-30-jsonb-boundary-validation.md). Next: actual jsonb text grammar, fast-float conversion, source serializer and full Arrow JSON. Full C/distributed/protocol value boundaries, JSONB query/index operations and all complete product/gate rows remain open; no optimization.

- **D01c3d native JSONB durable integration verified; public boundaries remain open.** Native payload roots and containers preserve exact source JSONB bodies with distinct null semantics. Payload v3 writes retain v1/v2 reads and migrate through existing atomic rewrites without sequence/schema changes. **21 native modules / 130 tests passed**, including all 6,331 source bodies, resource limits, mixed-version WAL/checkpoints, snapshots, compaction, physical backup and corruption/torn-batch recovery. Full Python **3,411 passed / 1 skip**, **9 crash modules / 24 tests**, module/worker builds and C ABI passed. [Evidence](../research/2026-10-30-jsonb-storage-validation.md). Public Python/HTTP/NDJSON/Arrow representations and source text/numeric/serialization work remain; complete D01 and all other product/gate rows remain open. No optimization.

- **D01c3c native JSONB binary-value dependency verified; durable integration followed in D01c3d.** Ported jsonb 0.5.6 databend scalar/number/extension/container encodings, decoding and sorted duplicate-rejecting builders into owned Mojo bytes with strict UTF-8/length/resource validation. JSON null remains separate from an outer absent slot. Exact source bytes and decoded typed fields match 6,246 cases plus 85 old decimal/timezone cases. 24 related native tests, module rebuild and full Python **3,411 passed / 1 skip**; fixture/metadata/lock reproduce byte-for-byte. [Evidence](../research/2026-10-30-jsonb-codec-validation.md) / [native API](../native-jsonb.md). Native payload type, durable migration and recovery are covered by D01c3d above; public boundary representations, textual jsonb conversion and Arrow JSON remain. No collection/Python/Arrow JSON capability or full product row is closed by this dependency. No optimization or changed gates.

- **D01c3b native StringView dependency verified; Lance/jsonb contract evidence established.** Both Arrow ingestion APIs and recursive typed scanner export support StringView using Arrow 58.4 view validation, inline/external storage and the C Data variadic size trailer. No Python row staging or durable format change. 26 new Python, 17 related native and 212 targeted Arrow tests pass; full Python **3,411 passed / 1 skip**. The unchanged Lance JSON module and two jsonb profiles characterize 5,641 inputs, nullable slots and storage types; this is source evidence, not Akasha JSONB conformance. Contracts/IPC/metadata/lock reproduce byte-for-byte. [Evidence](../research/2026-10-30-lance-json-stringview-validation.md). Next: distinct JSONB logical body and native source codec/durable migration, then jsonb grammar/numeric/serialization and complete `arrow.json` boundaries. All full D01/product/platform/quality/performance rows remain open; no optimization.

- **D01c3a native JSON reader dependency implemented and verified; Arrow JSON remains in progress.** Ported serde_json 1.0.151 byte/value grammar, UTF-8/escapes/surrogates and its explicitly pinned default numeric profile into native PayloadValue, with source/depth/node/content bounds. 5,630 actual-source inputs: 3,063 accepted typed trees/F64 bits also survive codec round trips; 2,567 rejected inputs. Eighteen native tests include WAL-only reopen, snapshots, checkpoint/reopen and invalid input leaving WAL/sequence unchanged. Python module build and full Python **3,385 passed / 1 skip**; fixture/metadata/lock/numeric table reproduce byte-for-byte. [Plan](2026-10-30-json-interop-source-port.md) / [evidence](../research/2026-10-30-json-reader-validation.md). Next: Lance/jsonb numerical source comparison and storage-null representation before complete Arrow JSON ingress/export. Native parser profile is not Lance equivalence; no complete D01 or other product/platform/performance row is closed.

- **D01c2 typed rich Arrow export implemented and verified.** Native recursive C Data output accepts PyArrow scalar/nested types and fields, preserves requested metadata/nullability, checks numeric bounds, and shares the existing unchanged recursive buffer owner. Scalar aliases now use this one path. Actual Arrow casts supply 2,126 inputs × F16/F32; all 4,252 bit/overflow outcomes pass after preserving the source's intermediate F32 rounding for F16. 55 new Python and 14 related native tests pass; full Python **3,385 passed / 1 skip**. Cast fixture, source metadata and lock regenerate byte-for-byte; existing 88 typed IPC cells round-trip with their schemas. [Evidence](../research/2026-10-30-rich-arrow-export-validation.md). Next is dynamic `arrow.json` interop, missing/null and arbitrary keys. Complete D01, durable schema/history/Lance format and all other product/platform/quality/performance rows remain open; no optimization.

- **D01c1 typed rich Arrow ingress implemented and verified.** Both upsert APIs use one Mojo buffer traversal for null/bool, all integer widths, finite floating types, UTF-8/large UTF-8 and nested struct/list/large/fixed lists. Supplied nulls remain explicit; masked children are ignored; atomicity, bounds and ownership remain native. Arrow/Lance source oracle covers 88 cells plus source invariants; 15 native tests and full Python **3,330 passed / 1 skip**, including 82 new public tests. [Evidence](../research/2026-10-30-rich-arrow-ingress-validation.md). Recursive rich output is covered by D01c2; dynamic JSON extension, complete D01 and all other product/platform/quality/performance rows remain open.

- **D03f point identity, vector presence, deterministic slices and standalone
  whole-path conditions implemented and verified.** Qdrant checker context and
  nested isolation, all-empty/any-null path semantics, Slice validation and
  canonical zero-key SipHash-2-4 are ported to Mojo. The actual pinned siphasher
  crate supplies hash expectations. Native/Python/Arrow/current HTTP search,
  formulas, scanners and payload updates share authoritative point context;
  payload-only cache formats stay unchanged. 12,656 source rows (29 expected
  errors), 2,187 exact hash cases, 45 native tests across seven modules and full
  Python **3,248 passed / 1 skip**; 36 new public tests.
  [Plan](2026-10-30-point-filter-source-port.md) /
  [evidence](../research/2026-10-30-point-filter-validation.md).
  Native signed Int64 IDs and the explicit unnamed sparse field selector are
  documented extensions; hash tests do not claim UUID/UInt64 point storage.
  Full D02/D03/Q04, rich Arrow, dedicated indexes/FTS, protocols and every other
  product/platform/quality row remain open. No optimization or changed gates.

- **D03e plain polygon containment implemented and verified.**
  Qdrant GeoPolygon validation, geo 0.33.1 winding/containment, geo-types 0.7.19
  closure and robust 1.2.0 adaptive orient2d are ported to Mojo. Source boundary,
  holes, EPSILON closure, degeneracy and planar antimeridian behavior are retained.
  17,060 source polygon cases and 31,167 exact-bit orientation cases cover all
  adaptive exits; 33 native tests across seven modules and 24 new Python tests
  pass; the rebuilt full Python suite is **3,212 passed / 1 skip**.
  Python/Arrow/search/formula/HNSW/mutation/snapshot/reopen/HTTP are covered.
  [Plan](2026-10-30-polygon-source-port.md) /
  [evidence](../research/2026-10-30-polygon-validation.md).
  Dedicated indexes, full protocols/C ABI, rich Arrow and the complete remaining
  Lance/general DB/UI/security/cluster/operations/platform/quality scope stay open.
  No optimization or changed performance gates.

- **D03d plain payload predicates and scoped filters implemented and verified.**
  Native/Python/Arrow and existing HTTP routes now support source-backed field
  JSON paths, same-object nested conditions, minimum matches, match/set/plain text,
  numeric/datetime ranges, count/empty/null, geographic boxes and radii. Shared
  authoritative-payload evaluation reaches search and atomic payload mutations.
  The original Rust oracle covers 10,781 cases (10 expected parse errors), with
  101 native tests across 16 modules and full Python **3,188 passed / 1 skip**.
  Sixteen new public tests cover source outcomes, Arrow, snapshots/reopen, HNSW,
  prefetch/formulas, full-depth payloads, batches, limits, ownership and HTTP.
  [Plan](2026-10-30-payload-filter-source-port.md) /
  [evidence](../research/2026-10-30-payload-filter-validation.md).
  D03/Q04 remain open for polygon geometry, dedicated typed/array/nested/date/geo/
  text indexes, indexed tokenizer/BM25/phrase behavior, remaining conditions,
  typed-index retrieval and full protocols. Rich Arrow, Lance/general DB/UI/
  security/cluster/operations/platform/quality scope is unchanged; no optimization.
- **Q04f / D03c datetime parsing and formulas implemented and verified for
  native, Python and Arrow.** Original Qdrant DateTimeWrapper and chrono 0.4.45
  scanners/calendar/timestamps support the complete ordered parser formats,
  eager `datetime` constants and lazy `datetime_key` paths/defaults. The source
  oracle covers 20,861 date inputs, 315 microsecond timestamps and 3,624 formula
  scores/errors, including calendar/UTC bounds, leap seconds and negative time.
  Twenty-one native tests across five modules, 1,013 targeted Python and full
  Python **3,172 passed / 1 skip**; 35 new public cases cover writes, filtering,
  decay, mutations/reopen, snapshots, Arrow ownership and query controls.
  [Plan](2026-10-30-datetime-source-port.md) /
  [evidence](../research/2026-10-30-datetime-validation.md).
  Q04/D03 remain open for datetime/geographic/nested filtering and indexes, full
  conditions, typed-index retrieval, sampling/feedback and protocols. Rich Arrow
  and all remaining product/platform/quality tasks stay open; no optimization.
- **Q04e / D03b geographic formulas implemented and verified for native,
  Python and Arrow.** Qdrant GeoPoint conversion/validation and its pinned
  GeoRust geo 0.33.1 Haversine distance now support payload paths/defaults and
  existing arithmetic/decay formulas. The original-source oracle covers 30
  coordinate cases, 796 exact F64 distances and 1,064 F32 formula scores/errors.
  Sixteen native tests across four modules, 979 targeted Python and full Python
  **3,138 passed / 1 skip**; 46 new public cases include mutations/reopen,
  snapshots, Arrow ownership, request validation, filters and query controls.
  [Plan](2026-10-30-geo-formula-source-port.md) /
  [evidence](../research/2026-10-30-geo-formula-validation.md).
  Datetime formulas subsequently landed in Q04f; Q04/D03 remain open for
  datetime/geographic filters/indexes, full conditions,
  typed-index retrieval, sampling/feedback and protocols. Rich Arrow and all
  Lance/general DB/UI/security/cluster/operations/quality/platform rows remain
  open; no optimization work has started.
- **Q04d rich formula payload retrieval implemented and verified for native,
  Python and Arrow.** Full JSON paths, source single-level array flattening and
  wildcard suffix, missing/null/type behavior, UInt64 numeric conversion and
  bounded JSON defaults use the original payload retriever/scorer semantics.
  1,068 source cases, 12 native tests across three modules, 933 targeted Python
  and full Python **3,092 passed / 1 optional skip**. Eighteen new public tests
  cover writes/mutations/reopen, nested queries, Arrow ownership and limits.
  [Plan](2026-10-30-formula-payload-source-port.md) /
  [evidence](../research/2026-10-30-formula-payload-validation.md).
  Geo/datetime formulas subsequently landed in Q04e/Q04f; Q04/D03 remain open
  for datetime/geographic filters/indexes, full conditions,
  typed-index retrievers, sampling/feedback and protocols. Rich Arrow and every
  other product/quality/platform row remain open; optimization has not started.
- **D05a collection payload mutations implemented and verified for native,
  Python and current HTTP.** Source-derived set/overwrite/delete/clear supports
  IDs or existing filters, JSON paths, wildcard edits, source null/order rules,
  unchanged vectors and atomic publication under the writer lock. The document
  root preserves depth-64 field values. 1,644 original-source mutation cases,
  3 native tests and full Python **3,078 passed / 1 optional skip**, including
  18 new public tests. [Plan](2026-10-30-payload-mutations-source-port.md) /
  [evidence and native/Qdrant boundaries](../research/2026-10-30-payload-mutations-validation.md).
  D05 remains open for mixed-operation batches, remaining vector/filter CRUD
  and complete REST/gRPC; D01 rich Arrow and D02/D03/Q04 data integration remain
  the next shared-data work. All other ledger rows and quality/platform gates
  remain open; no optimization phase has started.
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
