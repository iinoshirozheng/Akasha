# Live compaction ownership: validated isolated layer

The immutable-point candidate now rebases live numeric owners after foreground,
background and selected-range compaction. PointStore, its collection projection
and matching read runs publish the same checked owners while keeping later writes
and acquired snapshots intact. This extends the
[live-checkpoint layer](2026-10-20-immutable-point-live-flush.md).
Production remains `a6822c3`; no new speed or sustained-capacity acceptance is
claimed, and M5/M6 remain open.

## Qdrant source and adapted design

The reference is pinned Qdrant
[`21db2f3`, `lib/shard/src/optimize.rs:478–640`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/optimize.rs#L478).
Its `finish_optimization` takes the updates lock, propagates pending vector/index
and point changes, swaps segments, syncs the segment manifest and registers
deferred old-segment destruction. That destruction is gated by the durable
waterline and retains a WAL acknowledgement pin. The exact source and Apache
license are archived; the local checkout's different HEAD is not the reference.

Akasha adopts the short serialized publication and delayed reclamation principles
within its existing immutable point-record, WAL and exact-file lease protocol.
It does not introduce Qdrant's proxy-segment architecture or claim identical WAL
acknowledgement mechanics. Nine source files change from the live-flush parent:

- PointTable and MemTable now have heap-stable shared owners. The collection and
  maintenance worker use those same authorities under the existing writer lock;
  the worker holds no pointer to a movable collection. Close joins the worker and
  detaches the rows before releasing their owners outside writer.
- Compaction output is mapped and checked outside writer. Typed and legacy paths
  check checksum, kind and the selected interval before staging publication.
  Typed output also rejects a legacy sparse sidecar. The legacy decoder shares
  the existing header/order/CRC parser and preserves all float bits.
- Staging checks accepted point/document versions, field identities and matching
  projection ownership before committing the manifest. It skips current versions
  newer than the **last selected segment**, including later segments already in
  the captured manifest. Legacy cutover checks use the retained document version.
- Successful publication exchanges only numeric field owners in both authorities
  and matching read runs. Payload, sparse/binary owners, stable slots, sequence
  counters, tombstones and shared run indexes keep their established semantics.
  Acquired roots retain their old rows; retired owners are released outside writer.
- Legacy segment validation and encoding borrow the dense numeric reader instead
  of materializing the public List. Checked reader skips reject negative/overflow
  counts without advancing, and mapped skips reject a closed file.

The current four-delta partial policy, v4/v5 point contracts, pre-unlink directory
durability fence and public owned-value getters are unchanged.

## Validation and retained failures

Mojo `1.0.0 (ed45d567)` compiles the isolated candidate and Python native library.
The final 130-file source inventory is unchanged across the validation/build
batch. Results:

- **191 cases in 37 selected Mojo modules**, including the current maintenance,
  background publication, migration, partial compaction, checkpoint, snapshot,
  generation, named-field, HNSW projection and legacy-reader regressions.
- **23 checkpoint/WAL recovery cases** in eight modules.
- **379 distinct Python cases**. The main run passes 378 and skips the optional
  Qdrant adapter because its restored pinned dependency directory was omitted
  from that invocation. The skipped case then passes with that directory on
  `PYTHONPATH`. Candidate library identity is verified in every launcher process.
- The candidate merge probe builds and exits successfully with **32 file
  descriptors**. Existing Python static-source and ABI probes still inspect
  repository source; they do not establish a new candidate C ABI or Linux gate.

The first new live-compaction test fails on the unchanged live-flush parent:
numeric ownership still points at the retired source. It passes on this layer.
Eight new live cases cover all five numeric types plus multivectors, post-capture
WAL-only/flushed writes, corrupt/missing/wrong-checksum outputs, background
publication, a retained Arrow byte slice after close, empty output, close during
publication, migrated legacy data, manifest failure and conflicting publication.
An additional partial-range case exercises both a base prefix and a middle delta
range, preserving a later captured version and a tombstone without rebuilding run
indexes. Three parser/skip cases check exact nonfinite/sign-zero bit preservation,
uncached re-encoding and invalid input bounds.

Retained failed attempts distinguish implementation defects from fixture changes:

- Initial compilation rejects moving a field directly through an Arc dereference;
  in-object take methods detach the rows safely.
- The adapted legacy test initially requests ID 1 from a fixture containing IDs
  81 and 82. It now asserts existence and uses the actual fixture IDs; its behavioral
  assertions are unchanged.
- Re-encoding first materializes the legacy mapped numeric cache. Borrowed readers
  fix that regression. A new closed-file skip check also first fails, then passes
  with the existing mapped-file open check.
- The initial aggregate does not compile because three private checkpoint/flush
  calls predate the parent's required retention argument. Isolated test copies
  retain those objects across the writer scope. The inherited disk-only compaction
  fixtures continue to require a file lease to outlive its final mapped reader.

Native Python library SHA-256:
`6c8e8af37b5a11a6bfb5b34dc05be7b1d36fbb958c0b7e941b69cde1c834eb23`.

## Remaining acceptance

This closes the isolated live compaction publication layer, not the complete
ownership/performance objective. Remaining work includes the other consumer and
destruction/error-reporting paths, full type/lifecycle integration, and fresh fixed
warm/concurrent query and sustained-maintenance capacity gates. Native Linux and
actual-device GPU gates retain their previous status. The preceding candidate's
18/36 mixed quality-plus-speed result remains historical and is not updated by
these functional checks. No thresholds, workload definitions or per-cell failure
requirements change.

The [evidence archive](2026-10-20-immutable-point-live-compaction.json.gz) includes
the complete candidate source, patch against the verified parent, source and test
inventories, adapted tests, failure/success logs, pinned Qdrant source, validation
drivers and Python package source. Native binaries and copied databases are
excluded. Archive: 381 text artifacts, 643,531 compressed
bytes, SHA-256 `5b4e39907d6af713f2a4c9428ab6b7850429c6bc88032aaa1c273364170846f7`. All embedded hashes and the parent inventory
were verified.
