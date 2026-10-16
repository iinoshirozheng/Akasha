# Point checkpoint capacity after bounded mapped reads

The mapped checkpoint change fixes six repeated 192 MiB open/read failures:
both 1536-dimensional corpora change from OOM in all three trials to completing
in all three trials. The 128 MiB high-dimensional cases still fail. This is
**emulated Linux x86-64 on the ARM Mac**, not native Linux performance and not
a Qdrant recall/speed or sustained-nonresident acceptance matrix.

## Corrected controlled method

The before source is `45e04d2`, after is `f2781df`; only point segment decoding
and its recovery call site differ. Both complete source trees and Python
packages are frozen. Mojo 1.0.0 (`ed45d567`) builds both libraries successfully.
The four new mapped-decoder tests also pass on this emulated target.
Baseline binary SHA-256:
`1b0931f8899f9cf0088f273645c84b59e83aa4e57d4928352d1ede30e03d541f`.
Candidate binary SHA-256:
`2a11d86596c637aaafd52b41c96a3cbf7a9bf4697684d710c8719f22a35b7e28`.
The immutable image is `sha256:540414f50b96439a6ba1475b79b2e2dd2208e86ebef33e2fbf2a176a8f037d31`.

All three accepted N=8192 Dot/F32 trial-0 fixtures are retained unchanged, with
their original graph/config/metadata. Each constrained worker has one CPU,
zero swap and the same 128/192/256 MiB cap. Three alternating before/after
pairs run per corpus and cap, plus one 6144 MiB control pair per corpus.
Builds, tests and compression do not overlap workers.

Preparation runs in a **separate 6144 MiB container**, copying each job to fresh
inodes on a Linux Docker volume, fsyncing files and requesting FADV_DONTNEED.
It exits before the constrained worker starts. Both preparation and measurement
verify zero initial residency for all nonempty `.bin` files via mincore.
Code/reports use a host bind mount; the database uses the Linux volume.
No cache eviction occurs during open or queries. The worker does not load the
original corpus/query matrix. It opens the collection, runs one zero-vector
exact request and one zero-vector ANN request at ef=128, then closes.
Those two response checks are read-path sanity checks, **not recall evidence**.
No QPS/p95 pass or cross-engine parity is inferred.

## Results and remaining failure

All six controls complete. Under caps, baseline completes 15/27 workers and
candidate completes 21/27. All 42 completed workers' two responses match both
control implementations exactly (84 ID/F32-bit checks). All 18 failures are
Docker-confirmed OOM kills, exit 137, after the persisted `before_open` stage.
There are no preparation failures or timeouts in the corrected matrix.

| Corpus | Cap MiB | Before completes | After completes |
| --- | ---: | ---: | ---: |
| uniform-128 | 256 | 3/3 | 3/3 |
| uniform-128 | 192 | 3/3 | 3/3 |
| uniform-128 | 128 | 3/3 | 3/3 |
| uniform-1536 | 256 | 3/3 | 3/3 |
| uniform-1536 | 192 | 0/3 | 3/3 |
| uniform-1536 | 128 | 0/3 | 0/3 |
| real-1536 | 256 | 3/3 | 3/3 |
| real-1536 | 192 | 0/3 | 3/3 |
| real-1536 | 128 | 0/3 | 0/3 |

The open operation includes lazy native module initialization. Last-stage
records locate the failure within that operation; they do not identify a
specific allocation or decoder row. Per-stage process anonymous/RSS/fault
observations and cgroup memory counters are retained. Cgroup peak/current also
include charged file cache; they are not engine-owned allocation totals.

The change removes transient encoded-file storage. Decoded point authority
remains owned, and the 128 MiB failures are unresolved. This short open/read
diagnostic does not measure sustained pressure, maintenance, ingestion,
full type coverage or a recall-matched query matrix. The earlier full memory
matrix is not relabeled as passing. Native Linux and all outstanding M5/M6
performance requirements remain open.

## Preparation failure retained

An initial real-only probe and first three-corpus matrix copied data **inside**
the constrained worker. Most high-dimensional 128 MiB failures stopped during
fixture copying (`before_copy`), so they cannot be attributed to engine open.
Some reached `before_open`; every original result and stage is retained.
The 192 MiB baseline failures already reached `before_open`. Moving preparation
to its own container changes only the diagnostic setup, not engine source,
data, queries or limits. The corrected complete matrix above is the comparable
capacity result. Early commentary attributing every 128 MiB failure to open
was corrected when the stage evidence became available.

## Evidence

[Complete archive](results/2026-10-16-point-map-capacity.json.gz): 876
files, 942,162 bytes. It includes source/package snapshots, compiler
and mapped-test logs, every initial/corrected job/report/inspection, preparation
records, source/input hashes, runtime manifests and drivers. Databases and
binaries are identified rather than embedded. All embedded hashes verify.
Archive SHA-256: `75533006cd46a4e282229a6c902ff2dd3ed5fd26f276f9d43f97e2695613dd64`.

## Subsequent cache-loading fix

The [mapped-cache follow-up](2026-10-16-cache-map.md) localizes the remaining
128 MiB failures to overlay graph decoding and removes redundant cache-envelope
copies. Its unchanged controlled matrix completes 27/27 capped candidate jobs,
including all six previously failing high-dimensional 128 MiB cases. This
supersedes the unresolved short-open result above; the broader capacity and
native Linux limitations still apply.
