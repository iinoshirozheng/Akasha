# Metadata bulk sorting with the pinned official API

#60 is implemented and verified in the worktree; it is not yet committed or
integrated. Keyword and numeric bulk loading now use
`sort[stable=True](Span(entries))`. The three private heapsorts and their sift
helpers are removed. Incremental insertion/removal, query bounds, value
validation, ordinal assignment and serialized formats are unchanged.

## Ordering and API decision

The internal entries implement `Comparable` using the existing ordering:
field name, value kind where applicable, value, then ordinal. They also satisfy
the official API's `Copyable` requirement. This is the previously compiled
Comparable approach from the API audit; no additional sorting framework or
runtime fallback was introduced.

The project compiler is **Mojo 1.0.0 (ed45d567), MAX 26.5.0**. The matching
[official sort source](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/builtin/sort.mojo)
uses insertion sort for small inputs and, with `stable=True`, bottom-up merging
through a temporary descriptor buffer. Both paths move entries rather than
copy their strings. The default quicksort was evaluated first: in a preliminary
100,000-integer organ-pipe case it took 17.721 ms versus the existing heapsort's
12.479 ms. Its source has no depth-limit fallback on that path. Stable merge
sorting retains bounded O(n log n) comparison work and passed the measured
matrix. The rejected default's raw samples remain in the artifact.

## Measurement boundary

The [benchmark](../../benchmarks/mojo/metadata_bench.mojo) compiles separately
against the original two index files and the final implementation. Three fresh
process trials alternate implementation order. Each cell uses 10,000 or
100,000 entries, one of keyword/integer/float, 0 or 256 extra prefix bytes, and
sorted/reverse/random/tied/organ-pipe inputs: **60 paired cells, 360 runs**.
Random order is a fixed unsigned LCG/Fisher-Yates permutation; tied values
retain distinct ordinals. Organ-pipe values rise then fall.

The timer covers only `finish_bulk()`. Entry allocation, input preparation and
the audit serialization are outside it. Every sorted entry's name, type/value
and ordinal contribute to the byte count and CRC. All 180 before/after trial
pairs have equal byte counts and CRCs. Exact entry comparisons and byte-by-byte
cache tests supplement these checksums. Timings are per-cell medians, not a
claim about all workloads. This is an interactive macOS ARM64 host without
fixed affinity or CPU frequency.

| 100,000 entries | Extra prefix bytes | Old sort, ms | Official stable sort, ms | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Keyword, random | 0 | 36.749 | 25.009 | 1.47× |
| Keyword, random | 256 | 87.356 | 59.720 | 1.46× |
| Integer, random | 0 | 14.413 | 8.738 | 1.65× |
| Integer, random | 256 | 10.491 | 6.383 | 1.64× |
| Float, random | 0 | 14.763 | 9.613 | 1.54× |
| Float, random | 256 | 11.195 | 7.680 | 1.46× |
| Keyword, organ-pipe | 0 | 33.763 | 17.723 | 1.91× |
| Integer, organ-pipe | 0 | 12.978 | 6.210 | 2.09× |
| Float, organ-pipe | 0 | 12.431 | 6.889 | 1.80× |

Across all 60 cells, final/old median sorting time is 0.298–0.974. Increasing
entries tenfold increases normalized time per entry by at most 1.772× in the
measured patterns. The separate end-to-end MetadataIndex workload, which also
allocates payloads and updates slot lookups, improves median build time from
3.351 to 2.786 ms at 10,000 points and from 37.892 to 31.000 ms at 100,000.
Its existing scaling gate passes in all three trials for both implementations.
Filter query timings remain recorded separately; this change does not claim a
query-speed improvement or close the HNSW/Qdrant gap.

## Copies and temporary memory

The [compiled copy probe](../research/2026-10-01-metadata-sort-probe.mojo) wraps
the real three entry types with a counting copy constructor. A deliberate copy
first proves that the counter works. Sorting 0/1/31/32/33/10,000/100,000 entries
then observes **zero entry copies in all 21 cases**. This agrees with the
pinned source's move operations. It does not claim that index construction is
copy-free: entry construction and the probe's input preparation own strings.

Stable sorting introduces O(n) temporary descriptors. On this target they are
72 bytes per keyword entry and 40 per integer/float entry. At 100,000 entries,
the requested temporary allocation is 6.866 MiB or 3.815 MiB respectively.
The two numeric sorts allocate and release their buffers sequentially; string
contents are not duplicated by the sorting operation.

Separate `sort-memory` processes stop before audit serialization. Three-trial
median process peak RSS for long-string keyword input increases from
48.531 to 55.422 MiB, **+6.891 MiB**. Short keyword input is about 29.6 MiB and
numeric input about 22.6 MiB for both versions: input construction already
sets a higher peak and allocator reuse can hide the scratch allocation.
These are whole-process peaks, not exact live-allocation measurements. The
ordinary byte-audit runs retain their RSS values but are not used to estimate
sorting memory because serialization adds a larger buffer.

## Validation

The four new regression tests pass against both the original implementation
and the replacement. They preserve UTF-8/empty values, long strings, mixed
String/Bool fields, integer extremes, finite float extremes and signed-zero
bits, all numeric operators, field/value/ordinal ties, empty/singleton inputs,
duplicate entries, invalid bulk states and post-bulk mutation. Cache encoding
is compared byte by byte before and after decode/delete/reinsert. This is a
behavior-preserving refactor, so the baseline tests are expected to pass.

Final checks on the replacement:

- **62 Mojo tests** across metadata field indexes, MetadataIndex, persisted
  cache, cache envelope, persistent filters, generation fields, snapshots and
  filtered HNSW pass.
- **118 Python tests** pass, including actual native Qdrant adapter tests;
  the same three existing deprecation warnings remain.
- **21 copy-probe cases**, `pixi run build`, and all three built examples pass.
- `git diff --check` passes. WAL/segment bytes, crash publication and GPU paths
  are unchanged; their earlier successful gates remain applicable and were not
  rerun for this sorting refactor.

## Reproduction and provenance

```sh
pixi run mojo build -I src benchmarks/mojo/metadata_bench.mojo -o .build/metadata-bench
.build/metadata-bench
.build/metadata-bench sort keyword 100000 random 256
.build/metadata-bench sort-memory keyword 100000 random 256
pixi run mojo run -I src docs/research/2026-10-01-metadata-sort-probe.mojo
pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps pytest tests/python -q
```

[Raw measurements and source](results/2026-10-01-metadata-sort.json) include
every run, exact final benchmark/index/probe sources, original index sources,
driver scripts, binary hashes, source hashes, preliminary default-sort
rejection evidence, all targeted test output and measurement limits. To
reconstruct the original implementation, copy the current source tree and
replace only the two index files with their archived originals, then compile
the same final benchmark against that tree. The initial exploratory samples
are retained separately and are not mixed into the final medians above.

Base HEAD is `31f27e5`; the worktree source hash (sorted paths and contents under
src/tests/native/include/python) is
`0382203bab2012e2546d64ea8575ee1e0d6208d5375d8ddb9d6d71008cea700e`.
#61–#63, native/named/binary/multivector support, M5/M6 warm/cold performance,
and final integration remain open.
