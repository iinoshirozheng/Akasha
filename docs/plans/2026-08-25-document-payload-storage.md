# Document Payload Storage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist flat typed document fields atomically with vectors and expose backward-compatible `upsert_document` and `get` APIs.

**Architecture:** Add explicit tagged payload values and a strict binary payload codec. WAL and snapshot segments write version 2 records containing vector plus payload while their decoders continue to restore version 1 vector-only data with empty fields. MemTable owns the latest complete document state and `PersistentCollection.get` returns an owned copy.

**Tech Stack:** Mojo 1.0.0 stable, Pixi, existing pure-Mojo binary codec/CRC32/WAL/Segment/Manifest engine, `std.testing.TestSuite`.

---

### Task 1: Typed document value model

**Files:**
- Create: `tests/mojo/test_document_value.mojo`
- Modify: `src/akasha/document/value.mojo`
- Modify: `src/akasha/document/record.mojo`
- Modify: `src/akasha/document/__init__.mojo`

1. Add tests for String, Int64, Float64, and Bool constructors/getters, wrong-type access, field cloning, document lookup, duplicate-name rejection, and owned copies.
2. Run `pixi run mojo run -I src tests/mojo/test_document_value.mojo` and verify failure because the document types do not exist.
3. Implement explicit tagged `PayloadValue`, `DocumentField`, field validation/cloning, and `DocumentRecord` with linear `get_field`.
4. Re-run the focused test and require all cases to pass.
5. Format changed Mojo files, run `git diff --check`, and commit as `feat: add typed document value model`.

### Task 2: Strict payload binary codec

**Files:**
- Create: `tests/mojo/test_document_codec.mojo`
- Modify: `src/akasha/document/codec.mojo`
- Modify: `src/akasha/storage/checksum.mojo`

1. Add tests for all four types in one round trip, preserved field order, empty payload, invalid UTF-8, duplicate keys, unknown type tags, invalid Bool, truncation, non-finite Float64, and configured size/count limits.
2. Run the focused test and verify failure because payload encode/decode APIs do not exist.
3. Add little-endian Float64 primitives to the shared binary codec and implement payload v1 encode/decode/validation with 1,024-field and 16-MiB limits.
4. Re-run codec and storage checksum tests and require all cases to pass.
5. Format, inspect `git diff --check`, and commit as `feat: add typed payload binary codec`.

### Task 3: Document-aware MemTable and point lookup

**Files:**
- Modify: `tests/mojo/test_memtable.mojo`
- Modify: `src/akasha/storage/memtable.mojo`

1. Add tests that document upsert owns fields, later document upsert replaces them, vector-only upsert clears them, delete hides them, old sequences cannot restore them, and `get` returns an owned copy.
2. Run the focused test and verify failure because MemTable entries and APIs have no fields/get support.
3. Extend `MemTableEntry`, cloning, `apply_upsert`, add `apply_document_upsert`, and add live `get` without changing ordering or tombstone behavior.
4. Re-run document and MemTable focused tests.
5. Format, inspect `git diff --check`, and commit as `feat: store document payloads in memtable`.

### Task 4: WAL v2 with mixed v1/v2 recovery

**Files:**
- Modify: `tests/mojo/test_wal.mojo`
- Create: `tests/mojo/test_wal_v1_compat.mojo`
- Modify: `src/akasha/storage/wal.mojo`
- Modify: `docs/formats/wal-format.md`

1. Add tests for v2 document upsert/delete round trips, empty fields from vector-only writes, mixed v1 then v2 replay, v1 recovery as empty payload, malformed v2 payload, checksum corruption, and existing torn-tail behavior.
2. Build v1 test fixtures inside the test module from the documented v1 layout and verify new tests fail because WAL records have no fields or v2 encoder.
3. Make new encoders write v2 records, add document upsert, decode both versions per record, and retain sequence/dimension/CRC/torn-tail validation.
4. Re-run WAL, payload codec, and crash tests.
5. Update the format document, format code, inspect `git diff --check`, and commit as `feat: persist document payloads in wal v2`.

### Task 5: Snapshot Segment v2 with v1 compatibility

**Files:**
- Modify: `tests/mojo/test_segment.mojo`
- Create: `tests/mojo/test_segment_v1_compat.mojo`
- Modify: `src/akasha/storage/segment.mojo`
- Modify: `docs/formats/segment-format.md`

1. Add tests for v2 payload snapshot round trip, empty/vector-only records, v1 snapshot recovery with empty fields, invalid payload length, payload corruption, truncation, and dimension mismatch.
2. Build a v1 fixture from the documented v1 segment layout and verify failure because segment records have no payload support.
3. Write only v2 segments, decode v1 fixed-size records and v2 length-prefixed payload records, and keep exact checksum/sequence/ID ordering validation.
4. Re-run Segment, MemTable, WAL, and payload codec tests.
5. Update the format document, format code, inspect `git diff --check`, and commit as `feat: persist document payloads in segment v2`.

### Task 6: PersistentCollection document API

**Files:**
- Create: `tests/mojo/test_persistent_documents.mojo`
- Modify: `tests/mojo/test_public_api.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Modify: `src/akasha/__init__.mojo`

1. Add tests for immediate `upsert_document`/`get`, WAL-only reopen, flush/reopen, search-result ID to payload lookup, vector-only replacement clearing fields, delete returning `None`, invalid input preserving sequence, and v1 database upgrade on flush.
2. Run focused tests and verify failure because the public APIs and exports do not exist.
3. Compose document validation, v2 WAL, document MemTable, v2 Segment, and owned `get` while preserving existing vector-only APIs.
4. Run all document, persistence, public API, and crash tests.
5. Format, inspect `git diff --check`, and commit as `feat: add persistent document collection api`.

### Task 7: Examples, documentation, and full verification

**Files:**
- Modify: `examples/persistent_collection.mojo`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/query-model.md`
- Modify: `pixi.toml` only if a new runnable task is needed

1. Update the example to store chunk text, image URI, MIME type, and scalar metadata, then retrieve payload through a search result ID after reopen.
2. Document the Phase 4.1 API, supported types, v1 compatibility, limits, and Phase 4.2 filtering boundary.
3. Format every changed Mojo file.
4. Run `pixi run test`, `pixi run test-crash`, `pixi run build`, `pixi run smoke`, and `pixi run example-persistent`.
5. Run `git diff --check`, inspect the Phase 4.1 requirement checklist, and commit as `docs: complete document payload storage phase`.

