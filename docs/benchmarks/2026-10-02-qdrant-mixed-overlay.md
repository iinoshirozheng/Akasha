# Qdrant mixed comparison after overlay caching

The current production build passes all 5,184 content/recall audits, 36 matched
recall cells and 18 reopened exact oracles in three serial trials per corpus.
All nine Akasha Arrow leases remain valid through maintenance and close, and
release permits reclamation. Qdrant whole-matrix performance parity is still
unmet: real independent filters, uniform high-dimensional selective filters,
high-dimensional durable writes and reopen remain slower.

This reruns `benchmarks/qdrant_mixed.py` with the same fixed workload and pinned
Qdrant Edge package as the [original comparison](2026-10-01-qdrant-mixed.md).
There is one foreground caller, with engine background work enabled. Each trial
interleaves nine reads with an eight-point batch and flush for 32 blocks. Cache
eviction and a resident-memory limit are unavailable; all results are resident
mixed-workload measurements. No tests, builds or archive compression overlapped.

| Corpus | All QPS ratio | Correlated ratio | Independent ratio | Selective ratio |
| --- | ---: | ---: | ---: | ---: |
| Uniform 128D | 2.367 (2.116–3.193) | 4.399 (3.116–4.778) | 4.253 (4.123–5.885) | 2.326 (1.776–3.221) |
| Uniform 1536D | 1.715 (1.665–1.745) | 1.380 (1.323–1.416) | 1.242 (1.201–1.332) | .723 (.717–.810) |
| Real 1536D | 1.154 (1.032–1.173) | 1.016 (.989–1.088) | .606 (.595–.658) | 1.166 (.444–1.308) |

Ratios are Akasha/Qdrant, with the paired median and complete three-trial range.
Both engines exceed mean recall .95 in each matched cell. Real selective trial 2
has an Akasha p99 of 28.681 ms and a QPS ratio .444; it is retained. Qdrant query
times differ substantially from the prior comparison, and some Akasha cells also
slow down. Cross-run ratio changes cannot be attributed to overlay caching, nor
does this mixed workload establish pure warm read-only parity.

| Corpus | Akasha write + flush p95 ms | Qdrant write + flush p95 ms | Akasha reopen ms | Qdrant reopen ms |
| --- | ---: | ---: | ---: | ---: |
| Uniform 128D | 30.833 | 38.021 | 125.576 | 63.391 |
| Uniform 1536D | 78.699 | 35.712 | 352.165 | 58.208 |
| Real 1536D | 71.913 | 38.243 | 370.292 | 68.849 |

These are medians of the three trials. Combined write-plus-flush quantiles use
each block's actual total, not sums of component percentiles. Akasha synchronizes
its WAL at batch commit; Qdrant Edge synchronizes at the following flush. Their
write-only numbers therefore have different durability boundaries. Reopen is much
faster than before caching, but still about 2–6 times Qdrant in these medians.
The [paired Akasha study](2026-10-02-hnsw-overlay-cache.md) isolates the added flush
cost and the recovery benefit.

[All trial samples, execution stats, audits, worker reports and benchmark sources](results/2026-10-02-qdrant-mixed-overlay.json.gz)
have SHA-256 `e17fbea911364ba116cf6b832532d258a12045c84f0e68d7df11ec3263607046`.
The archive references byte-hashed, equality-checked workload plans already saved
in the stream-fingerprint archive and the immutable production source archive.
