# Exact file leases and last-reader reclamation

This follows the [immutable sidecar delivery](2026-09-30-hnsw-sidecar-publication.md).
That slice left two lifetime gaps: a snapshot could outlive its collection's
in-memory retirement queue, and open-time cleanup only recognized future-generation
job outputs. A replacement collection had no access to the old pin registry.

## Ownership and cleanup

`GenerationPinRegistry(path, dimension)` now associates the first pin of each
committed generation with a `ManifestFileLease`. It opens the manifest's dense,
sparse and HNSW files and keeps shared advisory locks. Further pins of that
generation share those descriptors. Memory-only registries retain their existing
counting behavior. A missing derived HNSW file remains rebuildable; missing
authoritative input fails capture without adding a pin.

Retirement unlinks only after a nonblocking exclusive file lock succeeds. This
protects independent collection instances and processes, not just one registry.
The final pin release rereads the committed manifest and tries to reclaim its own
files that are no longer referenced. This works after collection close and after
a replacement writer's compaction. Directory-relative `openat`/`unlinkat` keep the
cleanup attached to its original directory if the old pathname is replaced.

The lock conversion is allowed to release the shared lock before acquiring the
exclusive lock. Cleanup happens only after the last local reader has finished,
and only an exclusive-lock winner unlinks. It does not depend on atomic upgrade.
See the [Apple flock contract](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html)
and [Linux flock contract](https://www.man7.org/linux/man-pages/man2/flock.2.html).

Open-time cleanup now considers strict HNSW and compaction job names at any
generation, including their `.tmp` names. It excludes current manifest references
and shared file leases. Unknown/noncanonical names and legacy sequence-only HNSW
names are preserved. A captured foreground compaction retains source writer-file
ownership until publish/discard/build failure, as backups already do; a replacement
writer cannot run orphan cleanup while that operation can still create outputs.
The background worker is drained before the collection releases that ownership.

Last-release cleanup cannot raise through a destructor. Missing manifest authority
preserves files. Corrupt metadata or another I/O failure also records a registry diagnostic.
A live collection retries its retirement queue; reopen retries eligible job
outputs. This does not promise reclamation through an unrepaired filesystem failure
or automatic deletion of arbitrary/unknown files. Existing format bytes and public
query APIs are unchanged by this follow-up.

## Behavioral evidence

`test_file_retirement.mojo` has nine regressions covering final release after close,
a replacement writer, two independent collection registries, a renamed/replaced
directory, failed capture, cleanup failure, acquired compaction after close, stale
job outputs at past/current/future generations, and an independent reader process.
The process test waits for a real captured snapshot, lets a replacement writer
flush/compact/close, checks that leased files still exist, then releases the reader
and checks reclamation without another writer operation.

Existing backup and foreground/background compaction tests now check immediate
last-release reclamation instead of expecting an extra flush. The same-sequence
crash fixture restores captured pre-cleanup bytes before reconstructing a crash
window; normal last-release cleanup otherwise removes the old graph before the
fixture rewinds its manifest. All five sidecar publication boundaries remain
covered, including retaining the committed graph and removing the unreferenced one.

The additional filename cases preserve malformed generations, overflowing claims,
unknown names and double-temporary suffixes. Legacy v3 migration and strict v4
fixtures remain in their existing suites.

## Measurement and validation

`benchmarks/mojo/file_lease_bench.mojo` isolates first file-lease capture, a shared
pin/unpin pair, release while still referenced and release after retirement. It
records 31 samples and 1,024 shared pairs per sample with a 32-point collection and
no background worker. It does not measure complete snapshot capture or query
latency. Persistent first capture reads bounded manifest metadata and opens one
descriptor per referenced file plus its directory; last release reads metadata
and may unlink/fsync. No authoritative vector or payload bytes are copied by this
ownership step.

On Darwin arm64 with Mojo 1.0.0 (ed45d567), after validation processes finished,
the run had two or three referenced immutable files per sample, plus the directory.
Metadata was already cached. Median first capture was 38 µs (31–112 µs), a shared
pin/unpin pair 50.8 ns (47.9–58.6 ns), referenced release 12 µs (9–20 µs), and
retired release including unlink/fsync 63 µs (44–116 µs). These are small-file-set
diagnostics, not cold-filesystem latency or an extrapolation to large manifests.

Validation on the current worktree based on `31f27e5`:

- All 94 Mojo CPU test files: 761 tests passed. `pixi run test` exposed the stale
  background-retention and last-use snapshot assertions. After correcting them,
  every current file has a passing result; the snapshot file was rerun directly
  and the remaining files completed without repeating earlier unchanged successes.
- `pixi run test-python`: rebuilt extension, 66 passed, two existing deprecation
  warnings. `pixi run test-c` and `pixi run build` passed. All three built examples
  ran successfully, including configured BF16 HNSW reopen.
- All six crash files: 19 passed. `pixi run test-crash` exposed the fixture issue
  described above; its six HNSW tests passed after correction and the remaining
  sparse/WAL files passed directly. Earlier passing crash files were retained.
- No scoring/build algorithm or GPU execution path changed. The previous slice's
  two external quality gates remain applicable; the current CPU run also includes
  all HNSW quality, quantization, mutation and publication tests. No new GPU or
  Linux-host claim is made.

The complete source/test inventory SHA-256 is
`b5d2ca3e0cbbd307b473ca34754923402114babf384caac172078f8248ccde38`.
Hash sorted `rg --files src tests native include python` paths as relative path,
NUL, file bytes, NUL; ignored binaries are excluded. The changes after the initial
CPU run were test assertions/fixtures only, and those files were rerun against
their final contents. [Per-file results and raw measurement samples](results/2026-09-30-file-retirement.json)
record the source identity, commands, counts and limits.

This closes #56's file-lifetime implementation gap. Matched-recall comparison
(#59), the remaining Arrow/WAL/type work and branch integration remain open.
