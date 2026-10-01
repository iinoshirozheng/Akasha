# Retained HNSW base: 1536D paired diagnostic

The updated checkpoint keeps an immutable HNSW base through small updates and
reconstructs its bounded delta from recovered authority. One fresh paired trial
uses the exact same workload checksum as the earlier 1536D uniform baseline:
8,192 points, 819 replacements, 205 deletes, dot/F32, M=24/M0=48,
efConstruction=192, seed 12345, 64 measured queries per cell after three warmups.

Command:

```sh
pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps python benchmarks/qdrant_compare.py --output .build/qdrant-compare/hnsw-v5-1536 --dimension 1536 --trials 1
```

Fresh-process Akasha open took **3.859 s**, compared with **75.367–76.231 s** in
the prior three trials (19.5–19.8× faster). Initial ingest/build remained 78.077 s;
first checkpoint took 0.613 s and the post-mutation flush 0.137 s. The improvement
does not move a full rebuild into flush. The reopened first query had Recall@10
1.0, used ANN without fallback, and returned candidates from the retained base
and its 819-point delta. Qdrant's fresh-process open in this trial took 0.112 s.
OS page caches were **not** evicted; this is process-cold, not non-resident I/O.

| Filter | Akasha ef / recall | Qdrant ef / recall | Akasha/Qdrant QPS |
| --- | --- | --- | ---: |
| All | 512 / 0.993750 | 512 / 0.993750 | 0.360 |
| Correlated | 512 / 0.985938 | 512 / 0.978125 | 0.149 |
| Independent | 512 / 0.982813 | 512 / 0.979688 | 0.161 |
| Selective | 32 / 1.000000 | 32 / 1.000000 | 0.303 |

All four matched-recall cells pass 0.95. Warm-query speed remains below Qdrant;
this is **not** M6 parity. Only one new trial was run, so this result establishes
the recovery improvement and preserves the outstanding performance gap rather
than estimating its variance. The interactive host was not CPU-pinned. No other
test/build workload was started while the paired measurement was running.

[Raw results](results/2026-10-01-hnsw-base-reopen.json.gz) retain source and binary
hashes, host/toolchain, configuration, individual samples, oracle checks and both
engines' build/reopen reports. The workload, scoring and measurement boundaries
are unchanged from [the baseline](2026-09-30-qdrant-comparison.md).
