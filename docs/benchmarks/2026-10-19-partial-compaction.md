# Size-based partial point compaction

Automatic maintenance previously rewrote the complete base for small deltas.
The retained change selects contiguous delta ranges by file size, preserves their
latest tombstones, and publishes the merged delta without rewriting the base.
Explicit `compact()` and `schedule_maintenance()` retain full-merge behavior.

## Baseline and source evidence

Baseline is `268582c`, including the pre-delete durability fence. The original
nine diagnostic workers use the same frozen uniform-128, uniform-1536 and
real-1536 mixed plans. Median base share of merge input bytes is
98.54%/98.69%/98.37%; input bytes per selected delta byte are
68.37/76.51/61.44. Counts include outputs subsequently discarded at close.
These are logical file bytes, not measured physical disk I/O; the builder also
validates checksums and traverses records twice.

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d`,
`lib/shard/src/optimizers/merge_optimizer.rs:111–157`, sorts candidates by
available-vector bytes and forms size-limited batches. Its first batch must
contain at least three inputs unless another batch is available. Pinned RocksDB
`6dbb6f30e604e0047db29f06fe1c28c348074c98`,
`db/compaction/compaction_picker_universal.cc:908–1035,1139–1245`, selects
contiguous sorted runs and checks space amplification. Its default universal
options use 1% size slack and 200% maximum additional space
(`include/rocksdb/universal_compaction.h:134–137`). Akasha adopts these selection
principles while preserving its ordered sequence coverage; it does not copy
Qdrant's arbitrary size sort into a sequence-ordered manifest.

## Protocol

At the existing four-L0 trigger, automatic capture leases and revalidates the
whole committed manifest, then measures file sizes outside the writer lock.
If delta bytes are at least twice base bytes, it merges the full prefix.
Otherwise it accumulates newest-to-oldest contiguous deltas with 1% size slack,
requiring at least four inputs. If no compatible group exists, it chooses the
cheapest adjacent four, reducing L0 count by at least three. The existing
backpressure limit remains eight L0 files.

A range after the base emits an existing kind-2 point v5 delta with unchanged
sequence bounds and the latest complete state, including tombstones. A range
starting at the oldest input emits a kind-1 base and drops covered tombstones.
The two-pass cursor builder validates every selected record, including obsolete
versions, before claiming its output; it still uses one decoded head per input.
Legacy dense/sparse checkpoints retain full merging. No durable schema changes.

Publication validates the captured whole manifest as the current leading run,
then writes `untouched prefix + output + untouched suffix + appended tail`.
It retains current committed sequence and HNSW authority and retires only selected
files. Source ownership, file leases, serialized builders, retry limits, file/
directory fsync, cancellation, and pre-delete durability fencing remain in place.
This does not introduce concurrent disjoint compaction jobs.

Flush, synchronous threshold-based maintenance, and no-worker backup/flush use
automatic selection. Explicit scheduling forces full coverage even below the
threshold. A pending explicit request dominates automatic requests in either
coalescing order. The first candidate failed seven existing background tests
because it treated explicit scheduling as automatic; preserving request intent
fixes those tests without changing their assertions.

## Verification and measurements

The initial three-input policy reduces logical merge outputs 96.8–97.4%, but
increases built/published jobs to 15 in every diagnostic worker. Uniform-128
selective QPS falls to 0.948x and p95 rises to 1.467x (six alternating pairs).
That batch policy is rejected. The retained policy requires four deltas, matching
the existing trigger; it accepts more delta rewriting to reduce publication
frequency. All retained diagnostic workers build and publish ten jobs.

Median logical output volume per 32-block diagnostic worker:

| Corpus | Baseline output MiB | Retained output MiB | Reduction |
| --- | ---: | ---: | ---: |
| uniform-128 | 61.150 | 7.046 | 88.48% |
| uniform-1536 | 496.933 | 51.035 | 89.73% |
| real-1536 | 397.547 | 51.035 | 87.16% |

Baseline built jobs are 9/10/8 at the per-corpus median, with some cancelled at
close; the retained ten-job policy still publishes more often than the full-base
baseline. Both partial policies avoid reading the base in these diagnostic merges.
Job counts establish the scheduling difference; they do not attribute every
latency change to publication alone. Trace timings are not acceptance timings.

Retained/baseline median ratios from six alternating uninstrumented pairs per
corpus (QPS higher is better; p95 and operation time lower is better):

| Corpus | Mode | QPS | p95 |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.010 | 1.072 |
| uniform-128 | correlated | 1.027 | 1.021 |
| uniform-128 | independent | 1.021 | 1.063 |
| uniform-128 | selective | 1.019 | 0.938 |
| uniform-1536 | all | 1.033 | 0.952 |
| uniform-1536 | correlated | 1.047 | 0.950 |
| uniform-1536 | independent | 1.040 | 0.911 |
| uniform-1536 | selective | 1.073 | 0.884 |
| real-1536 | all | 1.025 | 0.990 |
| real-1536 | correlated | 1.033 | 0.987 |
| real-1536 | independent | 1.038 | 0.937 |
| real-1536 | selective | 1.046 | 0.899 |

| Corpus | Flush total | Write total |
| --- | ---: | ---: |
| uniform-128 | 0.980 | 0.978 |
| uniform-1536 | 0.980 | 0.976 |
| real-1536 | 0.972 | 0.957 |

All twelve corpus/mode throughput medians improve, but this is **not** a complete
latency win: uniform-128 all/independent p95 regress to 1.072x/1.063x, and correlated
p95 to 1.021x. These remain follow-up work. Every trial is retained, including real
selective trial 3 at 2.250x p95. Baseline and candidate workers run sequentially on
macOS ARM64; no build, test, container workload or archive compression runs during
timed comparisons. Plans, queries, ef, oracle checks and recall thresholds are
unchanged; no outlier removal or retuning of quality gates is used.

Reopening after the writes takes 1.009x/1.013x/1.018x at the paired median.
After close and final Arrow-lease release, disk inventory is
1.054x/1.058x/1.058x. Partial merging retains superseded base rows until a
full-prefix merge; logical deletions take effect immediately. The 200% additional
space trigger is relative to base file bytes, not current live-data bytes.
Explicit compaction remains the way to force complete base reclamation. These
costs are recorded along with the substantial reduction in rewrite volume.

Verification:

- The initial protocol passes 141 relevant native Mojo/recovery cases, 388
  Python/distributed cases (one skip, three warnings), C, and 61 Linux-emulated
  cases. This covers typed v4/v5 records, updates/deletes, snapshot/backup leases,
  append/rebase, stale outputs, corruption, output I/O failures, cancellation,
  backpressure, torn publication and direct fsync failure.
- After the batch-size adjustment, the six partial-compaction cases and 26
  background/maintenance cases pass again on native Mojo; Python/distributed
  388 (one skip, three warnings) and C pass on the final binary. The same 32
  affected Mojo cases pass in Linux emulation. Unchanged protocol checks above
  remain applicable; this is not a new full CPU-suite claim.
- Across baseline diagnostics, both candidates' diagnostics and both sets of
  alternating pairs, all 28,512 response audits from 99 workers match the
  original frozen IDs, F32 score bits, recall, execution checks and stats.
  All 99 exact reopens and 99 Arrow leases pass; minimum mode recall is 0.956944.
  The retained uninstrumented comparison contributes 10,368 audits/36 workers.

Binary SHA-256 identities:

- Baseline Python: `55d16d66769e3dbce395ea027efe1a9d897eb4d5582410a863167559d5e3395a`.
- Three-input Python: `aa16ef8d948bfbfab858ea6313f46802da1e2bd579880fdd8222deeeb8301815`.
- Retained Python: `1f114146390568e2f1518d81ee606728d99f22bb78e2d7bf5ed755ebce8de55c`.
- Retained C: `cd11721cf6457debd990f2ed9bc375519003722c2583fa5adf690e77d4b1c287`.

The archive records separate source identities and binaries' hashes for every
instrumented clone, plus the failed trials and reproducible measurement drivers.


## Failure records and remaining work

The baseline inline test fails because automatic compaction changes the base
filename. Initial test fixtures required ownership fixes for FieldCatalog and
Manifest; the three-input size-policy fixture was corrected from 30 to 31 because
a 30-byte older run fits the accumulated 30-byte candidate. The retained four-input
fixture uses 41 to stop a 40-byte accumulated group. The first diagnostic import
preceded a module docstring and failed to build; the corrected clone builds.
All failed attempts are retained separately from final validation.

The previous Linux build directory was absent on resumption. The first validation
attempt stopped before running tests. The build-only runtime was recreated from
the project's pinned pixi manifest/lock; compiler identity remains Mojo
1.0.0 (ed45d567). Ordinary Linux tests run as UID 501/GID 20 so chmod faults remain
meaningful; the direct fsync-injection wrapper uses the activated root toolchain.
Linux x86_64 is emulated and supplies correctness evidence only.

No formal Qdrant gate is closed by this local change. The last formal checkpoint
remains `45e04d2`: warm speed 6/36, mixed matched quality 33/36, speed 12/36,
write/flush 3/9. The three Qdrant real-correlated recall failures at frozen ef
remain failures. Full type/lifecycle and sustained-capacity coverage, both
128 MiB mixed-pressure failures, concurrency scaling, and native Linux performance
remain open. Prior full CPU and cgroup results are not claimed as fresh results.

## Evidence

[Complete evidence archive](results/2026-10-19-partial-compaction.json.gz):
848 text artifacts, 4,696,170 bytes, SHA-256
`ff9c907394526a96ce31b71bb2a3a2c4baff7ec3b558984dc8b004f86df97ec0`.
It includes original and retained byte traces, both sets of timing pairs,
all validation/failure logs, source snapshots and patches, source/binary identities,
and reproducible drivers. Frozen input plans/databases retain their original
identities, and the prior archive is linked in the archive metadata.
