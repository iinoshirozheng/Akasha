# Mapped point checkpoint recovery

Point checkpoint recovery no longer owns a complete encoded file while decoding
native point values. It maps the immutable file, checks its full checksum, copies
a 48-byte header and decodes one bounded record at a time. Native macOS paired
open measurements reduce high-dimensional process peak memory footprint by about
49%, with about 4% shorter open times. The change is retained. This does not
establish a constrained-memory, sustained-nonresident or native Linux gate pass.

## Source and ownership

The unified v4/v5 checkpoint path used `read_file_bytes` followed by the point
decoder, overlapping the whole encoded buffer with decoded vectors. Legacy
v1/v2/v3 segment recovery already used `MappedFile`. The existing mapping API
has checked copied loads and synchronous checksum operations; no new dependency
or pointer-exporting API is needed. Pinned Qdrant revision
`21db2f3ff95d50de3a2b88a741312c056fd1762d` uses mapped chunk storage in
`lib/segment/src/vector_storage/dense/appendable_dense_vector_storage.rs`.
Akasha retains its independent owned-value and immutable-checkpoint contracts.

Both input paths share header, interval, record-size, point, ordering and version
validation. Record length is checked against the remaining pre-checksum bytes
and the existing 256 MiB record limit before copying. The maximum temporary
encoded allocation is one record, plus the fixed header; decoded state still
scales with live points. The mapping closes on return/error, and no mapped Span
or pointer escapes. Checkpoint inodes must remain immutable during reading,
as for the existing segment reader. Recovery, compaction input loading and
backup validation all use the same changed `load_point_checkpoint` path.
The old whole-file read is removed from that path. Owned byte decoding remains
an existing API; durable v4/v5 bytes and catalog binding are unchanged.

## Native macOS measurements

Three alternating before/after pairs per corpus use the same cloned accepted
trial-0 databases, one fresh Python process per open, and identical collection
configuration. No corpus vector matrix is loaded into the worker. `/usr/bin/time
-l` records process peak memory footprint; `getrusage` records peak RSS and
faults. These are process measurements, including Python/allocator effects,
not a census of engine allocations. All database-file hashes remain unchanged.
No builds/tests/compression overlap these measurements. OS cache is present;
there is no enforced memory cap or cold-open/nonresident claim. Medians:

| Corpus | Before / after footprint MiB | Footprint ratio | Open-time ratio |
| --- | ---: | ---: | ---: |
| uniform-128 | 69.22 / 58.00 | 0.840 | 1.000 |
| uniform-1536 | 261.99 / 133.81 | 0.511 | 0.962 |
| real-1536 | 261.59 / 134.08 | 0.512 | 0.964 |

Ratios are medians of paired ratios, not ratios of the displayed medians.
Uniform-128 open-time ratio is 1.0002308, a slight regression rounded to 1.000.
Initial unpaired baselines are retained separately: high-dimensional footprint
varies between roughly 227 and 262 MiB, so the repeated paired observations
support the comparison. The footprint decrease cannot all be assigned to a
particular allocation from these counters alone. The source change removes
the encoded-file allocation; retained decoded authority remains resident.

## Lifecycle and correctness

Three alternating mixed pairs per corpus preserve all 5,184 response IDs,
F32 score bits, recall, oracle, execution decisions and search statistics.
All 18 reopen checks and 18 retained Arrow leases pass. Workers clone the same
accepted databases and use frozen plans; score-bit capture is outside the timed
search in both versions. This serial foreground diagnostic is not concurrent
load or a fresh Qdrant acceptance matrix. Timing medians are retained in full:

| Corpus | Filter | QPS after/before | p95 after/before |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.033 | 0.993 |
| uniform-128 | correlated | 1.010 | 1.039 |
| uniform-128 | independent | 1.005 | 0.958 |
| uniform-128 | selective | 1.013 | 1.176 |
| uniform-1536 | all | 1.022 | 0.939 |
| uniform-1536 | correlated | 1.022 | 0.892 |
| uniform-1536 | independent | 1.019 | 0.975 |
| uniform-1536 | selective | 1.050 | 0.738 |
| real-1536 | all | 1.032 | 0.988 |
| real-1536 | correlated | 1.030 | 0.930 |
| real-1536 | independent | 1.052 | 0.895 |
| real-1536 | selective | 1.067 | 1.022 |

Uniform-128 correlated/selective p95 and real selective p95 regress. Those
samples are not discarded or offset against gains elsewhere. This patch is
retained for measured recovery memory reduction and unchanged durable behavior;
it does not establish universal query improvement or complete M5/M6.

Validation passes 55 cases across 13 relevant Mojo/crash files, including four
new mapped-reader cases and two crash files. Frozen v4/current v5 roundtrips
preserve encoded native bits after mapping closure and file replacement. Every
truncation and byte flip of four golden files is rejected, as are CRC-valid
bad headers/lengths. V5 sparse zero weights succeed while v4 still rejects them.
Recovery, migration, point store/table, compaction, snapshot, backup, bounded
backup memory and default-field projection checks pass. Rebuilt public tests
pass 387 Python/distributed cases (one skip, three existing warnings) and C.
No new full Mojo, GPU or native Linux suite is claimed. Fixed query-quality
evidence from the parent remains applicable; query/index source is unchanged.

The first new test cannot compile against the parent because the file-reader
entry point is absent. The first candidate compiles but a test incorrectly
expects an increased maximum sequence of 255 to fail; the owned decoder also
correctly accepts it. That fixture is replaced with a genuinely invalid maximum
of zero; no production fix is needed. Original logs and the corrected pass are
retained. This is not presented as a preexisting decoder correctness defect.

Parent: `45e04d2c8b698fcbf9f515958bd2750886d78c7f`. Baseline Python SHA-256:
`ed1c16821d39ebafc29a7ee8d85928322c2b0d968166b7137f8f93e9179c2d3f`.
Candidate Python SHA-256: `2650cb7eda25a60d28412a7a3409a57d2dbc9b9e1d56f20eb3c9dfe253869a10`.

The last formal Qdrant acceptance is the parent
[delta-admission checkpoint](2026-10-16-delta-admission-first.md): warm speed
6/36; mixed matched quality 33/36, speed 12/36; write+flush 3/9. It is not
rerun or relabeled as this patch's acceptance. All remaining strict speed,
native Linux, concurrency, sustained pressure and type/capacity requirements
remain open. A separate emulated Linux capacity follow-up is being prepared;
it is not evidence of a successful gate here.

## Frozen evidence

[Complete archive](results/2026-10-16-point-checkpoint-map.json.gz) contains
161 files (3,724,331 bytes): both source identities, final patch,
new tests, failed/corrected logs, all validation, paired open/mixed reports,
database inventories and deterministic plan metadata. Databases/binaries are
identified rather than embedded. Every embedded hash verifies. Archive SHA-256:
`57b276e2d6c2b295f0d3e9fbb1f0d2c840a67658c8076e23d3e887c142be4949`.
