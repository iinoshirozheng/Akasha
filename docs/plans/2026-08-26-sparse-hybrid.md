# Phase 7: Sparse and Hybrid Retrieval

## Goal

Store caller-provided sparse vectors durably, search them with an inverted
index, and combine dense and sparse rankings with deterministic reciprocal-rank
fusion (RRF).

## Contract

- Sparse elements are strictly ascending non-negative term IDs with finite,
  non-zero `Float32` weights.
- Sparse mutations share the collection sequence space and are fsynced before
  becoming visible.
- A checksummed sparse snapshot sidecar is written before manifest publication;
  its checkpoint sequence must equal the manifest sequence.
- Sparse WAL recovery tolerates only an incomplete EOF record, like dense WAL.
- Dense delete removes the point from sparse search.
- Sparse dot-product and hybrid RRF preserve ascending ID tie-breaking.
- Boolean metadata expressions are evaluated before sparse candidates enter
  ranking or fusion.

## Delivery

1. Implement and test sparse value validation and inverted search.
2. Implement and test stable RRF.
3. Implement versioned sparse WAL and snapshot sidecar codecs.
4. Integrate sparse mutation, recovery, checkpoint, filtered search, and hybrid
   collection APIs.
5. Document formats and examples; run complete verification, merge, and push.
