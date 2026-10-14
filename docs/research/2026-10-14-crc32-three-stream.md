# Three full ARM CRC batches — not adopted

Three independent CRC chains reduce the fixed 64 MiB checksum microbenchmark
median from **6.286 to 2.351 ms**, with identical checksums. Complete native
operations do not establish acceptance: mixed query passes fall **32 → 27 / 36**
and combined write+flush falls **5 → 4 / 9**. The candidate is not adopted.
All failed cells remain; production engine source and binaries are unchanged.

The parent is the frozen [payload-writer-reuse candidate](2026-10-14-payload-writer-reuse.md).
Only `storage/checksum.mojo` changes relative to it. The altered Mojo adaptation
uses zlib's three adjacent batches of 3,990 UInt64 words and fixed polynomial
combination. Complete 95,760-byte groups use independent chains; the original
serial word/byte remainder and architecture/CRC-feature dispatch remain byte for
byte unchanged. There is no thread pool, retained buffer or new runtime library
dependency. The subtraction guard proves every unaligned load remains in bounds.
The complete zlib notice is retained in source; upstream source/header/license
and hashes are archived. This implements only full batches from
[zlib 1.3.2, pinned commit](https://github.com/madler/zlib/blob/da607da739fa6047df13e66a2af6b8bec7c2a498/crc32.c#L460-L514),
without its variable-size final batch.

Three new tests pass against both parent and candidate. They check a separate
bitwise oracle across 16 alignments, four initial registers, batch/tail boundaries
and streaming splits, real protected pages at both ends, and all 32 register
basis vectors over zero batches. Existing successful new-case results are reused
in the broader validation rather than rerun unchanged.

Fresh broader validation passes **119 Mojo cases in 20 files**, **17 crash-state
cases in six files**, **369 Python cases**, and C ABI compilation/execution.
Checksum, mapped file/reader, WAL/segment v1, HNSW v1/cache, point WAL, sparse
storage and checkpoint/torn-tail/atomicity cases are covered. Python has three
existing warnings and no skips; library builds have no warnings. All five target
assembly files are retained: M4 and generic ARM +crc each contain four `crc32x`
sites (three streams plus remainder) and byte instructions; M4 -crc, generic ARM
and Linux x86-64 have none. This is cross-compilation evidence, not native Linux
execution or performance.

The expanded suite exposed a separate inherited fixture typing issue. Three
previously unrun tests passed list literals directly to the span-based writer.
All three fail to compile against the parent too. Explicit `List[UInt8]` fixture
variables preserve every input byte and assertion; all **17 cases pass against
both production and the parent**. The corrected cases also pass in the CRC suite.
The initial candidate failure, three parent failures, before/after sources and
both successful fixture runs are retained. The earlier
[span report](2026-10-14-payload-span-encoding.md) now corrects its overly broad
implicit-conversion claim. These three fixture typing changes are the only
production-checkout code edits; the engine remains unchanged.

The microbenchmark retains all **165 observations**: 11 sizes, five rotating
serial/candidate/zlib triples, with the initial register varied every repetition.
All preflight and aggregate checksums match. The frozen serial and candidate
helpers keep the same `always_inline` contract.

| Buffer | Serial median | Candidate median | Candidate / serial |
| --- | ---: | ---: | ---: |
| 6 KiB | 504.944 ns | 512.269 ns | 1.0145 |
| 64 KiB | 5.500 µs | 5.521 µs | 1.0037 |
| 95,760 bytes | 8.149 µs | 2.876 µs | .3529 |
| 1 MiB | 91.219 µs | 39.906 µs | .4375 |
| 64 MiB | 6.286 ms | 2.351 ms | .3740 |

Installed zlib's 64 MiB median is 2.418 ms. Short inputs do not obtain the large
buffer benefit; their complete observations, including regressions, remain raw.

All **54 serial native workers** complete with unchanged corpora, ef, filters,
plans, oracles, timing boundaries and rotating triples. Warm takes 46.63 s and
mixed 65.97 s. Each version passes quality 36/36 in both phases. IDs, Float32
bits, statistics and execution decisions match; leases and reopen oracles pass.
All 18 overlay/metadata payload pairs are byte-identical with valid CRCs. Mixed
returns its expected strict-gate failure only after all nine triples finish.

| Phase | Strict speed before → after | Pass → fail | Fail → pass |
| --- | ---: | ---: | ---: |
| Warm query | 21 → 23 / 36 | 2 | 4 |
| Mixed query | 32 → 27 / 36 | 5 | 0 |
| Mixed write+flush | 5 → 4 / 9 | 1 | 0 |

Warm pass→fail cells are uniform-1536 selective trial 1 and real-1536 all trial 0.
Mixed loses all four uniform-1536 trial-2 modes and real-1536 all trial 0. Real-1536
trial-2 combined p95 rises from 37.799 to 39.565 ms, exceeding Qdrant's 38.075 ms.
Uniform-1536 trial-2 combined p95 also worsens 38.2%. No trial is excluded or its
cause assigned without evidence.

Only six of nine flush QPS pairs improve; after/before ratios span .8940–1.0928.
Combined QPS improves six pairs and p95 improves five. Cached same-process reopen
improves seven of nine pairs (ratios .9349–1.0028); fresh-process initial open
ratios range .8698–1.9808. OS cache is present, so neither closes nonresident gates.
The Python library grows only 160 bytes; this does not explain the query changes.

The [archive](2026-10-14-crc32-three-stream.json.gz) contains **890 files,
4,168,046 bytes**: full source/notice and diffs, upstream material, exact tests and
all failed attempts, assembly, microbenchmark, C/Python identities, every native
worker, byte audits and verified parent/plan references. Every embedded hash is
verified. No full CPU/crash-kill, native Linux, capacity, HTTP or GPU acceptance
is claimed. M5/M6 remain incomplete.

- Python SHA-256: `11248327cf552e93e6374f299af6ab538b1eecd487379fd693753498fff1ceb4`.
- C library SHA-256: `2e084c24b00941a801f81574f5c284c965f993f1cce813041cf58eede21a8bdc`.
- Archive SHA-256: `c5946480d5c580b1a2da621a43fee8763b7dcd56836e7c3fdaeffa0c497877c8`.

The next bounded experiment addresses the actual fingerprint row span: a
1536-dimensional F32 row is 6 KiB and never enters this full-batch loop. Evaluate
one smaller fixed group with the same CRC algebra, retain the large-group failure,
and require byte/bounds/feature proofs and complete operational evidence again.
Query parameters and acceptance thresholds remain fixed.
