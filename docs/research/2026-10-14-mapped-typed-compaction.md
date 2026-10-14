# Publish typed compaction owners to both live authorities — 2026-10-14

**Unadopted.** This isolated implementation closes the
typed live-compaction publication gap in the
[direct dense-owner candidate](2026-10-14-mapped-compaction-fields.md).
Production engine `6d01819` and its Python/C libraries remain unchanged. This
candidate has no new speed, capacity, sustained-nonresident or native Linux
result. M5/M6 remain unfinished; every required cell still needs Recall@10 ≥ .95,
QPS ≥ Qdrant and p95 ≤ Qdrant without tolerance or offsets.

Six engine files change in `.build/m5-resume/mapped-typed-compaction`.
PointStore now owns a heap-stable `ArcPointer[PointTable]`. The collection passes
that same authority to maintenance during construction, before starting its
worker. Mutation remains protected by the existing writer lock; reference
counting supplies ownership, not synchronization. Close joins maintenance before
clearing the shared table. No raw pointer into a movable collection is retained.

Output preparation maps and validates typed segments outside writer exclusion,
including catalog, checksum, base kind and captured sequence. Before disk commit,
staging validates the accepted point and its shared read projection. Successful
publication exchanges only numeric fields in both authorities. It preserves
slots, payload/sparse/binary owners, document versions, accepted sequence and
checkpoint sequence. Points changed after capture retain their newer fields.
Previous numeric fields and detached read runs remain owned until outside the
writer lock. Public APIs and durable formats are unchanged; no dependency is added.

The migration boundary needs its existing durable-format contract: before the
first typed flush, background compaction can still capture legacy segments.
Migration anchors point sequences at the catalog cutover, so comparing those
sequences directly to old dense-row sequences is wrong. This path now validates
the preserved document version and exchanges matching default dense owners in
both authorities. Later typed versions remain untouched.

Eight new regression cases cover:

- Five numeric dtypes and multivectors, unchanged nonnumeric owners, stable slots,
  old snapshots, and reclamation after the last reader releases the old mapping.
- Prepared output followed by newer WAL-only writes or an appended delta,
  including field updates, deletion and insertion, followed by reopen.
- Corrupt output, mismatched expected checksum and missing output; unchanged
  manifest/authorities, released job pin/source lock, retry and reopen.
- Background publication with a newer write, a borrowed Arrow UInt8 slice after
  collection close, empty output, and publication after close.
- Legacy-prefix migration, failed manifest publication, and replaced-input conflict.

The initial owner-address regression fails on the unchanged parent and passes
after implementation. The new migration case independently fails before its fix.
All attempts are retained, including the constructor compile failure and a test
lifetime assertion corrected to use the held field at the required boundary.

An existing disk-only point-compaction fixture also needed its lease expectation
updated: `finish_compaction` does not exchange an open PointStore's mapped fields.
Unpinning a generation therefore cannot delete files still owned by that store.
The adapted case checks the retained files, closes the store, reads the separately
held field, then verifies deletion on last release. The original failed fixture
and result are retained; this is not reported as an unchanged test pass.

Current-source validation passes **122 selected Mojo cases, 23 crash cases,
359 Python tests and C ABI**. Both rebuilt libraries and every counted source/test
snapshot match the final engine sources. All 54 child compiler invocations pass
the wrapper-path audit; earlier failed/control attempts remain separately recorded.
Unchanged successful suites were reused after a fixture-only
correction; the failed fixture/result remain separate. No new full CPU, Metal,
Linux or capacity gate is claimed.

Python binary SHA-256:
`bba71ea80d943178ed0e5e29311a485b6e0c2939e1bfec24c9d1837770543034`.
C binary SHA-256:
`ef9f665c402b0b2e9246f19f5418ee7b25f987b16b6006af8eb554b46e0f1118`.

The next capacity experiment must distinguish mapped authority segments from
derived HNSW inputs; the old worker's HNSW-only observations cannot certify exact
query residency. Warm mapped-reader regressions and all strict performance gates
remain unresolved. Typed flush retains its existing read-cache reset behavior.

[Complete sources, controls, failures and validation](2026-10-14-mapped-typed-compaction.json.gz)
contain 6,539 files, 26,595,157 compressed bytes, SHA-256
`975a2eea7241febcf43575dcc9122386519be62517bf11a99787b00d0f5aaf0d`.
Archive integrity and every embedded hash were verified. Binaries are excluded
and identified by hashes. The archive also contains the engine diff and the
remaining capacity work's source-role measurement notes.
