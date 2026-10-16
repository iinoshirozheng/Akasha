# Streamed cache envelopes and write-stage memory localization

Cache publication now writes the unchanged AKIC header, borrowed payload and
CRC footer directly to the temporary file, then preserves file fsync, atomic
replacement and directory fsync. The owned codec reserves its exact final size
and no longer copies the whole body to append a checksum. No format, search,
authority, workload or acceptance threshold changes.

An isolated native macOS test with an already owned 64 MiB payload measures
additional peak RSS falling from **201,392,128 bytes to 16,384 bytes**. The old
implementation fails the test's 16 MiB bound; the new one passes. Frozen AKIC
bytes, all three kinds, empty and boundary sizes, CRC, independent payload
ownership, atomic replacement of a mapped inode and publication failure are
checked. This result concerns envelope overhead, not total database memory.

## Lifecycle results

The unchanged streamed mixed diagnostic runs 12 workers: three corpora at
6144/256/192/128 MiB, one CPU and no swap, with separate fixture preparation
and zero initial database residency. All controls and all uniform-128 cells
complete. Both 1536-dimensional corpora still OOM at every constrained cap.
All 1,728 responses from completed workers match the prior uninstrumented
controls in IDs, F32 bits and statistics; final reopen oracles pass. Failed
workers remain failures. The real-1536 256 MiB worker records completion of
flush block 4 before being killed; other last-stage records are in the archive.
This single-pass, emulated Linux diagnostic is not a sustained or native Linux
gate pass.

Three alternating native macOS pairs per corpus preserve all 5,184 response
IDs/F32 bits/statistics, 18 reopens and 18 Arrow leases. This is a storage
memory change, not a new Qdrant speed acceptance. All trial timings remain
available, including uniform-128 correlated median p95 ratio 1.144 and real-1536
unfiltered ratio 1.041. Selective tails vary substantially across repetitions;
they do not justify a general speed claim.

Validation: 39 relevant Mojo/cache/crash cases, 387 Python/distributed cases
(one skip, three existing warnings), rebuilt C tests and four new cache tests
under Linux emulation pass. Parent source is `c3a582d`. macOS before/after
SHA-256: `620e396fc7ffcb4c731924f1b5061de131710f596ebfbb96269b3083d7bcb18c`
and `84b57a6bc43f5a56c790b73ed6884f40cc3bdf1ccd72e87d3540f0ca3f63b07a`.
Linux candidate: `e2e450d5bbc13796ba0d194558fd89f1f14a99253bf6e4a9c3407aa7a2052f06`.
Compilation, tests and compression do not overlap measurement workers.

## Native phase evidence and remaining work

An isolated pre-change diagnostic build records native checkpoint, snapshot
and compaction phase markers plus `/proc` and cgroup memory. Both unlimited
high-dimensional controls and the uniform-128 capped control complete and
match uninstrumented responses. Both high-dimensional 128 MiB workers stop
after `snapshot.before_body`, following committed point checkpoint/WAL
retirement and graph validation. Their RssAnon is approximately 122 MiB before
allocating the owned HNSW snapshot body. Both 192 and both 256 MiB workers stop
after `compaction.before_encode`, after loading the separate checkpoint table.
These are allocation boundaries, not precise live-allocation attribution.
Markers can shift failure timing; their timings are not acceptance data.

The initial Python-callback observer fails its first unlimited control with
exit 139 and no OOM flag. That failed attempt is retained but excluded from
conclusions. The replacement observer performs native I/O only and passes its
controls. Its binary SHA-256 is
`052ed6991b08a712eaa58da6da3d7154100e5947f5eaeb17f64da9fd710bf519`.

The next changes must stream HNSW output and bound compaction's input/output
ownership. Envelope streaming alone does not resolve those larger buffers.
The pinned Qdrant source's `lib/common/common/src/fs/ops.rs` provides the relevant
pattern: serialize into a buffered atomic file instead of materializing the
entire encoded output. Existing CRC, validation, publication and recovery
contracts must remain intact.

[Evidence archive](results/2026-10-16-cache-write.json.gz): 663 files,
2,357,474 bytes, SHA-256
`2a3e75d375ca1d8f8ec0e19a6c808c6b18308fc99fd215befe53dd44a7a15fea`.
It contains source snapshots, tests, drivers, builds, jobs, all partial and
completed responses, native phase records and the failed observer control.
Every embedded hash verifies. Full pressure/type/lifecycle, native Linux,
concurrency and strict Qdrant speed gates remain open.
