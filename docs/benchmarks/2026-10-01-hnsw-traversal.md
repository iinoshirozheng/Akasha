# Mapped traversal and heap layout

After the [four-group F32 kernels](2026-10-01-hnsw-accumulators.md) and
[SIMD rerank validation](2026-10-01-rerank-validation.md), native stage timings
on the same persisted 8192×1536 dot workload identified candidate collection
as the dominant remaining query cost. `hnsw_query_stages.mojo` opens the graph
and measures candidate collection, exact reranking and the complete public
kernel search separately. Every staged result must equal public IDs/scores.

The 67 queries are mode `all` from that paired workload, serialized as contiguous
little-endian F32 rows. EF=512, K=10, one serial query at a time. Four sequential
passes warm the same reopened graph; this is a diagnostic, not a fresh Qdrant
comparison or a non-resident measurement. No builds/tests ran during sampling.

Mapped graph node IDs, offsets, counts and edge slots previously decoded each
integer through individual checked byte reads. They now use the existing
`MappedFile.load_scalars` unaligned bounded load. Supported mapped hosts are
already constrained to little endian. Range/open-state validation remains,
and no interior pointer escapes the mapping owner.

HNSW heap entries now place the 64-bit ID before the 32-bit slot/distance and
use the standard trivial register-passing trait. A compiled `size_of` probe
confirms 24 → 16 bytes per entry. The existing comparison and heap algorithms
remain unchanged; this is separate from #61's rejected official-heap migration.

Raw totals in nanoseconds, each row covers 67 queries:

| Change | Pass | Candidate collection | Rerank | Complete kernel query |
| --- | ---: | ---: | ---: | ---: |
| Before integer-load change | 0 | 349187000 | 47663000 | 381614000 |
| Before integer-load change | 1 | 342181000 | 47687000 | 374386000 |
| Before integer-load change | 2 | 343707000 | 47686000 | 376176000 |
| Before integer-load change | 3 | 348438000 | 48012000 | 382585000 |
| Bounded integer loads | 0 | 291338000 | 47763000 | 322322000 |
| Bounded integer loads | 1 | 283886000 | 47870000 | 316267000 |
| Bounded integer loads | 2 | 287020000 | 48543000 | 319135000 |
| Bounded integer loads | 3 | 289734000 | 47583000 | 321369000 |
| Loads + compact heap entry | 0 | 282165000 | 48123000 | 313784000 |
| Loads + compact heap entry | 1 | 288821000 | 48253000 | 321344000 |
| Loads + compact heap entry | 2 | 283420000 | 48225000 | 314250000 |
| Loads + compact heap entry | 3 | 282436000 | 48439000 | 314855000 |

Every pass retained 68,608 candidates and performed 580,391 graph distances.
The integer loads improve this complete mapped query by approximately 15%.
The heap layout primarily establishes a one-third entry memory reduction;
these few passes do not establish a separate latency improvement for it.

Verification: 9 mapped-file and 9 HNSW-view tests (unaligned/truncated/corrupt/
closed inputs, owned/mapped equivalence), 9 heap oracle tests and 14 search-layer
tests pass. The 11-cell post-HNSW smoke matrix passes all four filter modes at
recall 1.0 for every supported metric/graph encoding pair. This smoke matrix is
dimension 32 and does not replace the high-dimensional paired benchmark.

Reproduce the stage diagnostic with:

```sh
pixi run mojo build -I src benchmarks/mojo/hnsw_query_stages.mojo -o .build/hnsw-query-stages
.build/hnsw-query-stages DATABASE ALL_QUERIES.f32 512
```
