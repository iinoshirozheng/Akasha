# Legacy flush phase localization

Three instrumented native workers attribute **95.2–96.3% of aggregate public
flush time** to derived index cache publication, including its fingerprint,
validation and encoding. All 864 query pairs match frozen production controls.
This locates work; it does not establish a speed improvement. Production and
all M5/M6 requirements remain unchanged.

## Scope and checks

The [overlay-cache contract](../plans/2026-10-02-hnsw-overlay-cache.md) already
requires a complete validated delta artifact after checkpoint and reuses a
successfully published sequence/base key through compaction. It must retain
recovery coverage, corrupt-cache rejection and retry after failed publication.
Existing [streamed fingerprints](../benchmarks/2026-10-02-stream-fingerprint.md),
[ARM CRC](../benchmarks/2026-10-02-arm-crc.md) and F32 snapshot byte copying are
already adopted; this diagnostic does not repeat those implementations.

The isolated `legacy-flush-phases` package starts from production and adds
timestamps/output in collection flush/cache publication, cache-envelope
publication and HNSW snapshot encoding. It preserves validation, bytes,
publication order, sync boundaries and error handling. Named envelope bytes
are explicitly destroyed before rename, preserving the prior temporary's
destruction boundary. The Mojo 1.0.0 shared library compiles without warnings.

Each of the three original mixed corpora runs its unchanged 32-block plan.
Controls are the still-applicable production trial-0 results in the
[four-row pruning matrix](2026-10-14-hnsw-four-pruning.md), reused for correctness
without a cross-run speed comparison. All **864 paired IDs, Float32 score bits,
stats and execution decisions match**. Retained Arrow lease and exact reopen
oracle checks pass; native binary, plan and workload identities are verified.

There are 96 public flushes, 96 foreground cache groups, 96 delta snapshot
encodes and 192 foreground cache publications. Each corpus also logs one
publication outside public flush intervals, retained in the raw events.
Every flush contains exactly one cache group inside its writer-locked checkpoint
interval. No flush retries admission and none invokes inline compaction.
Admission time includes acquiring the writer lock and checking policy; zero
retry counts do not prove zero lock wait or no background maintenance.

## Measurements

Median milliseconds per event:

| Corpus | Public flush | Cache group | Overlay | Authority fingerprint | Metadata encode | Metadata publish |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Uniform 128 | 17.6745 | 16.7690 | 5.9745 | 4.9100 | 4.5035 | 1.2475 |
| Uniform 1536 | 28.7365 | 27.6550 | 12.4320 | 9.1500 | 4.5415 | 1.2830 |
| Real 1536 | 29.8830 | 28.6140 | 13.6135 | 9.0585 | 4.5070 | 1.3140 |

The cache-group/flush aggregate fractions are .95193/.95463/.96341. Within
those groups, overlay occupies 35.0%/44.8%/48.2%, fingerprint 29.2%/33.0%/31.3%,
and metadata encoding 26.8%/16.5%/15.7%. Remainders principally publish metadata.
The remaining HNSW-base cache branch is effectively absent in these fixtures.

The overlay includes the following snapshot-encoding intervals:

| Corpus | Full encode | Structure validation | Prepared-vector validation | Vector byte copy | Counts/edges | CRC | Final body copy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Uniform 128 | 5.3535 | 4.3525 | .3510 | .0100 | .4480 | .0665 | .0270 |
| Uniform 1536 | 9.6440 | 4.3190 | 3.7800 | .1055 | .5600 | .5650 | .2140 |
| Real 1536 | 10.9010 | 4.2485 | 5.1090 | .1070 | .5540 | .5645 | .2160 |

Prepared-vector validation includes materializing each row and its existing
finite/norm checks. The trace does not separate those costs. Structure
validation includes the full graph contract and bidirectional audit; it cannot
be removed based on its cost. Headers, layout and node encoding account for
the other small intervals.

Median metadata payload is 2,783,580 bytes for every corpus. Overlay payload
medians are 709,032 / 6,066,140 / 6,060,384 bytes. Full envelope publication
medians are 1.2400/1.2755/1.3055 ms for metadata and .4875/2.5660/2.5340 ms for
overlay. Its write/sync interval is .6655/.7280/.7230 ms for metadata and
.2610/1.4220/1.4080 ms for overlay. These are helper intervals including the
temporary's destruction, not isolated syscall measurements.

Nested intervals cannot be added as independent costs, and medians of parts
need not sum to the median total. Clocks/output perturb scheduling. All samples
remain: maximum public flush times are 20.023/35.980/36.981 ms; maximum metadata
publication intervals are 3.935/5.114/2.289 ms. No cause is assigned to outliers.

## Next bounded change and evidence

Inspect the prepared F32 row materialization in
`hnsw_store._copy_graph_vector`: it currently calls `vector_value` and appends
one scalar at a time before running the original validator. A checked contiguous
row copy through existing List/Span APIs can be tested without changing the
validator, format, cache lifetime or adding retained memory. This is a hypothesis,
not a measured optimization. The previous prefix-base bidirectional-validation
experiment is already [rejected](../benchmarks/2026-10-02-hnsw-validation-level-bases.md);
do not repeat it or skip validation.

The [archive](2026-10-14-legacy-flush-phases.json.gz) contains **173 files,
16,697,125 bytes**: complete source, production originals, instrumentation patch,
build/driver records, references, all raw events, plans, summaries and the reused
control report. All embedded hashes and source/binary identities are verified;
production source/Python binary still match their frozen parent.

- Diagnostic Python SHA-256: `4e0fb705345179ea91598d45ad8ac687cea2e969af934beea54e732324b0be82`.
- Production Python SHA-256: `96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c`.
- Archive SHA-256: `ebe149bfbe9278dc87997ad20544e07fbb459a8814ba046086666dc569407aa5`.

Build, workers and compression run serially. No additional full test suite,
Qdrant speed, Linux, capacity/nonresident, C ABI, crash or GPU gate is claimed
for this timestamp-only diagnostic. M5/M6 remain incomplete.
