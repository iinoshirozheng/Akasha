# Measure four-row F32 delta scans

Continue from `a57f11a`; M5/M6 remains incomplete. Production `c00494f` sampling
retained in the paired-exact archive places 6.04–7.05% of filtered real ANN main
thread samples in scalar owned distance. Those queries use `segmented-delta-scan-f32`.
Mapped four-row scoring remains the largest cost (35%); disassembly maps its main
sample offset +1512 to a vector load, and +1536 to loop progression, with no
steady-loop vector spills. This does not prove redundant owner/bounds checks are
the dominant problem or justify redoing rejected raw-span/full-row probes.

Try only reusing the existing owned `_distance_to_four_f32` in bounded delta scans.
Collect up to four current/admitted F32 slots in ascending physical order, score
full groups together, and score partial groups individually. Preserve the scan
selection bounds, prepared-query validation, admission/heap order, IDs, score
bits and every public stat. Other backends retain their current scalar loop.
No new kernel, abstraction, tuning parameter, format, cache or dependency.

The existing level-zero HNSW grouping is the local pattern. Qdrant's local
`reference/qdrant/lib/segment/src/vector_storage/query_scorer/metric_query_scorer.rs`
(in the parent checkout) batches dense access but scores rows through its own
metric. It supports the batching boundary, not an Akasha speed claim. The alternative
of changing mapped access has no new causal evidence; leaving delta scalar is
the control and remains the decision if public benefit is not repeatable.

Before modifying the candidate, add scalar-oracle regressions for all three F32
metrics, SIMD boundaries, groups and tails, filtered/inactive holes, ID ties and
scan stats. Existing query/demand/identity/error tests remain required. The fixed
public gate already fails, so retain behavior tests on the baseline and candidate;
do not add brittle wall-clock test assertions. Use an isolated copied source and
binding entry. After targeted tests, compare all fixed warm/mixed trials, preserving
all samples, efs, recall target, service boundaries and strict parity failures.
Expected overall ceiling is small because the measured scalar component is small.
