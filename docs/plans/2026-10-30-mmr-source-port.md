# Q03a MMR source port

Continue from `8da22e8` under the full feature-completion plan. Q03 also requires
discovery/context; all existing Q02, protocol, datatype and product gates remain.
No performance work resumes.

## Source and behavior

Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`:
`lib/shard/src/query/mmr/{mod,lazy_matrix}.rs`, collection universal query
conversion, planned query and REST schema. Read the actual matrix code: despite
its symmetric comment, it caches ordered `(i,j)` cells and scores candidate i
against selected j. MaxSim is directional, so do not mirror cells.

- Port the original selection loop: highest query similarity first, last tie
  wins in current insertion order, IndexSet swap removal, F32 lambda products,
  ordered-float NaN/zero comparisons, original scores returned unchanged.
- Native nearest and point-ID nearest accept optional MmrOptions. Retrieve the
  candidate limit on one read root using exact/HNSW/IVF, then apply MMR on that
  same root. Python and Arrow expose this native operation. Default diversity
  is 0.5, default candidate limit is k, explicit candidate limit is 0..16384;
  preserve existing native positive-k contract. Binary MMR is unsupported by
  the source and must fail explicitly. Existing candidate retrieval contracts
  and all low-precision canonical-storage gates remain documented.
- Use source F32 volatile scoring for dense/sparse/MaxSim, adapting native raw
  stored values through the existing source preprocessing boundary. Cache
  ordered cells lazily in a dictionary rather than allocating the upstream
  n-by-n Option matrix; no selection/scoring algorithm substitution.
- Deduplicate before missing-field removal. Preserve candidate order and scores,
  check cancellation/deadlines and bound scoring work through QueryControl.

## Steps and acceptance

1. Compile the unedited upstream MMR function with explicit container adapters;
   reuse the reproducible portable metric oracle. Add fixtures for ties, signed
   zero, NaN/overflow, zero/one/empty/oversized limits, asymmetry, F32 rounding,
   and dense/sparse/multivector examples.
2. Native differential tests must compare exact selected indices and original
   score bits. Integrate retrieval/reranking and public APIs; validate candidate
   limits, filters, exclusions, modes, retained roots, reopen, Arrow lifetime,
   cancellation and resource errors.
3. Compile native tests, rebuild Python bindings, run relevant regression tests
   serially. Record source/target hashes, license notice, validation evidence,
   API contracts and remaining gates. Commit without pushing.

Status: the native nearest MMR slice is implemented and verified. 304 source
fixtures, 26 native cases and 1743 distinct Python cases pass (one optional skip);
final index-option changes passed 50 MMR and 521 focused regression cases.
Build/C checks and provenance are recorded in
[validation](../research/2026-10-30-mmr-validation.md).
MMR does not complete Q03 or the universal Query API.
