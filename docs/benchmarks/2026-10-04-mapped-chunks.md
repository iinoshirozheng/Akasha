# Mapped F32 two-chunk distance probe

**Not adopted. M5/M6 remain incomplete.** Loading two adjacent SIMD blocks per
checked mapped read reduces loop instructions, but the 1536-dimensional timings
are mixed. This free-function probe does not establish a public-query benefit or
Qdrant parity. Production source and all production binaries remain unchanged.

The candidate copies the existing four-row F32 scorer and adds a two-block loop
using `MappedFile.load_scalars[float32, 2 * width]`, followed by explicit
`SIMD.slice[width]()` calls. Each accumulator receives the same operations in the
same order, with the original reduction, remainder and `finish_distance`.
Dimension, slot, open-mapping and per-chunk byte bounds remain checked; it exposes
no raw span and adds no ownership/cache abstraction. Both A/B paths have the same
non-inlined diagnostic wrapper. This is distinct from the rejected full-row
bounds-hoisting prototype: the new loop still checks each copied chunk.

## Validation and all measurements

Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4. Three metric tests pass (Dot, L2,
Cosine), each covering 24 dimensions from 1 to 1537, including SIMD/tail boundaries,
repeated/noncontiguous/final slots, score bits, invalid dimensions/slots, closed
mapping, and insufficient mapped bytes. These are **three tests**, not 72 tests.
TestSuite reports 22.738 **milliseconds**, separate from compilation time.

The first compile failed because Mojo 1.0 could not prove the symbolic half-width
from `split()` equals `width`. Explicit `slice[width]()` compiled; the failed source
and log remain in the archive. The API was checked against the
[pinned official SIMD source](https://raw.githubusercontent.com/modular/modular/mojo/v1.0.0/mojo/stdlib/std/builtin/simd.mojo).

Each original corpus uses 67 prepared queries and all 8192 mapped slots in a fixed
permutation. Before timing, all 548,864 individual score bits match per corpus:
**1,646,592 comparisons** total. Seven alternating A/B passes yield **42 samples**;
each worker exits successfully and paired checksums agree. Timings include the
wrapper, slot generation and checksum accumulation, and exclude bit verification.
They are kernel diagnostics, with no recall, public-query or service gate.

Each entry below is **before → candidate milliseconds (candidate/before ratio)**.
Ratios below one are faster. Every sample, including the regressions, is retained.

| Trial | uniform-128 Dot | uniform-1536 Dot | real-1536 Cosine |
| --- | --- | --- | --- |
| 0 | 5.381 → 5.146 (.9563) | 68.947 → 68.105 (.9878) | 67.496 → 68.410 (1.0135) |
| 1 | 5.327 → 5.089 (.9553) | 70.492 → 67.398 (.9561) | 70.604 → 72.682 (1.0294) |
| 2 | 5.455 → 5.127 (.9399) | 77.178 → 72.813 (.9434) | 69.146 → 71.889 (1.0397) |
| 3 | 5.355 → 5.122 (.9565) | 68.947 → 68.519 (.9938) | 72.109 → 70.340 (.9755) |
| 4 | 5.650 → 5.164 (.9140) | 68.252 → 71.283 (1.0444) | 69.811 → 67.426 (.9658) |
| 5 | 5.388 → 5.147 (.9553) | 68.869 → 69.717 (1.0123) | 68.449 → 67.680 (.9888) |
| 6 | 5.402 → 5.050 (.9348) | 68.874 → 67.771 (.9840) | 69.579 → 67.646 (.9722) |

128D improves in all seven passes, but high-dimensional Dot has two slower pairs
and Cosine has three. These observations do not prove a cause for the variation.
There is insufficient evidence here to expand this code into the engine. This
decision is not a new acceptance rule: the user's gate remains each original
matrix cell/trial at matched recall, QPS ≥ Qdrant and p95 ≤ Qdrant.

## Machine code and scope

The compiled cosine width-16 steady loop has 61 instructions / 16 FMLAs per
16 coordinates before, versus 87 instructions / 32 FMLAs per 32 coordinates after.
Neither loop accesses the stack. Candidate wrapper size grows from 2956 to 3660
bytes and saves/restores d8–d15 outside the loop. Instruction counts are not a
speedup estimate. Raw backward-branch detection also includes error/epilogue
branches; only the explicitly identified steady loops are used in this report.

No engine source, Python binding or test suite was changed. No new full Mojo,
Python, crash, C ABI, examples, HTTP, Linux, GPU, ASan or nonresident/memory-limit
run is claimed. The existing production validation and failed gates retain their
documented scope. The original real-data profile motivating this probe was from
the earlier `53f630…` binary; it is not presented as a new production profile.

## Immutable evidence and reproduction

Source HEAD: `ca573de`. Production Python SHA-256:
`609aeb2b0d721cbc1d84f6aec1bd325a360484cfa72d207600313b342c5cd8d9`.
Probe binary SHA-256:
`fe74e4ca7a7407bcc117260396dade7724b34d7bb3ba6919046557eabf193ecb`.

[Frozen text archive](results/2026-10-04-mapped-chunks.json.gz): 150 entries,
357,290 bytes, SHA-256
`244b726338a8ec29c16557fcff8b2a363af980f6df78718188370b1be5b266c9`.
Gzip readback and every embedded text hash were verified. It includes original
source, prototype/test, first failed compile, successful commands/logs, all raw
timings, input/database hashes, disassembly, and the analysis/freezing drivers.
Binary/database/query payloads are represented by hashes rather than embedded.

Local evidence lives in `.build/2026-10-04-mapped-chunks`. Read-only inputs can be
reassessed (writing only derived `summary.json`) with:

```sh
rtk proxy python3 .build/2026-10-04-mapped-chunks/summarize.py
```

For new timing, recover the archived source and drivers into a fresh directory,
retain the pinned corpora/query files/compiler wrapper, then run `validate-slice.py`
and `measure.py` serially. Inspect paths first; do not overwrite this experiment.
The original `validate-build.py` and `first-probe.mojo` document the failed attempt.
