# #63: borrow fingerprint entries and check sparse liveness directly

Implemented and verified in the worktree on 2026-10-01; not yet committed.
The before snapshot is the completed #62 engine. Only two production call sites
change: fingerprinting uses `entry_ref_at`, and sparse upsert uses `ordinal_for`
plus `is_live_at`. Existing public owned reads, serialization, CRCs and mutation
ordering are unchanged. This completes #63, not typed-field support or M5/M6.

## What was actually removed

Since #49, an owned `MemTableEntry.clone` shares its field owners. Replacing it
with an immutable reference removes the descriptor, reference-count traffic and
temporary empty owners; it does not remove dense/payload serialization. A copied
source with instrumentation observes 128 `entry_at` calls per 128-row fingerprint
before, zero after. The complete fingerprint still visits every slot and encodes
its vector and payload before calculating the CRC.

The sparse existence check previously constructed an owned `DocumentRecord`.
The source path copies its vector List and payload-field List. Four updates now
make zero owned `get` calls instead of four. The public `get` used after timing
still calls that path, providing a positive instrumentation control.

**Payload content length is not physical copied bytes.** The pinned
[Mojo 1.0 String implementation](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/collections/string/string.mojo#L601)
shares heap storage on copy. A compiled pointer/isolation probe confirms shared
string addresses for 32-byte, 4 KiB, 1 MiB and 8 MiB values, independent vector
and field Lists, and independent content after modifying the returned document.
The probe obtains addresses through immutable arguments: a mutable StringSpan
would itself detach the copy. The raw trace's `payload_content_bytes` records
logical content only, including field names; it is not an allocation/memcpy count.
In particular, this change does not remove an 8 MiB string memcpy per update.

## Measurements

Mojo 1.0.0 (`ed45d567`), MAX 26.5.0, macOS ARM64. Before and after binaries use the
same benchmark source and toolchain. Each cell has three paired trials, alternating
engine order, with fresh processes. No compiler or test ran during timing.
Instrumented binaries are separate and never contribute latency samples.

All vectors have 64 F32 coordinates. Fingerprinting performs one untimed warmup
and five timed complete fingerprints. Sparse trials perform 32 public updates on
one existing point, including WAL append/fsync. Setup and postcondition reads are
outside the timer. Times below are medians divided by operations per trial.

| Operation | Points | String bytes | Before ms/op | After ms/op | Before / after peak MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fingerprint | 128 | 0 | 0.181600 | 0.125800 | 13.422 / 13.438 |
| Fingerprint | 128 | 4,096 | 1.348200 | 1.305000 | 15.172 / 15.172 |
| Fingerprint | 8,192 | 0 | 7.432600 | 6.778600 | 24.156 / 24.156 |
| Fingerprint | 8,192 | 4,096 | 78.184000 | 77.555600 | 123.078 / 123.062 |
| Sparse update | 1 | 0 | 0.040844 | 0.039500 | 13.672 / 13.656 |
| Sparse update | 1 | 4,096 | 0.039906 | 0.038344 | 13.781 / 13.797 |
| Sparse update | 1 | 1,048,576 | 0.035688 | 0.038594 | 18.891 / 18.125 |
| Sparse update | 1 | 8,388,608 | 0.049344 | 0.054406 | 53.969 / 53.938 |

Large-payload fingerprinting remains dominated by serialization. Sparse latency
does not show a consistent improvement: the two larger payload medians are slower
in this run. No broad sparse throughput or peak-memory improvement is claimed.
Peak RSS comes from `wait4` for the whole child, including setup and the owned
postcondition read; it is not an isolated operation allocation measurement.

The unchanged #39 workload uses 8,192 base points, 64 dimensions, 4,096-byte
payloads and 16 replacements, with seven paired trials. Public incremental flush
median is **161.730 → 160.377 ms**; process peak RSS is **283.000 → 282.984 MiB**.
Every durable `.bin` filename and SHA-256 matches within every pair. These small
differences do not establish an end-to-end memory or throughput gain. Flush still
has full fingerprint and other existing costs; it is not delta-only work.

## Correctness and verification

- Six independently encoded fingerprint fixtures freeze CRCs for empty state,
  negative/extreme IDs, signed zero, all payload types, replace, tombstones,
  delete-missing and reinsert. Sparse-only field changes leave the checksum intact.
- Sparse validation keeps its error order for deleted/missing/negative IDs and
  consumes no sequence or WAL bytes on rejection.
- An actual filesystem append failure preserves sequence, sparse postings, WAL
  bytes and the large dense document; retry and reopen succeed. The initial
  missing-parent test was corrected because FileHandle creates parent directories.
  The final test uses an existing regular file as a parent and passes before and
  after the production change.
- **49 targeted Mojo tests pass** across `test_index_cache`,
  `test_persistent_sparse`, `test_persisted_index_cache`,
  `test_persistent_collection`, `test_generation_fields` and `test_snapshot`.
- `pixi run build-python` passes; the rebuilt binding passes **118 Python tests**
  with the same three existing deprecation warnings.
- 48 direct timing runs, 14 flush timing runs, six separate trace runs and five
  owned-get pointer/isolation cases pass their postconditions. Checksums and sparse
  durable files match in all direct pairs; all flush durable files match.
- The unchanged crash/publication, C ABI, build/examples, GPU and quality paths
  retain their applicable prior evidence. The complete #62 CPU/crash/quality gates
  are documented [here](2026-10-01-borrowed-wal.md); they were not rerun for these
  two read-only substitutions. `git diff --check` passes.

## Reproduction and scope

Build `benchmarks/mojo/readonly_copy_bench.mojo` against the archived before and
after source roots, then run the exact driver embedded in the
[raw artifact](results/2026-10-01-readonly-copies.json). The existing
`benchmarks/flush_compare.py` reproduces the flush comparison. The raw artifact
includes the benchmark/driver/test sources, all samples and checksums, trace
instrumentation, independent fingerprint bytes, probe source/output and official
String source. The [source archive](results/2026-10-01-readonly-copies-sources.json.gz)
contains all 91 Mojo source files for each side and the locked toolchain files.

Verified source hash over sorted `src/tests/native/include/python` paths and bytes:
`52a4568989c0d900b45782261a3be921b0a82a90b830e89434e2e6d490018959`.
Named fields, atomic combined mutation, native scalar/binary/multivector formats
and the measured warm-query/missing-sidecar reopen gaps remain unfinished.
