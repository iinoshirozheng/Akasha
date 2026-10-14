# Checked F32 snapshot validation row copy

A checked contiguous copy improves all six high-dimensional flush QPS pairs
by **5.6–19.7%**, while retaining the original prepared-vector validator.
The candidate remains isolated: one mixed query cell changes from pass to fail,
and combined write+flush still passes only 3/9. Production is unchanged and
M5/M6 are incomplete.

## Change and validation

Starting from production, only `hnsw_store._copy_graph_vector` changes. For F32,
it checks the slot's complete row range, then extends the existing owned List
from an immediate Span of that row. Compact scalar decoding retains its
existing path. There is no retained view, cache, public API or format change.
Both callers validate graph structure before prepared-vector validation.
Existing List/Span usage and the installed Mojo **1.0.0 (ed45d567)** compiler
establish the API; newer documentation is not treated as version authority.

Four new semantic cases pass on both the unmodified parent and candidate:
exact bits across 14 dimensions and three adjacent rows, independent ownership,
invalid slots, and rejection of invalid inactive prepared rows. Cases include
signed zero, subnormals, extrema, infinities, NaN payloads and cosine zero norm.
These are equivalence tests, not a claimed red-to-green bug fix.

The candidate passes **104 Mojo cases in 11 files**, **9 existing crash-state
cases in two files**, and **369 Python cases** with no skips and three existing
warnings. The crash cases cover checkpoint ordering and base publication using
reconstructed states; they are not the entire process-kill crash suite.
The isolated shared-library build has no warnings. Child compiler routing,
full source inventory and source/binary hashes are retained and verified.

## Fixed native matrix

All **54 serial native workers** complete: three unchanged corpora, three
rotating triples and both warm/mixed phases. IDs, Float32 score bits, stats and
execution decisions match across versions. Arrow lease and exact reopen checks
pass. All fixed quality cells pass; no ef retuning, exclusions or tolerance apply.

| Phase | Quality before → after | Strict speed before → after | Pass → fail | Fail → pass |
| --- | ---: | ---: | ---: | ---: |
| Warm | 36 → 36 / 36 | 22 → 27 / 36 | 0 | 5 |
| Mixed | 36 → 36 / 36 | 20 → 21 / 36 | 1 | 2 |
| Mixed write+flush | — | 3 → 3 / 9 | 0 | 0 |

Warm takes 45.48 s. Mixed takes 70.17 s and returns its expected strict-gate
failure after completing all nine triples. Improvements do not offset failures.
The mixed regression is **uniform-128 selective, trial 2**:

| Version | QPS | p50 µs | p95 µs |
| --- | ---: | ---: | ---: |
| Production | 22,638.8113 | 25.125 | 99.708 |
| Candidate | 21,113.0817 | 25.167 | 274.959 |
| Qdrant | 14,125.1528 | 60.000 | 161.417 |

Both Akasha versions choose planned exact and recall is 1.0. Three of the
candidate's four largest samples are the first query after a write/flush block;
the fourth is the second query. Production has three similarly large samples.
The order-statistic difference explains the reported p95, not its root cause.
It is not grounds to waive the failure or label it proven noise.

Flush QPS after/before by trial:

| Corpus | Trial 0 | Trial 1 | Trial 2 |
| --- | ---: | ---: | ---: |
| Uniform 128 | 1.0143 | 1.0137 | .9992 |
| Uniform 1536 | 1.1015 | 1.1018 | 1.0559 |
| Real 1536 | 1.0971 | 1.1970 | 1.0575 |

Uniform-1536 flush medians fall from 29.316/30.459/29.335 ms to
26.502/27.775/26.846 ms; real-1536 medians fall from 30.283/31.109/30.006 ms to
27.800/27.378/27.879 ms. All six high-dimensional flush p95 values improve.
The real trial-1 production p95 of 52.642 ms versus candidate 28.667 ms remains
in the evidence with no asserted cause. Uniform-1536 trial-2 combined write+flush
p95 increases slightly, **56.045→56.079 ms**; it is not rounded into an improvement.
Individual writes do not represent equivalent durability across engines;
the existing combined write+flush gate remains authoritative.

A post-timing byte audit compares nine pairs each of overlay and metadata cache
payloads. All **18 inner payload pairs are byte-identical**. All envelope CRCs
and inner HNSW snapshot CRCs validate. Full-file and payload SHA-256 identities,
lengths, generation and sequence are retained; equality is not inferred from a
CRC residue.

## Evidence and next investigation

The [archive](2026-10-14-hnsw-validation-row-copy.json.gz) contains **789 files,
3,900,497 bytes**, including complete candidate source, production original,
tests, build records, all raw worker timings, audits and failures. Its plan
references identify the three complete plans in the
[flush diagnostic archive](2026-10-14-legacy-flush-phases.json.gz) by SHA-256;
that archive's hash is also verified. Every embedded file hash is verified.

- Candidate Python SHA-256: `2bec7169004af916c261fefa4f0c480df6204ef7a45a2e92ed3286ff4ddc5598`.
- Production Python SHA-256: `96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c`.
- Archive SHA-256: `82580bffcb55aa041a682bf61a697019d00df334bb89662f7a47c4208f8f9486`.

Retain this candidate while localizing the mixed first-query tail through the
actual read/planning/maintenance paths. Do not assume compaction reconstructs
the full read base; prior diagnostics already contradict that hypothesis.
No fresh Linux, native Linux performance, capacity/nonresident, C ABI, full CPU
suite or GPU acceptance is claimed. All builds, tests, workers and compression
run serially.
