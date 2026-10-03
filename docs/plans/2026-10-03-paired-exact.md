# Measure paired checked F32 exact scoring

Continue M5/M6 from `c00494f`. The filtered-only revision is now adopted;
the initial universal-pairing candidate remains unadopted. The existing profile
places about half of uniform-128 scan samples, and 69.8% of real selective samples,
inside exact scanning (including inlined arithmetic). Query preparation is already
once per scan; every candidate still requires finite validation and cosine norm.

First measure a private two-row kernel, sharing only the query SIMD load. Keep
each row's accumulator width, reduction, scalar-tail order, finite checks,
cosine norm and error order. Lists retain their owners throughout each call.
Use the existing SIMD implementation and constants; add no package, cache,
unowned view, inline directive or stored validation summary. Local Qdrant's
`MetricQueryScorer::score_stored_batch` supplies a batch boundary but invokes its
own metric per row; it does not establish performance for this checked kernel.

Compare every score bit over the three frozen corpora and all three metrics at
SIMD boundaries, including nonfinite values in either row, dimension errors,
zero norms, tails and finite extremes. Seven alternating kernel passes are
diagnostic only. If that benefit is sufficient, separately test batching adjacent
eligible exact-scan candidates while retaining admission order, missing default
fields, all filters and empty behavior. Public warm/mixed trials must keep all
original parameters and samples. Final parity remains a per-cell gate; it cannot
be inferred from this microbenchmark.

The first candidate passes 99 targeted Mojo, 358 Python, C ABI and three examples.
Warm improves 17→21/36 and mixed stays 31/36, with no strict pass→fail, but every
uniform-1536 full-scan trial regresses: QPS ratios .840–.903 across warm/mixed.
Retain that candidate and all samples. Do not promote it as a universal scan
improvement. A second isolated candidate will use pairing only for a proper
subset of live ordinals, keeping the original loop for a full live set. This is
an operation-shape distinction with no hardware threshold or new setting. Repeat
the entire fixed matrix, including the full-scan controls; do not exclude them.

The final restricted candidate passes 99 targeted Mojo (94 saved final-source
cases plus five promoted kernel cases), 358 Python, C ABI/client and three
examples. Warm 19→20/36 includes two real-all pass→fail cells; mixed 29→32/36
has none. All negative samples remain. Repeated high-dimensional filtered gains
support this intermediate change, but every-cell parity remains FAILED.
[Results, baseline profiles and frozen archive](../benchmarks/2026-10-03-paired-exact.md).
