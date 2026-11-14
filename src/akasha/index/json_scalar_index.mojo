"""One concrete scalar target behind the root-owned JSON artifact lifecycle."""
from std.utils import Variant
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.index.lance_json_btree import LanceJsonBTreeIndex
from akasha.index.lance_bitmap import LanceBitmapQuery
from akasha.index.nullable_rows import NullableRowMask
from akasha.query.control import QueryControl


struct JsonScalarIndex(Copyable, Movable):
    var _data: Variant[LanceJsonBitmapIndex, LanceJsonBTreeIndex]

    def __init__(out self, var index: LanceJsonBitmapIndex):
        self._data = Variant[LanceJsonBitmapIndex, LanceJsonBTreeIndex](index^)

    def __init__(out self, var index: LanceJsonBTreeIndex):
        self._data = Variant[LanceJsonBitmapIndex, LanceJsonBTreeIndex](index^)

    def kind(self) -> UInt8:
        return 1 if self._data.isa[LanceJsonBitmapIndex]() else 2

    def target(self) -> UInt8:
        if self.kind() == 1:
            return self._data[LanceJsonBitmapIndex].target()
        return self._data[LanceJsonBTreeIndex].target()

    def try_search(self, function: String, argument: Optional[String], query: LanceBitmapQuery,
                   *, control: Optional[QueryControl] = None) raises -> Optional[NullableRowMask]:
        if self.kind() == 1:
            return self._data[LanceJsonBitmapIndex].try_search(function, argument, query, control=control.copy())
        return self._data[LanceJsonBTreeIndex].try_search(function, argument, query, control=control.copy())
