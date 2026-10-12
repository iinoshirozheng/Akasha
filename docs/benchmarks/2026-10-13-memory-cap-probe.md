# Memory-cap diagnostic: open-time OOM and different residency states

The first controlled memory experiment uses the fixed real-1536 workload on
**emulated Linux x86-64**. Akasha completes at 256 MiB, but is OOM-killed during
open at 224, 192 and 128 MiB. Qdrant completes at all four caps. This is a
capacity diagnostic, not a completed three-corpus matrix or native Linux
performance acceptance.

Both engines use one CPU and no swap, separate serial containers, the same
8,192-point data, K=10 and frozen ef values. Akasha is the maintenance-fixed
production binary. Qdrant is the official pinned 0.8.0 Linux wheel, SHA-256
`65bae2a2f028d536706d9e2c24037344154864f84e22aba244f12648b072fb83`;
its previously skipped Linux adapter test now passes.

For this regime, Qdrant vectors are changed to `on_disk=True` using the public
`EdgeShard.load(config=…)`, `optimize`, `flush` and `close` APIs on a clone.
Payload and indexing settings remain as recorded in the resident baseline.
The saved config and resulting files are included. The original resident
database is retained, and these results are not merged with that configuration.

Each worker creates fresh database inodes on a Docker Linux volume. It fsyncs
and requests `POSIX_FADV_DONTNEED` once before opening; vector-file `mincore`
then confirms 0% initial residency. Database pages are not measured through a
Mac bind mount and do not reuse another container's file-cache charges.
No eviction is requested during queries. Code and reports use the bind mount.
The worker loads only query vectors, deduplicated allowed-ID sets and the
oracle, not the original NumPy corpus matrix.

The 6 GiB controls pass quality for both engines. At the last measurement,
Akasha has about 179 MiB anonymous memory and 161 MiB file cache charged to its
cgroup; Qdrant has about 66 MiB anonymous memory and 270 MiB file cache. These
are process/cgroup observations, not just engine allocations. The controls use
four passes per filter; the cap diagnostics use eight. Each pass repeats the
same 64 measured queries and adds no independent recall observations.

| Common cap | Akasha | Qdrant | Residency observation |
|---|---|---|---|
| 256 MiB | Completes; all quality cells pass | Completes; all quality cells pass | Akasha vector file stays 100% resident; Qdrant has sustained faults and 3–7% vector-file residency late in the run |
| 192 MiB | Open-time OOM | Completes; all quality cells pass | Qdrant ends with roughly 96% vector-file residency, despite continuing faults |
| 128 MiB | Open-time OOM | Completes; all quality cells pass | Qdrant initially sustains low residency, then becomes mostly resident in later filters |
| 224 MiB follow-up | Open-time OOM | Completes; all quality cells pass | Qdrant vector file is almost fully resident |

The follow-up 224 MiB cap probes the interval between Akasha's resident success
and open-time OOM. It was selected from memory behavior, without changing ef,
queries or recall. Docker confirms `OOMKilled=true` for all three Akasha
failures. Partial reports still say `initializing` because SIGKILL cannot run
the Python cleanup handler; container state is the authoritative outcome.

Before running the first sweep, the diagnostic defined sustained-pressure
evidence as major faults in every final-four pass and vector-file residency
below 95% at every corresponding boundary. Qdrant satisfies it for all four
256 MiB filters and the first two 128 MiB filters. Other cells do not. Faults
are process-wide, not attributed to individual files; the residency samples
are per vector file. Akasha's planned exact scans use owned record vectors,
so an evicted HNSW sidecar alone would not prove nonresident exact inputs.

The curve is nonmonotonic: Qdrant's 256 MiB trial is much slower than its
192 MiB trial. All samples, cgroup counters and faults are retained. Single
diagnostic trials, different residency states and emulation do not support a
general speed claim. The full repeated matrix and sustained nonresident
Akasha execution remain open.

An initial direct-launch attempt omitted Pixi's runtime environment and
aborted while locating the Python shared library. Its process required a
bounded container stop. The corrected workers supply the activation PATH and
`MODULAR_HOME`; both controls then succeed. The abort, missing-pip attempt and
early wheel-install attempt are retained separately from measured trials.

The next investigation is Akasha recovery peak memory. The current legacy
segment reader owns the complete encoded file while allocating decoded
vectors. This overlap is a candidate cause of the open-time limit, not yet a
proven sole cause or an adopted optimization.

[Commands, frozen query input, oracle, preflight results/timings, cgroup state,
container outcomes and identities](results/2026-10-13-memory-cap-probe.json.gz).
SHA-256: `b0aeb7b4ee4e993767c31ec54e88781ed6073efa8ad46934630fcce880162e7b`.
