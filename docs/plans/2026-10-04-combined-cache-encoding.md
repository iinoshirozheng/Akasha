# Encode payload once for the source fingerprint and metadata cache

Baseline `df61cf6`, engine `8ba04ce`, Python kernel `3ec07dc3…`; Mojo 1.0.0
(`ed45d567`), Apple M4 / Metal:4. The latest original high-dimensional durable
write+flush cells all fail. Existing mixed profiles identify foreground CPU in
authority fingerprinting and payload/cache encoding, not only fsync.

`_publish_index_caches_best_effort` currently serializes every authoritative
payload for its checksum, then serializes the same stable metadata slots again
for the cache. Generate both from one authority walk. Each row still calls the
existing validating payload encoder once; stream exactly the original bytes into
the original CRC and metadata framing. Share the existing metadata row framing
between its current encoder and the new cache factory. Keep the checksum-only
entry point for recovery and preserve its frozen CRC fixtures.

Use the existing CacheArtifact to return the checksum/payload together. No new
runtime configuration, persistent state, cache kind/version, authority schema,
scratch reuse, durability ordering or package is introduced. Named point-store
publication retains its existing path. Source memtable tombstones already carry
empty fields; the metadata index has the same stable ordinal/ID/live layout.

First verify independent frozen bytes/CRC, all field types and signed zero,
updates/deletes/reinsertion, sparse-only changes, bounds and retry. Compare with
the existing metadata encoder and standalone fingerprint through mutation streams.
Then run relevant persistence/metadata/compaction tests and crash boundaries.
Build only copied binding/source; benchmark serially on the original fixed
warm/mixed matrices, with every trial and failed sample retained. Compare complete
published metadata cache bytes and reopened query/oracle/lease results as well as
timings. Broaden Python/C/examples validation if adoption is justified.

This removes a second encoding pass, unlike the rejected payload scratch reuse
prototype. It does not relax per-cell Recall@10 ≥ .95, QPS ≥ Qdrant and p95 ≤
Qdrant, or treat any local gain as M5/M6 completion. Freeze the isolated experiment
under `.build/2026-10-04-combined-cache-encoding`; do not overwrite earlier evidence.
