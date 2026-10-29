# Qdrant DBSF normalization fixtures

`normalization.json` contains 114 fixtures / 3,706 individual scores, including
empty, singleton, constant, signed, near-constant, small-magnitude, outlier and
deterministic generated cases. Both original and descending query-result orders
are represented; Welford accumulation order is significant.

Generate from the pinned Qdrant checkout using:

```sh
rtk proxy python3 scripts/qdrant_dbsf_reference.py
```

The script obtains the source with `git show` at the exact recorded revision,
extracts `norm`, `welfords_mean_variance` and `distr_norm` verbatim, and compiles
them using `rustc`. Its shims only replace the score-carrying record and score
alias; the algorithm is never reimplemented in Python. Input and output F32
bits, readable values and source/extraction/scaffold hashes are recorded.

Mojo checks all cases directly with absolute tolerance `1e-5`, the upstream
normalization-test absolute tolerance. Python checks descending rankings through
the real collection API. The source oracle is not a performance benchmark.

Qdrant source is Apache-2.0; see [notices](../../../THIRD_PARTY_NOTICES.md).
