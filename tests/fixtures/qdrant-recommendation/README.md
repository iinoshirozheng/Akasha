# Qdrant recommendation reference

Regenerate from pinned source with:

```sh
rtk proxy python3 scripts/qdrant_recommendation_reference.py
```

`recommendation.json` freezes 336 queries and 24 score reductions from Qdrant
`74f3e85b9473c62560006c043e13737ce6b48412`. Fourteen functions are extracted
without modifying their bodies: three average transforms, sparse combination
and sparse scoring, two sigmoid functions, best-score/sum-score reducers,
dot/Euclid/cosine scalar metrics, the normalization predicate and MaxSim.
Source, extracted-function and generated-harness hashes are embedded.

The harness substitutes owned vector containers, errors, iterator/type plumbing,
and candidate storage. It calls upstream preprocessing before target scoring;
ID-tagged examples additionally pass through source-field preprocessing before
the average transform. Results use ascending numeric ID ties. This does not run
the Qdrant HTTP server, HNSW, SIMD dispatch, F16 or U8 datatype conversion.

Native tests compare average transforms and reductions by exact F32 bits.
Python tests call the actual Mojo collection and Arrow boundary and compare
candidate IDs plus F32 scores (2e-6 absolute/relative tolerance for independent
compiler normalization). Other tests cover lookup, filters, snapshots, native
dtype adaptations, finite validation, budgets, cancellation and ownership.
Those tests are not independent datatype or complete protocol parity evidence.

Empty positives are invalid for average-vector; custom strategies accept
negative-only inputs. Nonfinite native results are rejected, including source
sum-score overflow. Sparse nearest zeros are omitted; sparse custom-score zeros
remain eligible. Multivector averages concatenate rows.
