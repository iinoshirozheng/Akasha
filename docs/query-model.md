# Query model

Status: exact vector retrieval implemented; filtering and hybrid retrieval planned.

The current Mojo API exposes exact dot-product, squared-L2, and cosine Top-K searches through `FlatIndex`. Scores remain in their native metric scale: larger is better for dot product and cosine, while smaller is better for L2. Equal scores use ascending point IDs as a deterministic tie-break.

The future query model will separate vector retrieval, document filtering, result fusion, exact reranking, projection, and limits. The planner will choose between filtered exact search and approximate search based on candidate selectivity.
