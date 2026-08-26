# Phase 6: HNSW and Filter-Aware Planning

## Goal

Add deterministic in-memory approximate dense search while keeping WAL,
segments, and the MemTable authoritative. Exact search remains the correctness
fallback.

## Public contract

- `HnswIndex` owns vectors, deterministic levels, and bounded undirected links.
- `search_*_approx(query, k, ef_search)` exposes the search breadth.
- `search_*_approx_where(query, k, ef_search, expression)` over-fetches,
  filters, exact-reranks, and falls back to exact filtered search when needed.
- Small collections use exact scan through `QueryPlanner`.
- Reopen rebuilds the graph from recovered live state; mutation and delete
  refresh the graph without changing durable formats.

## Delivery

1. Test and implement deterministic bounded HNSW graph construction.
2. Test and implement greedy upper-layer and best-first base-layer search.
3. Test and implement exact/HNSW planning decisions.
4. Integrate approximate collection APIs, recovery, replacement, delete, and
   Boolean-filter fallback.
5. Document, benchmark, run all verification, merge, and push.
