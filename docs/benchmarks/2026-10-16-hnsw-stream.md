# Streamed HNSW snapshots: bounded encoding, remaining pressure failures

HNSW sidecars and overlay caches now serialize through the same borrowed byte
stream as the owned codec. The file path no longer materializes the entire
snapshot or a second envelope. **All six high-dimensional constrained mixed
workers still OOM**, so this change does not close the lifecycle capacity gate.

## Implementation and compatibility

`HnswSnapshotEncoder` completes the existing configuration, graph, vector,
layout, size and decode-allocation checks before an output pathname is opened.
An immutable origin-bound graph borrow spans preflight and emission. The writer
borrows native little-endian F32 bytes, encodes other scalars and graph sections
in bounded chunks, and computes incremental checksums. The owned codec reserves
one final-size buffer and consumes the same stream. Overlay publication nests
the HNSW stream within AKIC; the inner footer is covered by the outer CRC.
File fsync, close, atomic rename and directory fsync retain their existing order.
Entry encoding and graph validation still have graph-dependent memory costs.

This follows the pinned Qdrant source's serialize-into-file pattern in
`lib/common/common/src/fs/ops.rs`. It does not change format versions, graph
topology, query arithmetic, authoritative state or acceptance thresholds.
The F32 tape currently reaches the file sink as one borrowed span; bounded
encoding memory must not be confused with bounded syscall size or total cgroup
memory. Mojo 1.0's `write_all` passes borrowed remaining bytes to `write_once`,
which invokes the OS write call; this does not establish the runtime/emulator
or kernel's allocation behavior. See the
[versioned standard-library source](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/io/file.mojo#L427-L507).

Twenty-two frozen files were captured with the pre-change encoder at `d06c812`,
covering all eleven supported metric/scalar combinations, empty graphs and
deleted/replaced points. Owned, sidecar and nested overlay output match byte
for byte. Additional tests cross encoding chunk boundaries for all four scalar
kinds, verify mapped decoding, reject invalid graphs before truncation, and
preserve the published overlay when opening its temporary path fails.

For an already built graph with a 64 MiB F32 tape, the old sidecar writer raises
peak RSS by **177,930,240 bytes** and fails a 16 MiB bound. The streamed sidecar
and overlay show **no measured increase above the prior process peak** in both
native macOS and emulated Linux tests. This is a high-water measurement, not a
claim of zero allocations. The new path still needs its small buffers and
validation state.

## Uninstrumented lifecycle measurements

The existing 32-block streamed query/write/flush/reopen diagnostic is unchanged:
N=8192 Dot/F32, frozen plans and ef values, one CPU, zero swap, separate 6144 MiB
preparation containers and verified zero initial `.bin` residency. Workers run
serially without compilation, tests or compression overlap. Linux remains
x86-64 emulation on the ARM Mac, not native Linux.

| Corpus | Cap MiB | Result | Last recorded operation | Acknowledged batches / completed flushes |
| --- | ---: | --- | --- | ---: |
| all three corpora | 6144 | complete | after_close | 32 / 32 each |
| uniform-128 | 256 / 192 / 128 | complete | after_close | 32 / 32 each |
| uniform-1536 | 256 | OOM | before_flush, block 4 | 5 / 4 |
| real-1536 | 256 | OOM | before_flush, block 4 | 5 / 4 |
| uniform-1536 | 192 | OOM | before_query, block 3 | 3 / 3 |
| real-1536 | 192 | OOM | before_query, block 4 | 4 / 4 |
| uniform-1536 | 128 | OOM | before_flush, block 0 | 1 / 0 |
| real-1536 | 128 | OOM | before_flush, block 0 | 1 / 0 |

All 1,728 responses from completed workers match prior controls in IDs, F32
bits, statistics and execution paths; all mode means meet recall 0.95 and all
six final reopen oracles pass. All failures are Docker-confirmed OOM kills,
not preparation errors or timeouts. Six separate uncapped recovery workers
reopen those same killed databases and verify 152 acknowledged rows across
19 batches, including native vector bits, complete payloads and exact oracles.

Three alternating native macOS pairs per corpus preserve all 5,184 response
audits, 18 final reopens and 18 Arrow leases. Timings remain diagnostic, not
a fresh Qdrant acceptance. Relevant regressions are retained: uniform-1536
selective median p95 ratio 1.1285 (QPS 0.9780) and real-1536 selective p95
1.0378. No search-speed improvement is claimed.

## Native phase follow-up

An isolated instrumented build has three successful controls matching all
864 query responses and six OOM workers. Both 128 MiB traces reach
`snapshot.before_vectors`, after preflight and node output, at RssAnon
125,024 / 125,016 KiB. They do not reach `snapshot.after_vectors`. The complete
snapshot sizes are 5,249,292 / 5,213,276 bytes. The original whole-body copy is
gone; the next investigation must distinguish the large borrowed write, kernel
file charges and runtime/emulation overhead at the already tight resident
baseline. No exact allocation owner is established by these phase boundaries.

The uniform-1536 192 MiB trace loads a separate checkpoint table, raising
RssAnon from 132,776 to 183,988 KiB, then completes `live_points()` descriptor
capture at 184,624 KiB before output encoding fails to complete. PointState
copies share immutable vector/payload owners; this descriptor capture is not
another full vector copy. The separately decoded table and entire encoded
compaction output remain the larger ownership costs.

Higher-cap traces expose overlapping foreground cache writes and background
compaction. Their marker records can interleave because each marker uses
multiple file writes and has no thread ID. The last marker cannot identify
which thread caused the process-wide OOM. Some 256 MiB traces stop at a vector
write or metadata fingerprint instead of compaction, and real-1536 192 MiB
contains interleaved records. All raw traces are retained; these observations
do not overturn the uninstrumented failures or justify assigning every kill
to the latest marker. A future concurrent observer needs per-thread framing.

## Validation and identities

64 relevant Mojo/cache/compatibility/crash cases, 387 Python/distributed cases
(one skip, three existing warnings), rebuilt C tests and five new tests under
Linux emulation pass. The first Linux test invocation bypassed Pixi activation
and could not find the standard library; the corrected activated invocation
passes. The initial native pair driver omitted its measurement helper and
failed before running a workload; the helper was restored and the complete
18-worker matrix passes. Both failed harness attempts remain in the evidence.

- Parent: `d06c812`.
- Native macOS before: `84b57a6bc43f5a56c790b73ed6884f40cc3bdf1ccd72e87d3540f0ca3f63b07a`.
- Native macOS after: `d3a5120ccc489a3b13e7dbf53be29d5d3bebc2705d8c6e2a6c00d7c2d4fcd96b`.
- Linux after: `79f457a225ae4ae4c65c6d622f8627957e62173e9f5a0ec1814165bd6f4192f0`.
- Linux phase probe: `534c947d0cb76bc4d3d574ecf3e4254ea8fdf5153330b4d771644d94db88312f`.

[Evidence archive](results/2026-10-16-hnsw-stream.json.gz): 567 text artifacts,
2,112,012 bytes, SHA-256
`f8d3106767ec20d4a1725d37a047a0a140f7bed371d3e5a860a7169876487759`.
It retains sources, frozen fixture identities/capture driver, tests, failed
harness attempts, all measurement jobs/results, OOM recoveries and native
phase traces. Every embedded hash verifies. The binary fixtures are separately
committed under `tests/fixtures/hnsw-stream`. Compaction memory, bounded I/O
pressure, full type/lifecycle coverage, concurrency, native Linux and strict
Qdrant speed gates remain open.
