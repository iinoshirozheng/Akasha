# Borrowed payload bytes into the existing binary writer

All nine native flush pairs improve QPS **3.5–11.1%** and p95, preserving
payload bytes and all query audits. The candidate remains isolated: warm query
speed stays 21/36, mixed falls 26→24/36 and six individual query cells change
pass→fail. Combined write+flush still passes only 3/9. Production is unchanged;
M5/M6 are not accepted.

## Implementation and checks

Only two production-based files change. `BinaryWriter.write_bytes` takes a
borrowed `Span[UInt8, _]` and extends its existing owned byte List. The installed
Mojo **1.0.0 (ed45d567)** compiler accepts all original List callers through its
implicit conversion; no extra overload or compatibility path is needed.
`encode_payload` passes string/name byte spans and borrows the tagged string
field directly instead of first copying it. Field order, all validation,
length prefixes, numeric encodings and the final 16 MiB check remain unchanged.
There is no new dependency, retained view or memory cache.

The [official String API](https://mojolang.org/docs/std/collections/string/string/String/)
documents `as_bytes`; the current documentation is 1.1.0, so local usage and the
project compiler establish compatibility. Existing record/Arrow internals also
read the string field after checking its tag. Local Qdrant uses serde_json for
its payload storage; that different format cannot replace Akasha's codec.
The existing writer already bulk-copies Lists through Span. The fixed workload
has three integer fields and a 256-byte string per point.

Four new semantic cases pass on both parent and candidate: independently
specified UTF-8/NUL golden bytes, all scalar kinds and 16 string lengths against
the frozen scalar encoder, exact name/count/payload size boundaries, and invalid
names/duplicates/tags. Mutation after encoding preserves the output's ownership.
A fifth test for borrowed writer inputs first fails parent compilation because
Span cannot convert to List, then passes with the new canonical argument. It
covers empty spans, nonzero-offset slices, owned List calls, source mutation and
destruction of a local string.

Validation passes **102 Mojo cases in 17 files**, **9 crash-state cases in three
files**, and **369 Python cases**, no skips and three existing Python warnings.
Coverage includes document codec, checksum, metadata/cache, persistent documents,
WAL/segment v1 compatibility, point codec/WAL/store/migration/compaction, checkpoint
ordering and batch atomicity. Crash-state cases are not the full OS-kill suite.
The shared library compiles without warnings. Full source/binary identities and
child compiler routing are checked.

## Fixed matrix and retained failures

All 54 workers complete, using unchanged corpora, ef values, filters, K, plans,
oracles and rotating triple order. Warm takes 44.54 s, mixed 69.39 s. Mixed returns
its expected strict-gate failure after all nine triples. Every paired query has
identical IDs, Float32 bits, stats and execution decisions; retained Arrow leases
and exact reopen checks pass. Quality is 36/36 on each side in each phase.

| Phase | Strict speed before → after | Pass → fail | Fail → pass |
| --- | ---: | ---: | ---: |
| Warm queries | 21 → 21 / 36 | 2 | 2 |
| Mixed queries | 26 → 24 / 36 | 4 | 2 |
| Mixed write+flush | 3 → 3 / 9 | 0 | 0 |

The six pass→fail cells are warm uniform-1536 selective trial 0 and real-1536 all
trial 2; mixed uniform-128 selective trials 0/2, uniform-1536 selective trial 2,
and real-1536 all trial 0. No improved cell offsets these failures. The prior
lock diagnostic does not retroactively explain every uninstrumented sample.

Flush QPS after/before by trial:

| Corpus | Trial 0 | Trial 1 | Trial 2 |
| --- | ---: | ---: | ---: |
| Uniform 128 | 1.1057 | 1.0940 | 1.1038 |
| Uniform 1536 | 1.0598 | 1.1110 | 1.0501 |
| Real 1536 | 1.0420 | 1.0456 | 1.0354 |

All nine flush p95 ratios are below one (.8867–.9683); combined write+flush QPS
improves 2.4–7.4% and its p95 also improves in all nine pairs. These relative
gains still miss Qdrant in the six high-dimensional combined cells. Individual
updates are not a durability-equivalent comparison; the combined gate remains.

Post-timing audit finds all **18 overlay/metadata inner payload pairs byte-identical**,
with valid envelope and snapshot CRCs. It retains full-file and payload SHA-256,
sizes, sequence and generation; equality is checked directly, not by CRC residue.

## Evidence and next step

The [archive](2026-10-14-payload-span-encoding.json.gz) contains **808 files,
3,891,587 bytes**, including full candidate source, scalar reference, new/existing
tests, parent failure, compiler records, all worker logs/raw timings and byte
audits. The three complete plans are referenced by verified hashes in the flush
archive. All embedded hashes and source/binary inventories are verified.

- Candidate Python SHA-256: `620a34d182d491bd1ccdb365a5f8515e9577a5d94306a92c0b24f6b30ea02e25`.
- Archive SHA-256: `e615322190a282020059383f75a43b627f3b45c554590fa39470756610f0a10e`.

Keep this independently validated candidate and the
[F32 snapshot row-copy candidate](2026-10-14-hnsw-validation-row-copy.md) frozen.
Next verify their composition in another isolated tree: it should reduce two
distinct measured flush costs, but no combined benefit is assumed and all fixed
query gates still apply. No new Linux, capacity/nonresident, C ABI, full CPU or
GPU acceptance is claimed. All jobs run serially; production remains unchanged.
