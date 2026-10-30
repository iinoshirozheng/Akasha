# Original Roaring and Lance nullable-row oracle

Reproduce with `rtk proxy pixi run python scripts/lance_rowset_reference.py`.
The committed Cargo.lock is reused on a clean build. Lance is fixed at
`ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`; roaring 0.11.4 matches that source's
lockfile. Roaring source/archive and license bytes are checked before execution.

The actual original roaring crate produces 309 set scenarios, 1,236 binary set
operation results, 112,021 insertion flags and 9,853 removal flags. Cases cover
UInt64 extrema, 16/32-bit partitions, duplicate IDs, sparse/dense/mixed stores,
4096/4097 transitions, full 16-bit blocks, empty sets and owned snapshots.
No expected set algorithm is implemented in the generator.

The original Lance `mask/nullable.rs` module produces 564 mask scenarios,
2,256 NOT/AND/OR/union_all outcomes and 27,072 sampled Kleene states. Every raw
selected/null overlap representation and allow/block combination is exercised,
including null rows absent from selected. Raw selected/null sets and allow/block
tags are compared as well as semantic states.

For this materialized-row oracle, a small `RowAddrTreeMap` adapter delegates
finite set operations to the actual roaring `RoaringTreemap`. The source
nullable algorithm bodies are unchanged; only the unused DeepSizeOf import and
derive are removed. This does not execute Lance's full-fragment representation,
cache, serialization or query planner. `sources.json` hashes the original and
adapted module, dependency archives/source files, scaffold, generator and data.
Existing Lance and new roaring Apache-2.0 notices are under
`docs/upstream/licenses`.

The native port retains array and bitmap containers reached by point mutations.
It does not claim range/run optimization, full-fragment selections, portable
Roaring bytes or a usable collection scalar index. Those remain in the full
Lance JSON-index and product plans.
