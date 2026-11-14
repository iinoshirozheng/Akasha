# Lance B-tree page lookup reference

Pinned Lance revision: `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`.
Source: `reference/lance/rust/lance-index/src/scalar/btree.rs` (Apache-2.0;
see the reference repository LICENSE). Extracted ordering implementations also
come from the pinned Lance scalar source. `sources.json` records source,
extracted-unit, generator, scaffold, fixture and dependency-lock hashes.

Regenerate from the repository root:

```
pixi run python scripts/lance_btree_lookup_reference.py
```

The generator executes the original lookup and statistics function bodies.
The physical-type dispatch adapter supplies real Arrow comparators to the
original equality scan; it does not reimplement that scan. Cargo.lock pins the
Rust dependency graph. The corpus reuses bitmap scalar inputs and creates leaf
batches of 1, 3 and 7 rows: 183 datasets and 48,720 queries across Boolean,
Int64, Float64 (raw bit strings), Utf8 and Binary (hex strings).

The native test compares candidate page IDs, ordering and All/Some flags for
equality, IN, ranges and IS NULL, including null bounds, repeated keys and
floating-point edge values. Run:

```
pixi run mojo run -I src tests/mojo/test_lance_btree_lookup.mojo
```

This corpus verifies page lookup only. It does not verify leaf predicates,
whole-index null masks, persistence, catalog dispatch or query integration.
