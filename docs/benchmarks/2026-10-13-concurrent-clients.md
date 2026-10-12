# Concurrent external clients: quality passed, speed failed

The first concurrent-client matrix uses one shared engine handle behind the
same minimal loopback HTTP shim for Akasha and pinned Qdrant Edge 0.8.0.
**Both configurations fail the strict speed matrix:** the one-client control
passes 21/36 cells and four clients pass 14/36. All 72 paired quality cells pass
Recall@10 ≥ .95. Each speed cell still requires QPS ≥ Qdrant and p95 ≤ Qdrant,
without tolerance or compensation from other cells.

This is a distinct service boundary. It is neither the previous binding-only
matrix nor a comparison of the products' HTTP servers. Do not merge its counts
with those matrices or attribute an overhead-diluted ratio to an engine change.
Akasha uses the fresh maintenance-fixed extension; no performance prototype
was adopted.

## Method

Use the same three 8,192-point workloads, checksums, cloned databases, K=10,
post-replacement/delete state and frozen warm ef values as the
[resumed baseline](2026-10-12-mapped-probes.md). Run three alternating engine
pairs per corpus, separately for one and four clients: 36 serial workers,
without overlapping builds, tests or archive compression. The original corpus
specification retains its `query_concurrency: 1`; each report's top-level
`clients` field records the actual external-client count.

Each client is a separate spawned process with one persistent TCP connection.
It warms the connection before a barrier, then submits its disjoint share of
the 64 measured queries per filter for eight passes. Client clocks include
queueing, server JSON parsing and public request conversion, search, response
serialization and client JSON decoding. Input JSON is prepared before timing.
Throughput is total completions divided by the interval from the first request
start to the last response completion, including idle gaps. It is not the
reciprocal mean latency. External processes ensure GIL waiting is visible.

Serial preflight checks all 67 queries per mode against the independent exact
oracle and records approximate recall and execution statistics. Every timed
response must match its preflight IDs and Float32 score bits. Shared
`last_search_stats` is not read during concurrent requests because it cannot
attribute statistics safely to an individual request. Qdrant's public API
does not expose equivalent fallback counters.

All **9,648 exact preflight checks** and **73,728 timed response checks** passed.
Repeated passes add latency observations, not independent recall samples.
The controlled fault test also confirms that a server failure is reported and
client processes are reaped. All 19 relevant Python benchmark/adapter tests
passed with the fresh Akasha and pinned Qdrant packages.

## Four-client results

Ratios below are medians of the three retained Akasha/Qdrant pairs. Pass counts
apply to individual pairs, not the medians.

| Corpus | Filter | QPS ratio | p95 ratio | Passed pairs |
|---|---|---:|---:|---:|
| uniform-128 | all | .878 | 1.147 | 0/3 |
| uniform-128 | correlated | 1.785 | .556 | 3/3 |
| uniform-128 | independent | 1.860 | .566 | 3/3 |
| uniform-128 | selective | 1.062 | .851 | 2/3 |
| uniform-1536 | all | 2.052 | .493 | 3/3 |
| uniform-1536 | correlated | 1.225 | .855 | 2/3 |
| uniform-1536 | independent | .983 | 1.034 | 1/3 |
| uniform-1536 | selective | .626 | 1.641 | 0/3 |
| real-1536 | all | .897 | 1.136 | 0/3 |
| real-1536 | correlated | .800 | 1.349 | 0/3 |
| real-1536 | independent | .734 | 1.488 | 0/3 |
| real-1536 | selective | .939 | 1.074 | 0/3 |

All real-data four-client cells fail speed acceptance. Uniform-1536 also has
slow correlated/independent trials and a consistent selective deficit. All
trials remain in the artifact, including the large slow samples.

The smoke run initially used naive recall addition, which represented exactly
.95 as `.9499999999999995`. The formal run uses `statistics.mean`, matching the
existing binding benchmark, with no epsilon or relaxed threshold. Both smoke
and formal sources/results are retained. An initial test of an unserved socket
hit the timeout before its connection error could be reported; the deterministic
server-error test replaces it. The original failed test log remains available.

## Reproduction and limits

The tracked worker is `benchmarks/qdrant_concurrent.py`; the artifact includes
the matrix driver, exact jobs, source and binary hashes, raw per-request
timestamps, all preflight audits, smoke results, test logs and process exits.
An individual job runs as:

```bash
pixi run env PYTHONPATH=<fresh-package>:.:.build/qdrant-compare/deps \
  python -m benchmarks.qdrant_concurrent <job.json>
```

The Apple M4 Pro host still has other applications and swap in use; host
observations are included. There is no imposed memory cap or sustained
nonresident claim. Those regimes and the failed speed cells remain open.

[Complete artifact](results/2026-10-13-concurrent-clients.json.gz), SHA-256
`c8c6f2afafd8cd4162bfec13ddc7c00921f78365b6d7e8d64234a99802cd42bd`.
