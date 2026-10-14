# Three ARM CRC streams over a fingerprint row — not adopted

A fixed 6,144-byte group makes the existing 1536-dimensional F32 fingerprint row
eligible for three independent ARM CRC chains. Six high-dimensional native flush
QPS pairs improve **11.0–21.3%**; their combined write+flush QPS and p95 also
improve. Acceptance remains incomplete: warm query passes fall **22 → 21 / 36**,
including two new failed cells. Mixed query stays **33 / 36** and combined
write+flush **6 / 9**. This candidate is not adopted; production source and
binaries remain unchanged.

The parent is the frozen [payload writer](2026-10-14-payload-writer-reuse.md),
not the failed [large-group CRC variant](2026-10-14-crc32-three-stream.md).
Only `storage/checksum.mojo` changes. The latter's three-stream implementation
is reused with exactly three 256-word chunks and polynomial `0x4D47BAE0`.
Installed official zlib's `crc32_combine_gen64(2048)` supplies that operator and
reproduces the previous 3,990-word operator; the function, library identity,
inputs and outputs are retained. There is one fixed group size, no tuning sweep,
new dependency, thread, retained buffer or durable-format change. The original
scalar remainder and architecture/CRC-feature dispatch are verified unchanged.
Full upstream notice and pinned [zlib source](https://github.com/madler/zlib/blob/da607da739fa6047df13e66a2af6b8bec7c2a498/crc32.c)
remain in the archive and adaptation.

Three new row-boundary cases pass against the unchanged parent, then all six
row/large-group cases pass against the candidate. A separate bitwise oracle
checks 16 alignments, four initial registers, streaming splits and both group
boundaries; protected pages check both ends, and all 32 register basis vectors
check zero batches. The unchanged previous large-group parent success is reused
by exact source/test identity. Broader validation passes **122 Mojo cases in
21 files**, **17 crash-state cases in six files**, **369 Python cases**, and all
three C ABI stages. Python reports three existing warnings and no skips; builds
have no warnings. All five target assemblies pass: ARM M4/+crc contain the four
expected `crc32x` sites, while -crc, generic ARM and Linux x86-64 do not. This is
cross-compilation evidence, not native Linux performance.

The microbenchmark retains **280 observations**: 14 sizes, five rotating trials
of frozen serial, row group, installed zlib and the previous large group. Initial
registers vary each repetition; preflight and aggregate checksums agree. Both
Mojo helpers preserve the same `always_inline` contract.

| Buffer | Serial median | Row-group median | Previous large-group median |
| --- | ---: | ---: | ---: |
| 6,143 bytes | 507.140 ns | 509.520 ns | 506.683 ns |
| 6,144 bytes | 510.804 ns | 204.084 ns | 504.944 ns |
| 12 KiB | 1.019 µs | .414 µs | 1.031 µs |
| 64 KiB | 5.748 µs | 2.563 µs | 5.911 µs |
| 95,760 bytes | 8.090 µs | 3.506 µs | 2.834 µs |
| 1 MiB | 88.797 µs | 38.016 µs | 35.766 µs |
| 64 MiB | 5.674 ms | 2.463 ms | 2.216 ms |

Installed zlib takes 511.262 ns for 6,144 bytes and 2.225 ms for 64 MiB. The
row-sized benefit has a larger-buffer tradeoff versus the previous variant;
all short-input and large-input regressions remain. Microbenchmarks alone do
not establish acceptance.

All **54 serial native workers** complete using the original corpora, filters,
ef values, plans, oracles, timing boundaries and rotating triples. Warm takes
44.05 s and mixed 64.32 s. Each version passes quality **36/36** in both phases.
Every paired result ID, Float32 bit, statistic and execution decision matches.
All leases and reopen oracles pass; all **18 overlay/metadata payload pairs**
are byte-identical with valid envelope and snapshot CRCs. Mixed returns its
expected strict-gate failure after all nine triples complete.

| Phase | Strict speed before → after | Pass → fail | Fail → pass |
| --- | ---: | ---: | ---: |
| Warm query | 22 → 21 / 36 | 2 | 1 |
| Mixed query | 33 → 33 / 36 | 0 | 0 |
| Mixed write+flush | 6 → 6 / 9 | 0 | 0 |

Warm loses uniform-128 selective trial 1 and real-1536 selective trial 1; it gains
uniform-1536 selective trial 2. These failures are retained without attributing
a cause. The fixed strict recall/QPS/p95 conjunction is unchanged.

| Corpus | Flush QPS after/before, trials 0 / 1 / 2 |
| --- | --- |
| Uniform 128D | 1.0414 / 1.0161 / 1.0076 |
| Uniform 1536D | 1.2131 / 1.1104 / 1.1182 |
| Real 1536D | 1.2115 / 1.1365 / 1.1277 |

All nine flush QPS pairs improve. Flush p95 improves six pairs; uniform-128
trials 1/2 and uniform-1536 trial 1 regress. High-dimensional flush medians fall
from 17.805–19.351 ms to 15.177–16.554 ms. Their combined write+flush QPS improves
4.9–9.1% and p95 falls 1.1–12.8%, yet all three uniform-1536 combined cells still
fail Qdrant parity. Uniform-128 combined trial-2 QPS regresses .0095%, while its
trial-1/2 p95 regress 1.7%/2.7%; none is excluded.

Fresh-process initial open improves only one of nine pairs (ratios
.9839–1.0911), and same-process reopen improves two (ratios .9657–1.1108).
OS cache is present; neither is nonresident/cold-disk evidence. The larger
checksum microbenchmark benefit does not imply whole-operation open gains.

The [archive](2026-10-14-crc32-row-stream.json.gz) contains **873 files,
4,167,884 bytes** with every embedded hash verified: full sources and notices,
exact tests, assembly, raw micro/native results, source/binary identities,
cache-byte audits, and verified parent, previous-experiment and original-plan
references. No full CPU/crash-kill, native Linux, capacity, HTTP or GPU gate is
claimed. M5/M6 remain incomplete.

- Python SHA-256: `29f9fcbeaded77a24bc95bd1e2133b7416fd8bda46af7ec0cf75418ca60ca91e`.
- C library SHA-256: `f4f9e6f863a90e6cf1e708fd5ce4547423e122d81a31f28524390e54805372db`.
- Archive SHA-256: `855a527a83ecccf735b6cc988357df2d7f7bec50858676b09cf59f75120fd09b`.

The next independent query experiment reuses the existing four-row F32 kernel
inside the bounded delta scan. It must preserve admission, physical order,
score bits, counters and query breadth, and face the same complete native gates.
