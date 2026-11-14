"""Native immutable paged B-tree, following Lance page lookup/search dispatch."""
from akasha.index.lance_bitmap import LanceBitmapQuery, LanceBitmapRow, BitmapRowStream
from akasha.index.bitmap_sort import ExternalBitmapSort
from akasha.index.lance_btree_lookup import BTreePageMatch
from akasha.index.lance_btree_predicate import validate_btree_query, search_btree_leaf
from akasha.index.nullable_rows import NullableRowSet
from akasha.index.roaring_rows import RoaringRowSet
from akasha.storage.btree_pages import BTreePages, stage_btree_pages
from akasha.query.control import QueryControl


struct _BTreeRows[origin: ImmOrigin](BitmapRowStream):
    var rows: Pointer[List[LanceBitmapRow], Self.origin]
    var position: Int

    def __init__(out self, ref[Self.origin] rows: List[LanceBitmapRow]):
        self.rows = Pointer(to=rows)
        self.position = 0

    def next(mut self) raises -> Optional[LanceBitmapRow]:
        if self.position == len(self.rows[]):
            return None
        var row = self.rows[][self.position].copy()
        self.position += 1
        return Optional(row^)


@fieldwise_init
struct _RemappedPages(BitmapRowStream):
    var pages: BTreePages
    var mapping: Dict[UInt64, Optional[UInt64]]
    var control: Optional[QueryControl]
    var page: Int
    var position: Int
    var rows: List[LanceBitmapRow]

    def next(mut self) raises -> Optional[LanceBitmapRow]:
        while True:
            if self.control:
                self.control.value().checkpoint(0)
            if self.position == len(self.rows):
                if self.page == len(self.pages.locations):
                    return None
                self.rows = self.pages.read_page(self.page, self.control)
                self.page += 1
                self.position = 0
            var row = self.rows[self.position].copy()
            self.position += 1
            if row.id in self.mapping:
                if not self.mapping[row.id]:
                    continue
                row.id = self.mapping[row.id].value()
            return Optional(row^)


@fieldwise_init
struct LanceBTreeIndex(Copyable, Movable):
    var pages: BTreePages

    def updated(self, rows: List[LanceBitmapRow], *, sequence: UInt64,
                source_checksum: UInt32, removed: Optional[RoaringRowSet] = None,
                control: Optional[QueryControl] = None,
                sort_memory_bytes: Int = 8 * 1024 * 1024) raises -> Self:
        """Filter old IDs, append new rows, re-sort and stage an immutable artifact.

        Replacement requires explicitly removing the old ID. Duplicate live IDs
        are rejected by the existing page validator. Caller supplies the new
        authoritative source identity; this operation does not publish files.
        """
        var stream = _BTreeRows(rows)
        return self.updated_stream(stream, sequence=sequence, source_checksum=source_checksum,
            removed=removed.copy(), control=control.copy(), sort_memory_bytes=sort_memory_bytes)

    def updated_stream[Stream: BitmapRowStream](self, mut stream: Stream, *,
                sequence: UInt64, source_checksum: UInt32,
                removed: Optional[RoaringRowSet] = None,
                control: Optional[QueryControl] = None,
                sort_memory_bytes: Int = 8 * 1024 * 1024,
                string_getter_safe: Bool = False) raises -> Self:
        var sorter = ExternalBitmapSort(memory_bytes=sort_memory_bytes, control=control.copy())
        for page in range(len(self.pages.locations)):
            for row in self.pages.read_page(page, control):
                if not removed or not removed.value().contains(row.id):
                    sorter.push(row.copy())
        var added = False
        while True:
            var row = stream.next()
            if not row:
                break
            added = True
            sorter.push(row.take())
        sorter.prepare(self.pages.lookup.target)
        return Self(stage_btree_pages(sorter, self.pages.column, self.pages.path,
            self.pages.lookup.target, self.pages.string_getter_safe and (not added or string_getter_safe),
            self.pages.artifact[].dimension, sequence, source_checksum, control))

    def remapped(self, mapping: Dict[UInt64, Optional[UInt64]], *,
                 sequence: UInt64, source_checksum: UInt32,
                 control: Optional[QueryControl] = None) raises -> Self:
        """Missing IDs stay unchanged; None deletes; conflicting live IDs fail."""
        if len(mapping) > 1_000_000:
            raise Error("B-tree remap entry limit exceeded")
        if control:
            control.value().checkpoint(0)
            control.value().validate_candidate_count(self.pages.row_count)
        var stream = _RemappedPages(self.pages.copy(), mapping.copy(), control.copy(),
            0, 0, List[LanceBitmapRow]())
        return Self(stage_btree_pages(stream, self.pages.column, self.pages.path,
            self.pages.lookup.target, self.pages.string_getter_safe,
            self.pages.artifact[].dimension, sequence, source_checksum, control))

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
