# JSON bitmap external sorting and spill

Implement the next build-time storage layer while preserving existing scalar
ordering, inferred/learned types, nullable semantics and atomic catalog publication.

Reference: pinned Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`,
`scalar/json.rs::sort_stream_by_value` (ascending, nulls first, spilling enabled)
and `scalar/bitmap.rs::streaming_build_and_write` (sorted value-run consumption).
Reuse Mojo's stable sort and the current bitmap run merge; no new dependency.

Collection builds always use external-capable sorting with an 8 MiB logical run
budget and 512 MiB combined temporary-file cap. Small inputs sort in memory;
large inputs become sorted runs. Two-way merge passes keep only two row heads
and two open anonymous files, independent of run count. The output stream feeds
the same bitmap builder used by in-memory training, without rematerializing input.

Native standalone training retains its documented in-memory mode and aggregate
input limits. `sort_memory_bytes` explicitly selects external training; there is
no retry/fallback after I/O failure. Null inference prefixes retain sortable IDs,
not extracted JSON; EOF alone defaults to Utf8. One oversized row may exceed
the run target but is still bounded by `max_bytes`.

Temporary files use POSIX mkstemp and immediate unlink, FileHandle ownership,
per-record CRC and bounds checks. They are not durable formats and are never
catalog entries. Success, abort, cancellation, exception and process exit close
the descriptors. No startup orphan scan or migration is needed.

Validation: force small runs across all five scalar types and the 786 existing
source scenarios; test multi-pass stable merge, long null prefix, input larger
than the run budget, final bitmap limits, disk budgets during flush/merge,
truncation, unavailable directories, cancellation and descriptor cleanup. Run
public create/rebuild/reopen above the real default spill threshold and existing
query/catalog/Arrow regressions. Heavy builds remain sequential.

Output bitmap, source snapshot, per-batch extraction/conversion and active query
results retain their existing bounds. This does not implement a disk-native
bitmap builder, persistent shard merging or incremental shard publication.

Completed: [22 native / 206 Python tests and source-oracle validation](../research/2026-11-13-json-bitmap-external-sort-validation.md).
