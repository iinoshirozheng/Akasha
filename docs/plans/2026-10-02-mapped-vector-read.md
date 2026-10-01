# Mapped F32 validation reads

**Disposition: adopted.** All nine cached-open pairs improved, with identical
public results; high-dimensional paired median improvements are 16–17%.
Full integration passed 954 Mojo, 23 crash and 317 Python tests, the rebuilt
C ABI client and three rebuilt examples. See the
[measurement and retained logs](../benchmarks/2026-10-02-mapped-vector-read.md).

The current cached-open phase probe attributes about 98/106 ms to base graph
structure validation on the uniform/real 1536D corpora. The new owned F32 reader
has reduced total opens to about 253/269 ms, making this an appreciable remaining
cost. An earlier isolated row-load probe was inconclusive while delta rebuild
dominated opens; measure again against the current production baseline.

Reuse `MappedFile.load_scalars`, already used by mapped graph distance kernels.
For F32 structural validation, copy SIMD-sized chunks and a scalar tail into the
same owned prepared vector, then call the unchanged metric validator. Keep all
node, vector, count, edge, checksum, identity and owner checks. No mapped pointer
or span escapes. `MappedFile.open_readonly` already rejects big-endian builds,
so native-endian loads retain the little-endian format interpretation. Other
scalar representations are unchanged. No new dependency or durable format.

Check owned/mapped vector bits and scores across dimensions 1/3/15/16/17/31/32/33/
1536/1537 and all three F32 metrics. Resign checksums on nonfinite/unsafe vectors,
zero/nonunit cosine rows and malformed tapes so vector/layout rejection remains
covered independently of checksum rejection. Check inactive rows and closed
owners. Run existing mapped, quantized and snapshot compatibility tests.

Build the isolated binding from its **copied entry file**, record binary hashes,
and compare three alternating fresh-process cached-open pairs per corpus. Use
identical closed data, exact independent oracle checks and identical approximate
IDs/scores. OS cache is present; this is not a non-resident gate. Builds, tests and
archive compression must not overlap benchmarks. Adopt only with evidence of
useful improvement, then run affected persistence/crash and Python/C integration.
