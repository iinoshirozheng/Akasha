# Lance materialized bitmap target oracle

Run `pixi run python scripts/lance_bitmap_reference.py` from the project root.
The generator executes unchanged pinned Lance ordering, old-row filters,
bitmap search, streaming training/update merge and remap methods. Actual
DataFusion ScalarValue, Arrow sorting and roaring crates provide typed values,
sorting and sets. In-memory store/stream/error adapters replace transport only.
The first generation needs locked crates and the pinned Rust total_cmp source;
subsequent runs reuse the source under `.build/lance-bitmap-reference`.

Fixtures include Boolean/Int64/Float64/Utf8/LargeBinary, typed nulls, signed
zero, distinct NaNs, byte ordering, all range endpoints, IN duplicates, empty
and dense postings, cross-batch equal runs, old-ID/fragment filters and UInt64
remapping/deletion/collisions. Unknown/null results are retained separately.
Unsupported full-text/prefix queries preserve original errors.

This does not execute Lance file encoding, caches, shard merge, SQL planning
or collection publication. Native tests compare every recorded state/search
and comparison. Bounds/type errors and cancellation are native adaptations.
Source, dependency, compiler, adapter and output hashes are in sources.json.
