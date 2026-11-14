# Native paged B-tree — full implementation goal

User authorized all four proposed items, not just a lookup dependency:

1. Pin and execute Lance source contracts for scalar ordering, NULL, NaN,
   page candidates and page predicates; retain reproducible fixtures/provenance.
2. Implement a real native paged B-tree: sorted value/row-ID leaves, min/max/null
   directory, equality/range/IN/IS NULL, bounded lazy page access and controls.
3. Integrate index-kind selection with durable catalog, immutable snapshots,
   create/list/drop/rebuild, Python/HTTP and existing JSON/Arrow query execution.
4. Verify source parity, boundaries, corruption/torn writes, restart, old formats,
   publication failure, old snapshot lifetime and relevant regressions.

Current status: all four items are implemented and verified. See
[the requirement-by-requirement validation](../research/2026-11-14-json-btree-integration-validation.md).

## Existing evidence and design constraints

- Lance pin: ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e.
- `scalar/btree.rs`: BTreeLookup try_new, scan_equality_pages, pages_between,
  pages_null; analyze_batch/train_btree_page; search_with_options/search_page.
- `scalar/btree/flat.rs`: actual page predicate evaluation and null shortcuts.
- Lance uses an in-memory min/max directory and disk leaf batches, default 4096
  rows, not a mutable pointer-tree. Port that architecture with Akasha codecs.
- Reuse existing five scalar key types and total ordering, external sort,
  query controls, nullable sets, immutable mapped owners and atomic publishing.
  B-tree must retain sorted leaf rows, not disguise a bitmap index as a B-tree.
- Candidate range selection includes straddling pages and repeated minima.
  All-null and mixed pages are distinct. IN deduplicates candidate pages.
- Flat predicates differ from bitmap null shortcuts. Source parity for the raw
  target and semantic guards for JSON expression substitution are separate gates.
  Explicitly audit unbounded ranges, null literals/IN, empty IN and NaN/zero bits.
- Existing authoritative/public contracts and old fixtures must be inspected
  before catalog kind/version changes. New kind must persist and reject unknown
  kinds; old bitmap catalogs remain readable. Record migration behavior.
- Preserve earlier uncommitted bitmap/storage work. No subagents; heavy builds
  serial. No performance claim, no unsolicited package or configuration layer.

## Completion evidence checklist

- [x] Original-source generator, frozen cases, lock/provenance/licenses.
- [x] Native paged target plus lazy persistent codec and corruption checks.
- [x] Eq/range/IN/IS NULL source parity across all supported scalar types.
- [x] Catalog kind/schema migration and old-format compatibility.
- [x] Native/Python/HTTP creation, listing, dropping and rebuilding.
- [x] Prepared JSON/Arrow dispatch with residual guards and snapshot ownership.
- [x] Restart, failed publication, corruption/torn data and recovery tests.
- [x] Relevant native/Python regression, build, documentation and final audit.
