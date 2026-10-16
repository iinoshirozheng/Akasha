# Current concurrent clients: quality passes, speed remains open

This rerun measures commit `63794d662c0538d9a9a5d66dd4a2552213bbdb25` through the
same loopback HTTP shim and pinned Qdrant Edge 0.8.0 used in the
[original concurrent-client matrix](2026-10-13-concurrent-clients.md).
All **72/72 quality cells pass**. Strict speed parity passes **6/36 cells with
one client** and **12/36 with four clients**. Every cell still requires both
wall QPS ≥ Qdrant and p95 ≤ Qdrant at Recall@10 ≥ .95, without tolerance.

## Inputs and boundary

Each engine reopens a clone of the corresponding corpus/trial database from
[the bounded-bitmap fresh acceptance](2026-10-16-bitmap-bounded-read.md).
The three corpora have 8,192 points, Dot F32, K=10, four filter modes, and
64 measured queries per mode. Each engine uses its own smallest warm
recall-passing ef from that trial; ef is frozen before concurrent timing.
Three alternating engine pairs run separately for one and four external
process clients. Eight passes per client partition add timing observations,
not independent recall samples. Jobs run serially, without overlapping builds,
other benchmarks, or compression. The worker is unchanged.

All **36 workers finish successfully**, all **9,648 exact preflight audits**
pass, and all **73,728 timed responses** match serial preflight IDs and F32
score bits. The driver exits 1 because speed acceptance fails, not because
a worker fails. Shared last-search statistics are read only during serial
preflight. Both libraries keep one shared handle behind the same HTTP shim;
this is neither a binding-only result nor a product HTTP-server comparison.

## Ratios

Medians of three retained pairs; pass counts use individual unrounded ratios.
Each entry is QPS / p95, Akasha divided by Qdrant.

| Corpus | Filter | 1 client | Pass | 4 clients | Pass |
|---|---|---:|---:|---:|---:|
| uniform-128 | all | 0.643 / 1.497 | 0/3 | 0.658 / 1.749 | 0/3 |
| uniform-128 | correlated | 0.622 / 1.586 | 0/3 | 0.678 / 1.683 | 0/3 |
| uniform-128 | independent | 0.621 / 1.865 | 0/3 | 0.636 / 1.649 | 0/3 |
| uniform-128 | selective | 1.079 / 0.930 | 2/3 | 1.128 / 0.852 | 3/3 |
| uniform-1536 | all | 1.003 / 0.996 | 2/3 | 1.047 / 0.971 | 3/3 |
| uniform-1536 | correlated | 0.739 / 1.260 | 0/3 | 0.718 / 1.421 | 0/3 |
| uniform-1536 | independent | 0.795 / 1.160 | 0/3 | 0.775 / 1.466 | 0/3 |
| uniform-1536 | selective | 0.989 / 1.047 | 0/3 | 1.062 / 0.992 | 2/3 |
| real-1536 | all | 0.954 / 1.079 | 0/3 | 0.985 / 1.026 | 1/3 |
| real-1536 | correlated | 0.615 / 1.561 | 0/3 | 0.601 / 1.806 | 0/3 |
| real-1536 | independent | 0.828 / 1.196 | 0/3 | 0.850 / 1.240 | 0/3 |
| real-1536 | selective | 1.013 / 0.967 | 2/3 | 1.054 / 0.958 | 3/3 |

## Source findings and limits

Akasha’s six legacy ANN entry points hold `_writer_lock` across traversal.
`SegmentedHnsw` and its graph query paths update shared scratch and last-search
statistics. Removing the lock alone would violate the ownership assumptions
exercised by `tests/mojo/test_concurrency.mojo`. Exact snapshot operations
already acquire an owned immutable read root and can finish after close.

The pinned Qdrant Python `PyEdgeShard::query` and `search` directly call the
native shard with no `allow_threads`/`detach` section. Akasha’s Python entry
points also contain no GIL-release section. The Rust shard exposes shared
read handles and a search pool internally, but that does not establish
parallel execution of these external Python requests. Increasing clients
from one to four changes within-engine wall QPS by a median **1.135× for
Akasha** and **1.094× for Qdrant** across the 36 corresponding cells.
These observations do not isolate the GIL or writer lock as the cause of the
between-engine gap. A concurrency change needs operation-owned graph state
and safe Python object/lifecycle boundaries, not an unguarded lock removal.

The previous 21/36 and 14/36 speed counts used different binaries, graphs,
planner behavior and frozen ef values. They are historical snapshots, not
a paired regression baseline. This matrix predates the separate source-map
single-probe experiment; it must not be attributed to that candidate.

Low-dimensional and real-data filtered ANN still fail every speed cell.
Linux, sustained nonresident/memory-limited execution, capacity/type matrices
and full M5/M6 acceptance remain open. The host is macOS on Apple M4 Pro;
no CPU affinity or global isolation from desktop applications is claimed.

## Reproduction and identity

Run an archived job with:

```bash
pixi run env PYTHONPATH=python:.:/Users/ray/Projects/Akasha/.build/qdrant-compare/deps \
  python -m benchmarks.qdrant_concurrent <job.json>
```

Akasha native SHA-256:
`df71664362253188ef32828dc9d28f315a97eee2a82d76fe0fca43c0396839bb`.
Qdrant revision: `21db2f3ff95d50de3a2b88a741312c056fd1762d`.
The artifact retains jobs, complete raw reports, process exits, driver/worker
sources, host observations, source excerpts, and input identities. Database
files and native binaries are identified by hashes rather than embedded.

[Complete artifact](results/2026-10-16-concurrent-current.json.gz), 166 files,
SHA-256 `431aaa05372c567f4b6d2b96e72e501c672b2324a239690f071942b085ac1b34`.
