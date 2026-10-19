# Live checkpoint ownership: validated isolated layer

The isolated mapped-point candidate now replaces live numeric owners after a
successful checkpoint, including the collection projection and cached read runs.
Production remains `a6822c3`; this layer is not installed in the production
package and does not close M5/M6. It builds on the
[inline immutable range candidate](2026-10-20-immutable-point-query.md), whose
query regressions remain unresolved. No new performance result is claimed.

## Reference and implementation

The pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d` storage/borrow
boundary remains the reference: `appendable_dense_vector_storage.rs:81–105`
and `chunked_vectors/read_only/read_ops.rs:88–117`, archived in the preceding
report. Akasha's immutable point records, WAL and exact-file leases determine
its publication protocol. The earlier
[typed live-publication prototype](2026-10-14-mapped-typed-compaction.md)
supplies owner-staging patterns; its older mutation, compaction and recovery
implementations are not copied wholesale.

Six source files change relative to the inline-range prototype:

- PointStore prepares and validates the durable mapped output before committing
  its manifest. A prepared checkpoint retains the previous point descriptors,
  replacement descriptors, output file and retirement paths. Publication replaces
  only numeric owners; accepted versions, payload, sparse/binary owners and stable
  slots remain unchanged. Same-sequence graph updates retain the WAL-before-cleanup
  ordering. The v4/v5 parsers and formats do not change.
- Collection stages its matching projection and read-run replacements before the
  manifest commit. It publishes those prevalidated descriptors before WAL rotation.
  A rotation failure therefore leaves both authorities consistent while requiring
  reopen. The retention object is created outside writer and explicitly released
  after leaving writer on the normal flush, backup and compaction-capture paths.
- Read runs clone descriptors only where the accepted point version matches.
  Their metadata/sparse indexes are shared immutable owners; slots, shadow masks,
  head accounting and sequence remain valid. Held roots keep their old runs.
  Close detaches every cached run, then releases those owners outside writer.
- PointStore, recovery mappings and the collection now share the lease registry.
  Supplied recovery registries must match directory and dimension. Destructor
  cleanup diagnostics no longer disappear into a separate recovery-only registry;
  completing their public observability remains part of the ownership audit.

This implements live flush and standalone PointStore full checkpoints. Collection
foreground/background compaction still performs its existing disk publication;
rebasing those live owners is the next layer. Consequently this is not evidence
that sustained file retention or capacity has been resolved.

## Validation and retained failures

Mojo `1.0.0 (ed45d567)` compiles the candidate. All 130 source hashes remain
unchanged throughout the final validation batch and native binding build.

Two PointStore regressions first fail on the unchanged parent: flush leaves owned
numeric values, and an acquired post-flush point does not retain the source file.
Both pass after implementation. Five additional collection cases cover all five
numeric types and multivectors, nonnumeric owner identity, stable slots, replacement
and deletion, no-op flush, retained snapshots after close, base/head/sealed-run
index reuse, manifest failure and post-commit WAL-rotation failure.

The final evidence covers **77 distinct selected Mojo cases**, **23 checkpoint/WAL
recovery cases**, and **379 distinct Python cases**, with the following precise
qualification of corrected fixtures and harnesses:

- The original 20-file Mojo batch has two failures. Both call disk-only compaction
  directly and expect generation-unpin or explicit reclamation to delete files
  still owned by live mapped rows. Candidate fixture copies instead check that
  those files remain readable, then disappear after the final store/point owner
  releases them. The complete five-case point-compaction file and the one-case
  reclamation fixture pass. Repeated cases are counted once in the 77 total; the
  original failures and both fixture versions are archived.
- The initial Python invocation passes 377 cases and fails two spawned-client
  harness cases. Its unguarded launcher is reimported by multiprocessing after
  tests alter `sys.path`; the binary-identity assertion detects the production
  library in those children. Adding the `__main__` guard and restoring the isolated
  package path before import fixes the launcher. All three cases in that file then
  pass, including one overlapping prior pass, giving 379 unique cases. The failed
  launcher, diagnostics and corrected launcher are retained. These client harness
  tests use an echo engine, not a new concurrent database performance gate.
- Runtime Python cases import the isolated candidate library. Existing static
  source/ABI compilation probes still use repository source. The low-descriptor
  merge check is additionally compiled against candidate source and executed with
  a 32-descriptor limit. This is not native Linux or sustained-memory acceptance.

Initial compilation failures from attempting to copy a move-only Manifest, taking
an Optional rvalue, and iterating move-only projection rows are retained. The final
implementation moves the optional manifest, uses explicit owned test copies and
indexes the projection list. No numerical/search behavior was changed to pass a
test. The pre-unlink durability fence and current four-delta partial compaction
policy remain unchanged.

Native Python library SHA-256:
`128233be2432b6af293958682c64ec59d4fa03bebf864d28aa8363674bef5334`.
No new C, GPU, Linux or fixed Qdrant speed/capacity result is claimed.

## Next publication layer

Give maintenance heap-stable shared PointTable and MemTable authority, synchronized
by the existing writer lock. Map and validate compaction outputs outside writer;
stage matching point/projection/read-run owners before disk publication, then
exchange them without rebuilding indexes. Keep acquired roots and post-capture
updates intact and release replaced owners outside writer, including failure paths.

For partial merges, validate the output kind and sequence interval against
`inputs.first..inputs.limit`, and skip current point versions newer than the last
selected segment's maximum sequence. Using the whole captured manifest's last
sequence would wrongly include later-segment versions in owner-staging validation.
Retain delta tombstones and legacy cutover document-version checks. Test cancelled,
conflicting, corrupt and uncertain publication, appended deltas, newer WAL-only
writes, close and background publication before measuring the complete fixed
performance and sustained-maintenance matrix.

The [evidence archive](2026-10-20-immutable-point-live-flush.json.gz) contains the
complete candidate source, source inventories, tests and fixture adaptations,
failure/success logs, validation drivers and the patch against its parent. Native
binaries, copied databases and unported prior prototype files are excluded.

Archive: 385 text artifacts, 590,690 compressed bytes, SHA-256
`1c6c046e061c3cb7f2fc0eec096356b010c4651b884abe4ad475d3215cbaa0c2`. All embedded hashes and the parent source inventory were verified.
