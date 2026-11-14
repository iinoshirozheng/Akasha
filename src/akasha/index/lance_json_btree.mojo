"""JSON extraction and guarded expression substitution for native B-tree pages."""
from akasha.document.jsonb import JsonbValue
from akasha.index.lance_json_stream import LanceJsonBitmapTrainer
from akasha.index.lance_btree import LanceBTreeIndex
from akasha.index.lance_bitmap import LanceBitmapQuery
from akasha.index.lance_json_matcher import json_bitmap_reference_supported, json_bitmap_query_supported
from akasha.index.nullable_rows import NullableRowSet, NullableRowMask
from akasha.storage.btree_pages import stage_btree_pages
from akasha.query.control import QueryControl


@fieldwise_init
struct LanceJsonBTreeIndex(Copyable, Movable):
    var _btree: LanceBTreeIndex

    def target(self) -> UInt8:
        return self._btree.pages.lookup.target

    def search(self, query: LanceBitmapQuery, *, track_nulls: Bool = True,
               control: Optional[QueryControl] = None) raises -> NullableRowSet:
        return self._btree.search(query, track_nulls=track_nulls, control=control.copy())

    def try_search(self, function: String, argument: Optional[String],
                   query: LanceBitmapQuery, *, negated: Bool = False,
                   control: Optional[QueryControl] = None) raises -> Optional[NullableRowMask]:
        if control:
            control.value().checkpoint(0)
        if not json_bitmap_reference_supported(self._btree.pages.path, self.target(), function, argument):
            return None
        if function == "json_get_string" and not self._btree.pages.string_getter_safe:
            return None
        if not json_bitmap_query_supported(self.target(), query):
            return None
        # Raw Lance treats an unbounded leaf range as TRUE even for NULL.
        # The existing JSON expression contract returns UNKNOWN for NULL.
        if query.kind == 1 and not query.lower.key and not query.upper.key:
            return None
        var rows = self.search(query, track_nulls=True, control=control.copy())
        return Optional(NullableRowMask(rows^, negated))


struct LanceJsonBTreeTrainer(Movable):
    var _input: LanceJsonBitmapTrainer

    def __init__(out self, var path: String, *, learned_type: Optional[UInt8] = None,
                 control: Optional[QueryControl] = None,
                 sort_memory_bytes: Int = 8 * 1024 * 1024) raises:
        self._input = LanceJsonBitmapTrainer(path^, learned_type=learned_type,
            control=control.copy(), sort_memory_bytes=Optional(sort_memory_bytes))

    def learned_type(self) -> Optional[UInt8]:
        return self._input.learned_type()

    def push(mut self, values: List[Optional[JsonbValue]], ids: List[UInt64]) raises:
        self._input.push(values, ids)

    def abort(mut self):
        self._input.abort()

    def finish_update(mut self, old: LanceJsonBTreeIndex, sequence: UInt64,
                      source_checksum: UInt32) raises -> LanceJsonBTreeIndex:
        try:
            self._input._check_open()
            if self._input.path != old._btree.pages.path or not self.learned_type() or self.learned_type().value() != old.target():
                raise Error("JSON B-tree update must retain the old path and learned type")
            var sorted = self._input.finish_sorted()
            var updated = old._btree.updated_stream(sorted.stream, sequence=sequence,
                source_checksum=source_checksum, control=self._input._control.copy(),
                string_getter_safe=sorted.string_getter_safe)
            return LanceJsonBTreeIndex(updated^)
        except error:
            self.abort()
            raise error

    def finish(mut self, column: String, dimension: Int, sequence: UInt64,
               source_checksum: UInt32) raises -> LanceJsonBTreeIndex:
        try:
            var sorted = self._input.finish_sorted()
            var pages = stage_btree_pages(sorted.stream, column, sorted.path, sorted.target,
                sorted.string_getter_safe, dimension, sequence, source_checksum, self._input._control)
            return LanceJsonBTreeIndex(LanceBTreeIndex(pages^))
        except error:
            self.abort()
            raise error
