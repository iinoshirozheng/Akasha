# HNSW owned decoding without a complete temporary vector tape

Baseline is `72d3c8a`. The owned snapshot reader previously decoded a complete
F32 vector tape, then copied each row into a growing graph tape. Compact F16/BF16
snapshots also temporarily promoted their complete vector section to F32.
The retained reader validates one row and appends it directly to preallocated
final graph storage. I8 retains bounded encoded codes until the later scale
section has been validated, then restores each row once. Lifecycle flags are
restored in slot order; entry, edge, checksum and format validation still finish
before the local graph can be returned. No format, API or search contract changes.

## Source evidence

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d` separates vector
storage from graph links. Its `lib/segment/src/vector_storage/chunked_vectors/`
`write_ops.rs:70–98` writes supplied typed rows into their destination chunk;
`read_only/read_ops.rs:88–117` accesses a bounded vector range through the backing
storage. This is a storage-ownership pattern applied to Akasha's existing owned
decoder, not a verbatim port or a claim that point authority is now mapped.

## Attribution and regression test

The old description “before first flush” was too coarse to identify the failing
allocation. On current baseline uniform-1536, the 128 MiB worker reaches
`after_query` in block 0 and is OOM-killed before its first write marker. Real-1536
acknowledges eight rows and is killed during its first flush. Both have already
consumed most of the cap after open. The input databases and JSONL streams match
all original recorded hashes; collection identity and point segments are already
v2/v5, so this is not a first-flush format migration.

One separate, unconstrained diagnostic clone records process anonymous memory:

| Phase, uniform-1536 | Anonymous KiB |
| --- | ---: |
| Before PointStore.open | 34,172 |
| After point recovery | 99,960 |
| After PointStore.open | 102,040 |
| After read projection | 104,088 |
| After metadata | 114,528 |
| After HNSW recovery | 131,140 |

These are phase measurements under x86-64 emulation, not exact allocator ownership
or native Linux performance. Point recovery remains the largest increase.
Source inspection also confirms that point segment records still materialize
owned vector values. Removing the HNSW intermediate tape addresses one measured
contributor without claiming to solve that broader ownership issue.

The new regression builds a valid directed graph with a 64 MiB F32 tape, encodes
it into an exactly sized buffer, keeps the original graph alive and measures
additional process peak RSS while decoding. The unchanged 96 MiB ceiling permits
one final tape and graph metadata but rejects another complete temporary tape.

| Platform | Baseline growth bytes | Retained growth bytes |
| --- | ---: | ---: |
| macOS ARM64 | 122,814,464 | 67,584,000 |
| Linux x86-64 emulated | 136,331,264 | 67,117,056 |

Both baselines fail the same assertion; both retained readers pass and reproduce
all vector values and graph counts. An earlier test setup used the bounded file
reader to obtain the encoded bytes; its prior allocation high-water mark masked
the regression (baseline growth 36,880,384 bytes). That ineffective setup is
recorded and replaced with the exact-size encoder before accepting the test.

## Workload and recovery checks

All workers use the original frozen 32-block mixed plans, ef, query vectors,
filters, write batches and recall thresholds. Fresh volume inodes are prepared
in a separate 6 GiB container, fsynced and evicted with FADV_DONTNEED; preparation
and execution both verify zero initial `.bin` residency. Workers use one CPU,
no swap, the pinned image and compiler, and run sequentially without concurrent
build/test workloads. These are single-pass cgroup diagnostics, not repeated
performance or sustained-duration acceptance.

- Retained 6 GiB controls pass all three corpora. Uniform-128 also passes 128 MiB;
  both high-dimensional corpora pass 192 and 256 MiB.
- **Both high-dimensional 128 MiB cells still fail.** Uniform-1536 now completes
  two flushes and acknowledges 24 rows before OOM during block 2 flush.
  Real-1536 still fails during block 0 flush after acknowledging eight rows.
- Across all 12 completed workers, including controls and the diagnostic clone,
  3,456 query responses match baseline IDs, F32 score bits, oracle recall and
  execution stats. All 12 exact reopens agree; minimum mode recall is 0.956944.
- Unconstrained recovery of all four OOM volumes verifies all 40 acknowledged
  rows' F32 bits and full payloads, plus each next-state exact oracle. The
  zero-acknowledgement baseline still verifies its unchanged exact oracle.
- 40 native Mojo cases pass, covering owned/mapped readers, v1/v2/v3 fixtures,
  compact scalars, lifecycle flags, corruption, overlay recovery/publication,
  checkpoint cleanup and the new memory regression. Linux also passes the new
  regression, after reproducing its failure on baseline. Existing unrelated
  full-suite results are not represented as fresh validation.

Uninstrumented Linux Python SHA-256:

- Baseline: `4a9876334e9334e7278764fe8b9ee929927b6c2ea2d616771bd537eeeace4531`.
- Retained: `b66d0ea2a9921db1f7b538c1b2920250a0411740dc9130af39dca4c4ba93295d`.

The final source only clarifies the decoder's v3-support docstring after these
builds; executable source is unchanged. No formal Qdrant gate is closed. The last
formal checkpoint remains `45e04d2`; low-dimensional tails, full type/lifecycle
coverage, sustained capacity, concurrency scaling and native Linux performance
remain open. Next memory work must address point-value ownership and remaining
cache input allocations rather than treating this decoder fix as a capacity pass.

## Evidence

[Complete evidence archive](results/2026-10-19-hnsw-decode-memory.json.gz):
184 text artifacts, 697,294 bytes, SHA-256
`f6613fa2df8a99476dcb1cec210b6a86dc620adc3649a08ce2d34435b756fe0f`.
It retains source/binary/input identities, before/after source, instrumentation,
measurement drivers, all failed and successful workers, recovery audits and
validation logs. Original immutable database hashes are retained in the inventory.
