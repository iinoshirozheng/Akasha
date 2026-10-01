# Reuse checked adjacency ranges during HNSW validation

Full mapped validation and the shared bidirectional audit previously located
the same node/level metadata again for each neighbor. They now use the existing
`neighbor_range` once per level and `neighbor_at_offset` for each occupied edge.
The latter still checks each mapping owner and read bound. This changes two
production files and introduces no new access interface, dependency or format.

Node flags, packed offsets, counts, vector values/norms, current IDs, entry point,
self/duplicate edges, target levels and exact bidirectional comparison remain
checked. Owned graphs use the same audited range interface. Validation statistics
and reserved edge-tape capacity matched in all native pairs.

Three alternating before/after pairs per corpus each run eight complete mapped
structure validations, retaining pass zero as warmup. Median validation times:

| Corpus | Before ms | After ms | Median paired after/before |
|---|---:|---:|---:|
| Uniform 128D | 48.348 | 40.720 | .842 |
| Uniform 1536D | 56.700 | 48.959 | .864 |
| Real 1536D | 66.734 | 59.130 | .887 |

The actual public Python reopen was then measured from identical closed,
cache-populated database copies. The baseline is the saved validated package
from before the [rejected dictionary probes](2026-10-02-hnsw-lookup-probes.md);
all those production changes had been reverted. Production source bytes match
the measured range prototype exactly. Each of the 18 worker processes checks
its loaded native binary hash.

| Corpus | Before median ms | After median ms | Paired ratio median (full range) |
|---|---:|---:|---:|
| Uniform 128D | 107.762 | 97.940 | .907 (.906–.917) |
| Uniform 1536D | 216.258 | 208.986 | .957 (.955–.966) |
| Real 1536D | 227.871 | 217.844 | .968 (.950–.969) |

All **576 exact oracle checks** pass. The **576 approximate result lists**, IDs
and scores match between versions. Graph and overlay data are unchanged. Trials
are serial and alternate order; no build, test or compression overlaps timing.
OS cache remains present, with no enforced memory limit or eviction. These are
cached reopen results, not cold/non-resident or query/write performance claims.

Validation passed **108 Mojo tests in 11 affected files, 9 crash tests in two
files, all 339 Python tests**, and the rebuilt C ABI client. The cases include
checksum-resigned bad vectors, corrupt counts/offsets/edges, closed mappings,
owned/mapped metric equivalence, frozen compatibility fixtures, retained-base
recovery, overlay caches and checkpoint publication. Previous unchanged full
CPU/example gates are retained; no new GPU or network gate is claimed.

Commands and outputs, both native and public raw results, source snapshots and
the exact patch are in the [evidence archive](results/2026-10-02-hnsw-validation-ranges.json.gz)
(411,974 bytes; SHA-256
`bc6340d0ba20d415b31e66c43b65ddcc324e00de29be6b1aec535f5d231ef052`).
Qdrant parity and the remaining M5/M6 delivery gates remain open.
