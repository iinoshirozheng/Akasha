# HNSW immutable sidecars and captured backup

This is the durable part of #56, built on the separately measured
[unlocked rebuild](2026-09-30-hnsw-rebuild.md). It changes sidecar names and
ownership; the HNSW v1/v2 graph bytes and authoritative data formats are unchanged.

## Publication and migration

Manifest v4 names a sidecar as `hnsw-<sequence>-<creation-generation>-<claim>.bin`.
The reader validates canonical UInt64 components, sequence equality, a positive
creation generation no newer than the manifest, reserved fields and CRC. V3 keeps
its exact sequence-only filename contract. An independent Python `struct`/`zlib`
fixture fixes the v4 bytes; old manifest and HNSW fixtures remain unchanged.

Each writer attempt exclusively creates a new pathname, writes/fsyncs the graph,
and fsyncs the directory before committing the manifest. Same-sequence rebuild
and disable/re-enable cannot replace a pinned file. A manifest publication error
leaves the job output because its rename may already have committed; retries
claim a different name. Superseded sidecars enter the existing generation-pin
retirement queue. Compaction carries an existing v3/v4 reference unchanged.

Tests cover v3 reopen followed by same-sequence migration, old-file retention
until pin release, publication failure followed by a distinct retry, future-job
cleanup, every truncated v4 fixture prefix, noncanonical/overflow/path names,
unknown versions and frozen v3 rejection of v4 names. Five same-sequence crash
states exercise torn output, durable output, durable manifest temp, committed
manifest before cleanup and completed cleanup. Reopen selects the committed
graph and serves ANN without rebuilding.

## Backup ownership and verification

Backup now copies its complete captured manifest, including HNSW, outside the
writer mutex. Dense/sparse CRC excludes magic; HNSW CRC includes it. The shared
streaming copier retains only its configured buffer plus 64 HNSW header bytes,
and checks graph version, header size, reserved fields, sequence, configuration
fingerprint and live count before file publication. The destination manifest
remains last. Inspection/restore strictly validates every referenced sidecar;
normal collection recovery retains its documented missing-derived-state rebuild.

A captured copy also holds a strong owner of the source advisory file lock.
Collection close rejects further operations and drops its lock owner; an active
backup prevents a replacement writer from reclaiming paths through a different
pin registry. This does not hold the writer mutex or delay writes on the original
open collection. The regression first failed because a replacement collection
could open after close, and passed after the lock ownership change.

Coverage includes source flush/compaction while captured files remain pinned,
buffers of 1/3/4/5/7/4096 bytes, corrupt/mislabeled/truncated source files,
checksummed-but-inconsistent HNSW headers, BF16 graph format v2, recovery after
deleting the original source, and torn HNSW backup copy followed by retry.
The existing 128 MiB bounded-copy memory gate also passes.

## Verification

Source: worktree based on `31f27e5`, Mojo `1.0.0 (ed45d567)`, MAX 26.5.0,
macOS arm64. Aggregate source SHA-256 over the sorted source/test/native/include/
Python file paths and bytes:
`5e798ea74a91f77fb150aca3fc240dc39dbaa43bfb6f8cdee48fc749c55ec348`.
CPU/Python ran against `a81dcba21b11be72e114a30714afdfbdb08f363c22bf620bc041026251f1bcbe`;
the only subsequent source change updated the crash rebase test's legacy filename
assertion to check the v4 sequence and original creation generation. Engine,
bindings and CPU/Python test sources remained unchanged.

- All 93 Mojo CPU test files: 752 tests passed using individual
  `pixi run mojo run -I src tests/mojo/<file>.mojo` invocations.
- `pixi run test-python`: rebuilt extension, 66 passed; two existing dependency/
  extension deprecation warnings remain.
- All six crash test files: 19 passed. The initial `pixi run test-crash` stopped
  at the stale sequence-only filename assertion in `test_checkpoint_order.mojo`.
  That assertion now verifies v4 sequence and creation generation. Its seven
  tests passed on rerun, as did all remaining crash files; the already passed
  backup and atomic-batch tests were retained.
- `pixi run check-hnsw-quality`: all six cells recall 1.0.
- `pixi run build`, `pixi run test-c` and all three built example executables:
  passed on macOS arm64.
- `pixi run check-post-hnsw-quality`: 11 metric/scalar cells × four filter modes,
  all recall 1.0. Selective filters intentionally used exact fallback (rate 1.0);
  the other three modes reported no fallback. This is not a Qdrant comparison.

[Per-file results, commands and quality output](results/2026-09-30-hnsw-sidecar-validation.json)
record the complete validation inventory for this slice.

The attempted `pixi run test > ... 2>&1` crashed inside Mojo before the first
test. A direct file invocation passed; a separately redirected collection-lock
test also exited 133 and its direct invocation passed. The successful per-file
run covers the complete CPU test inventory, with no skipped failing test.
Crashpad initialization during formatting was denied by the sandbox; formatting
itself exited zero. These tooling diagnostics are separate from test outcomes.

## Remaining boundaries

Checkpoint sidecar I/O still runs under writer locking; graph construction and
bounded catch-up are outside it. Restore validation still has O(segment) memory,
whereas copying is bounded. At this slice's validation checkpoint, the conservative orphan policy removed only
job outputs from future generations on open: unreferenced outputs at or below the
committed generation, and retired files still pinned at collection close, can
remain on disk. Unique names do not resolve that lifecycle limitation.

The subsequent [exact file lease follow-up](2026-09-30-file-retirement.md) resolves
these lifetime gaps, with separate source identity and validation evidence.

No GPU execution path changed; the actual-device gate is not rerun here. The
Qdrant matched-recall/real-embedding comparison (#59), #57–#63, named vectors,
native scalar authority types, binary and multivector support remain required.
