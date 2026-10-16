# Frozen HNSW v3 writer fixtures

These 22 files were emitted by the owned encoder at `d06c812`, before the
streamed writer change. `manifest.json` records that encoder's SHA-256 and every
fixture's SHA-256. Do not regenerate them with the implementation under test.

Names encode metric (0 Dot, 1 L2, 2 cosine), scalar (0 F32, 1 BF16, 2 F16,
3 I8), and population (0 empty, 1 populated with deletion and replacement).
L2/I8 is unsupported and intentionally absent. The graph recipe is in
`tests/mojo/test_hnsw_snapshot_stream.mojo`; the original capture driver is also
retained with the streamed-writer benchmark evidence. Tests compare owned,
sidecar and nested overlay output against these bytes, then exercise larger
chunk boundaries separately.
