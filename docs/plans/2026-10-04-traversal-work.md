# HNSW traversal work audit

Continue M5/M6 at `fd82b49`, production engine `ac48cda` and kernel `80ddc239…`.
This is a diagnostic, not an optimization candidate or performance gate.

Production disassembly confirms two current-state reads for each filtered layer
candidate. Reanalysis of the existing real correlated/independent profiles places
all current-state reads at only 1.36% / 0.82% of query-boundary samples. Source and
metadata admission together account for 3.56% / 4.25%. This does not justify a new
admission cache or unchecked path. Distance remains the largest sampled category.

Count the actual adjacency and distance grouping work before choosing another
implementation. In an isolated source copy, add local counters to `search_layer`
for edges checked, already-visited edges, expanded nodes and group sizes 0–4.
Print one diagnostic record at the end of a layer. Keep every validation, visit,
heap/admission operation, score operation and public statistic unchanged.
No graph, owner, cache, durable format, compiler optimization or configuration
change is involved.

Compile the copied binding with Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4.
Use original fixed corpora/queries/filters/K and selected default efs; include the
existing named ef grid as a separate diagnostic. Replay saved graph bytes in fresh
database clones. Capture native output per query, compare IDs/score bits/all
public stats to production, and check exact oracles separately. Count all groups,
including empty tails, and preserve all failures. Instrumented wall times cannot
be substituted into any acceptance matrix.

Use existing production profiles for CPU attribution; counts alone are not cost
estimates. Inspect the checked-edge contract before considering any reordered
validation: lower-level graph access must still reject invalid and cross-level
edges, and invalid boundary inputs must not mutate scratch/statistics.

Keep artifacts in `.build/2026-10-04-current-state-audit`, freeze evidence after
analysis, and update the sole checklist without marking M5/M6 complete. No new
Qdrant, full integration, Linux or nonresident/memory-limit pass is implied.
