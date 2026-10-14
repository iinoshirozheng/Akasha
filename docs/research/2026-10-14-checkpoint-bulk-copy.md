# Composition of snapshot-row and payload-byte copies

The two independently tested changes compose without byte or query differences.
All nine flush pairs improve QPS **10.9–18.5%** and p95. The composition remains
isolated: one mixed selective cell changes pass→fail, and combined write+flush
still passes only 3/9. Production and all M5/M6 requirements remain unchanged.

The source is exactly the union of the
[F32 validation row copy](2026-10-14-hnsw-validation-row-copy.md) and
[payload byte-span encoder](2026-10-14-payload-span-encoding.md): three changed
files, no new logic, dependencies, retained memory, format or durability changes.
Each source file is verified against its frozen single-change parent. Standalone
codec/WAL/segment/migration and scalar validation evidence remains applicable and
is referenced by verified archive hashes rather than rerun indiscriminately.

Fresh joint validation passes **49 Mojo cases in eight files**, including the
nine inherited new cases, writer checksum, HNSW store/v1 fixtures, overlay and
persisted caches; **13 crash-state cases in two files** cover legacy and HNSW
checkpoint ordering. **369 Python cases** pass without skips, with three existing
warnings. Mojo 1.0.0 compiles the shared library without warnings. This is not
the full crash-kill or standard CPU suite.

All **54 serial native workers** complete with unchanged plans, ef values,
filters, corpora, oracles and rotating triple order. Warm takes 47.82 s and mixed
69.67 s. Mixed returns the expected strict-gate failure after all nine triples.
IDs, Float32 bits, stats and execution decisions match; all lease/reopen checks
pass. Quality is 36/36 for each version in both phases.

| Phase | Strict speed before → after | Pass → fail | Fail → pass |
| --- | ---: | ---: | ---: |
| Warm queries | 23 → 26 / 36 | 0 | 3 |
| Mixed queries | 20 → 24 / 36 | 1 | 5 |
| Mixed write+flush | 3 → 3 / 9 | 0 | 0 |

The remaining new pass→fail is **mixed real-1536 selective, trial 1**. It remains
in the raw report and is not offset by improvements or retroactively assigned
the cause observed in separate lock diagnostics.

Flush QPS after/before by trial:

| Corpus | Trial 0 | Trial 1 | Trial 2 |
| --- | ---: | ---: | ---: |
| Uniform 128 | 1.1090 | 1.1289 | 1.1133 |
| Uniform 1536 | 1.1414 | 1.1439 | 1.1846 |
| Real 1536 | 1.1815 | 1.1713 | 1.1521 |

High-dimensional flush medians fall by about 3.9–5.0 ms. Combined write+flush QPS
improves in all nine pairs, 6.8–11.5%, but the high-dimensional Qdrant gate remains
unmet. Uniform-1536 trial-2 combined p95 worsens by 1.8%; it is retained alongside
the other eight improved p95 pairs. Individual update calls are not treated as
durability-equivalent; the combined gate is unchanged.

Post-timing inspection again finds **18 byte-identical overlay/metadata payload
pairs**, valid envelope CRCs and valid inner snapshot CRCs. All full-file/payload
hashes, generations and sequences remain available. No checksum residue is used
as a substitute for comparing bytes.

The [archive](2026-10-14-checkpoint-bulk-copy.json.gz) contains **784 files,
3,891,858 bytes**: full source, tests, build identities, all raw workers and
failures, byte audit and verified references to both parent archives and the
original plans. Every embedded hash is verified. Root production source and
Python binary remain unchanged.

- Candidate Python SHA-256: `c2fb53975e0c020b2fae80c2636bd890ecaf0e50268187168513de603ab09d15`.
- Archive SHA-256: `b7076f497c619f6a090be84dfc50006b41377b2f234be68a40879ca7a11de372`.

Next test an explicit separation of live-query exclusion from durable writer
publication, motivated by the [measured compaction lock waits](2026-10-14-mixed-query-boundaries.md).
Approximate queries must still serialize graph scratch/statistics and all live
mutations, close and rebuild exchanges. Durable writes, snapshots, pins and
manifest transitions retain writer exclusion. Establish lock order and test
concurrent progress/atomicity before a fixed matrix; do not just remove a lock.
No fresh Linux, capacity/nonresident, C ABI or GPU gate is claimed here.
