# Bounded legacy batches and ordered metadata updates

Legacy batch commits now stage only affected IDs, sharing existing immutable
field owners, and publish final entries under the writer lock after the existing
v3 WAL envelope is fsynced. Stable slots and first-appearance ordering are retained.
Repeated updates preserve the last mutation; any delete clears sparse state even
when a later mutation recreates the dense point. Unchanged live payloads skip
posting removal/reinsertion after validation. Type, field order and Float64
signed-zero bits remain significant. The three posting types use binary key
search and standard `List.insert`/indexed `pop` instead of full searches and
adjacent swaps. Bulk loading retains its existing append/sort contract.

WAL or derived publication errors now leave the collection requiring reopen.
An I/O exception cannot prove whether the complete envelope reached disk. Old
immutable snapshots remain usable; recovery exposes the whole accepted batch or
repairs the incomplete tail. No persisted format or checksum changed.

See the [design and dependency/reference inspection](../plans/2026-10-02-bounded-batch.md).

## Paired measurement

`benchmarks/bounded_batch.py` alternates a saved pre-change package and the rebuilt
package in separate sequential processes, three times for each prior corpus.
Both use the same apple-m4/metal:4 compiler target. Each version first ingests
8192 points in 256-point batches into a new collection, then separately clones
the closed post-update baseline for the 32-block mixed workload: nine reads,
eight replacements, flush, with one retained Arrow row/root through close.
Oracles are prepared outside workers; no build or test runs overlap sampling.
These are resident Python binding measurements; Qdrant is not remeasured here.

Every 5,184 returned ranking passes the independent live-ID/filter/count/recall
audit. All 72 per-version filter/trial cells meet .95 recall with valid execution
classification. Every final reopened exact query and retained lease check passes.
The final archive includes all samples, plans, hashes, disk inventories, peak RSS,
the unsuccessful first screen and both versions of the inventory collector.

Ratios are **after / before elapsed time**, median with complete three-trial range:

| Corpus | Total ingest | Eight-point write p95 | Flush p95 |
| --- | --- | --- | --- |
| Uniform 128D dot | 1.000 (.930–1.114) | .511 (.428–.564) | .561 (.429–.995) |
| Uniform 1536D dot | 1.009 (.974–1.087) | .722 (.690–.842) | .953 (.844–.954) |
| Real 1536D cosine | .982 (.484–1.327) | .748 (.093–5.138) | 1.059 (.306–4.665) |

All write p95 samples in milliseconds, in trial order:

| Corpus | Before | After |
| --- | --- | --- |
| Uniform 128D | 13.908, 19.510, 16.011 | 7.839, 8.358, 8.190 |
| Uniform 1536D | 32.198, 37.513, 43.682 | 27.114, 27.084, 30.152 |
| Real 1536D | 23.481, 194.239, 24.191 | 120.646, 18.076, 18.101 |

Real-data dispersion is substantial: both versions have a slow trial affecting
open, queries, writes and flushes. The run does not isolate its cause. Retain those
trials; the median is not evidence of consistently lower real-data tail latency.
Flush publication was not changed, so its noisy ratios are not attributed to this
optimization. Ingest medians are near parity; individual runs differ materially.

The first screen, before ordered posting updates, slowed ingestion by 12.4% while
reducing write p95 by 38.4%. That intermediate implementation was not retained.
During the third 1536D pair, the original collector raced segment retirement
between enumeration and `stat`. The worker closed normally in `finally`, but its
timings had not yet been written and are unavailable. The failed database and
diagnostic are retained locally. The completed five pairs and third-pair ingest
sample were reused; only the interrupted worker used a new baseline copy.
Subsequent active inventories record files that vanish during enumeration and
explicitly represent a non-atomic observation. Future worker exceptions also save
already collected samples before propagating the failure.

## Verification

Eight batch regressions, ten metadata-index and twelve field-index tests pass.
They cover append failure, partial derived publication after commit, restart,
immutable snapshots, repeated/negative IDs, ordinals, untouched owner pointers,
sparse delete/reinsert, signed zeros, strict types, duplicate postings and removal
during unsorted bulk loading. Relevant MemTable/WAL/persistent sparse/HNSW and
torn-batch recovery checks pass. The rebuilt extension passes **316 Python tests**.
The broader integration gate is tracked separately; this report does not mark
the remaining M5/M6 parity or non-resident work complete.

[Raw archive](results/2026-10-02-bounded-batch.json.gz), SHA256:
`83d335e24d31e4e0627cdee6b0f180639f9aab9eb86dc5d449de5be49b4de0bf`.
