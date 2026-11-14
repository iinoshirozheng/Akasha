"""Native immutable paged B-tree, following Lance page lookup/search dispatch."""
from akasha.index.lance_bitmap import LanceBitmapQuery
from akasha.index.lance_btree_lookup import BTreePageMatch
from akasha.index.lance_btree_predicate import validate_btree_query, search_btree_leaf
from akasha.index.nullable_rows import NullableRowSet
from akasha.index.roaring_rows import RoaringRowSet
from akasha.storage.btree_pages import BTreePages
from akasha.query.control import QueryControl


@fieldwise_init
struct LanceBTreeIndex(Copyable, Movable):
    var pages: BTreePages

    def search(self, query: LanceBitmapQuery, *, track_nulls: Bool = True,
               control: Optional[QueryControl] = None) raises -> NullableRowSet:
        validate_btree_query(query, self.pages.lookup.target, control)
        if control:
            control.value().checkpoint(0)
        var candidates: List[BTreePageMatch]
        if query.kind == 0:
            candidates = self.pages.lookup.pages_eq(query.values[0], control)
        elif query.kind == 1:
            candidates = self.pages.lookup.pages_between(query.lower, query.upper, control)
        elif query.kind == 2:
            candidates = self.pages.lookup.pages_in(query.values, control)
        else:
            candidates = self.pages.lookup.pages_null(control)
        if track_nulls and query.kind != 3:
            var included = List[Bool](length=len(self.pages.locations), fill=False)
            for candidate in candidates:
                included[candidate.page] = True
            for candidate in self.pages.lookup.pages_null(control):
                if not included[candidate.page]:
                    candidates.append(BTreePageMatch(candidate.page, False))
        var row_count = 0
        for candidate in candidates:
            row_count += self.pages.lookup.pages[candidate.page].row_count
        if control:
            control.value().validate_candidate_count(row_count)
        var selected = RoaringRowSet()
        var nulls = RoaringRowSet()
        for candidate in candidates:
            var rows = self.pages.read_page(candidate.page, control)
            var result = search_btree_leaf(rows, self.pages.lookup.target, query,
                track_nulls=track_nulls, all_rows=candidate.all_rows, control=control.copy())
            selected = selected.union_with(result.selected_rows, control=control.copy())
            nulls = nulls.union_with(result.nulls, control=control.copy())
        return NullableRowSet(selected^, nulls^)
