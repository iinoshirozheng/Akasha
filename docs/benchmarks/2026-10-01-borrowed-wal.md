# #62: bounded borrowed dense-WAL recovery

The dense WAL now uses owner-backed byte spans and bounded envelope I/O.
Collection recovery consumes decoded mutations without retaining the complete
dense history. On the fixed 256-ID, 50,000-record, 128D/1 KiB-payload workload,
median open time changes from **491.702 to 254.319 ms**, and peak process RSS from
**398.500 to 16.453 MiB**. These are fresh-process measurements with a warm OS
page cache, not disk-cold latency or a resolution of the missing-HNSW-sidecar gap.

Implementation, measurement and integration validation are complete. This
package remains uncommitted.

## Ownership and recovery changes

- `BorrowedBinaryReader` stores an origin-backed immutable byte span. The owned
  `BinaryReader` keeps its existing API; both use the same little-endian primitive
  reader. Subtraction-based bounds reject `Int.MAX` requests without overflow or
  cursor advancement. Payload decoding borrows name/string byte ranges and returns
  independent owned fields. No returned field retains the input buffer.
- `WalReader` reads ahead 64 KiB and grows only for a complete, size-validated
  envelope. It validates CRC-32/ISO-HDLC directly over source spans, removing the
  whole-file decode copy, per-envelope copy and payload byte-list copies. An
  envelope prefix crossing a read boundary may be compacted inside the buffer.
  A failed reader cannot be resumed past the corrupt envelope.
- The encoded buffer is bounded by `max(64 KiB, largest accepted envelope)`.
  Decoded output for one envelope is separately owned and bounded by the existing
  record/batch limits. V3's existing 256 MiB limit remains; this does **not** claim
  total recovery RAM is 64 KiB. Growing a List can temporarily retain both old and
  new allocations. No reader or subspan survives a buffer refill.
- Collection open merges dense envelopes with sparse mutations in sequence order,
  transferring vector/payload allocations directly into the MemTable. Dense deletes
  still remove sparse state, including delete/reinsert histories. A compatible
  committed HNSW sidecar replays a second bounded pass under the same collection
  lock, preserving historical update order without retaining all dense payloads.
- Tail repair retains accepted/source lengths, opens the existing file without
  create/truncate flags, checks its current length, then calls `ftruncate` and
  `fsync`. Accepted bytes are never rewritten. Repair and identity publication
  remain after complete authoritative/sidecar recovery preflight. A missing or
  length-changed file is rejected without overwriting it.

The owned `decode_wal_bytes`, `preflight_wal`, `replay_wal` and `recover_wal`
interfaces still return owned records. Their output necessarily grows with history;
the collection path uses the cursor directly. Sparse-WAL decoding, segment decoding,
and the live MemTable/index memory are outside this dense-WAL buffer bound.

## Compatibility evidence

The same compiled probe runs against the saved pre-#62 source and the new source.
All **1,853 cases** produce identical decoded record counts/content digests and
accepted prefix lengths for both owned-byte decoding and file preflight. The corpus
includes mixed v1/v2/v3, every truncation point, bit flips, recomputed-CRC mutations
of headers and bodies, duplicate sequences, and partial final headers. Generation
source, labels, corpus hash and complete outputs are in the raw artifact.

Four reader/payload regressions cover scalar bits, UTF-8/sliced pointer identity,
overflow bounds and owned-result lifetime. Ten streaming regressions cover
independent mutation ownership, no-copy authority transfer, all torn boundaries,
shortening during preflight, error poisoning, read boundaries and large envelopes,
deferred repair, unchanged prefixes, repaired append, stale/missing-file repair,
corruption and missing/empty inputs. Existing migration tests still reject a later
corrupt sparse source without repairing a torn dense WAL or publishing identity.

The pinned Mojo 1.0.0 compiler accepts the positive borrowed-reader/I/O probe and
rejects a local-owner view escaping with a static origin. It does **not** reject
every owning-List mutation while a span remains live; the unsafe mutation probe
was compiled but deliberately never executed. Buffer reuse is therefore scoped
explicitly. See the [API probe](../research/2026-10-01-borrowed-wal-api-probe.mojo)
and its [evidence](../research/2026-10-01-borrowed-wal-api-probe.json).

## Fixed workload and measurements

Mojo 1.0.0 (`ed45d567`), MAX 26.5.0, macOS ARM64. The benchmark uses the same source
and public interfaces in two separately compiled executables. Each fixture repeatedly
replaces one of 256 IDs; every seventeenth sequence deletes its ID. The final state
is checked independently from sequence arithmetic, including vector values, payloads
and deleted IDs. Replay checks every record. Preparation is excluded from timing.

Three fresh-process trials alternate engine order. Each run receives a fresh fixture
copy. The driver uses `wait4` for each child's peak RSS, avoiding cumulative child
maxima. All 42 runs pass the content checks and preserve the expected WAL hash; torn
tails are removed to exactly the original valid fixture. Times below are medians.

| Operation | History | Dimension / payload bytes | Before ms | After ms | Before peak MiB | After peak MiB |
|---|---:|---:|---:|---:|---:|---:|
| Owned replay | 10,000 | 128 / 1,024 | 82.064 | 39.689 | 61.922 | 29.984 |
| Collection open | 10,000 | 128 / 1,024 | 144.221 | 97.934 | 62.297 | 16.438 |
| Owned replay | 50,000 | 128 / 1,024 | 425.378 | 197.284 | 398.109 | 97.375 |
| Collection open | 50,000 | 128 / 1,024 | 491.702 | 254.319 | 398.500 | 16.453 |
| Owned replay | 50,000 | 8 / 0 | 38.731 | 23.216 | 37.859 | 22.703 |
| Collection open | 50,000 | 8 / 0 | 103.237 | 81.581 | 38.266 | 14.500 |
| Open + torn-tail repair | 50,000 | 128 / 1,024 | 562.424 | 257.553 | 398.500 | 16.438 |

The first unbuffered cursor reduced memory but made the small-record open case
slower (100.797 to 110.212 ms in the exploratory pair). Fixed read-ahead removed
the two-syscalls-per-record cost; that exploratory result is retained. No runtime
fallback to the whole-WAL decoder was added.

The two larger collection-open cells demonstrate that increasing dense history
fivefold does not increase retained dense-history memory. They do not establish
constant memory for larger live datasets, huge batches, sparse histories, all
dimensions or all index configurations.

## Validation and reproducibility

- `pixi run build`: passed, followed by all three compiled examples.
- Python: 118 passed, three existing deprecation warnings; rebuilt extension and
  `PYTHONPATH=python:.:.build/qdrant-compare/deps`.
- `pixi run test-crash`: 19 passed.
- C ABI: rebuilt shared library, compiled with `-Wall -Wextra -Werror`, test passed.
- `pixi run check-hnsw-quality`: six cells passed; `check-post-hnsw-quality`: all
  11 cells passed, all four filter modes at recall 1.0.
- `pixi run test-mojo`: all 98 CPU test files passed, **789 tests**, no failures
  or skips. This includes the new reader/stream tests and existing migration,
  sparse, HNSW recovery, batch, snapshot, file-lifetime and format checks.
- GPU behavior is unchanged; no actual-device GPU rerun is claimed.

Source hash over sorted `src/tests/native/include/python` paths and bytes:
`bedef6a261417bce6ad45e53cfb3ffff3f61d6b7c144123909646a65c47e1924`.
The [raw artifact](results/2026-10-01-borrowed-wal.json) contains all timing samples,
fixture/binary hashes, benchmark/probe/driver source and validation evidence.
The [source archive](results/2026-10-01-borrowed-wal-sources.json.gz) contains all
91 Mojo source files before and after, plus the locked toolchain manifests.

#63, typed-field migrations, and M5/M6 warm/cold performance remain separate
unfinished work. In particular, avoiding dense-WAL history copies does not make
a missing committed HNSW sidecar available on reopen.
