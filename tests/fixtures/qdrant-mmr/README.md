# Pinned Qdrant MMR reference

`rtk proxy python3 scripts/qdrant_mmr_reference.py` regenerates `mmr.json` from
Qdrant `74f3e85b9473c62560006c043e13737ce6b48412` without changing the historical
recommendation fixture. It compiles `maximal_marginal_relevance` verbatim and
reuses the original portable metric/normalization/sparse/MaxSim functions from
the recommendation oracle generator. Rust compiler and pinned reference Git
objects are needed only to regenerate fixtures.

The container adapter models ordered IndexSet insertion/swap removal; the
OrderedFloat adapter treats signed zeros as equal and all NaNs as equal and
larger than numeric values. The matrix supplies directional source scores.
The oracle is not Qdrant's complete service, volatile-storage implementation,
SIMD dispatch, typed storage or ANN candidate planner.

192 reducer cases cover empty/single/multiple inputs, tied and random scores,
zero/oversized limits, signed zeros, infinities/NaNs and F32 arithmetic.
112 vector cases cover dense/sparse/MaxSim and Dot/L2/cosine where supported,
including fractional values and directional pair scores. Vector-case lambdas
are computed from F32 public diversity values, matching query conversion.
Original candidate scores are distinct and returned unchanged, so the tests can
detect replacing or sorting results by the MMR score.

The Mojo tests check exact selection, relevance/pair-score bits, the captured-root
adapter and public snapshot lifetimes. Python tests separately cover API modes,
original scores, candidate bounds, lookup/exclusions, filters, reopening,
cancellation/budgets, datatype boundaries and Arrow lifetimes.

Source provenance and extraction/scaffold hashes are in the fixture. See
`docs/upstream/ports.json`, `THIRD_PARTY_NOTICES.md` and the validation report.
