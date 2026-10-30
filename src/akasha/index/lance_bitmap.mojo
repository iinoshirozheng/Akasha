"""Lance bitmap scalar target: materialized search, run merge and row remap.

Ported from lance-index scalar/bitmap.rs, scalar/btree.rs and index-core
OldIndexDataFilter (The Lance Authors, Apache-2.0). Sorted native keys replace
the source BTreeMap; postings use the source-ported RoaringRowSet. File storage,
cache, shard merging and planner/catalog integration are separate layers.
"""
from std.sys import size_of
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.roaring_rows import RoaringRowSet
from akasha.index.nullable_rows import NullableRowSet
from akasha.query.control import QueryControl


@fieldwise_init
struct LanceBitmapRow(Copyable, Movable):
    var key: LanceScalarKey
    var id: UInt64


@fieldwise_init
struct _OrderedRow(Comparable, Copyable, Movable):
    var row: LanceBitmapRow

    def __lt__(self, other: Self) -> Bool:
        return self.row.key._compare_same(other.row.key) < 0

    def __gt__(self, other: Self) -> Bool:
        return self.row.key._compare_same(other.row.key) > 0

    def __eq__(self, other: Self) -> Bool:
        return self.row.key._compare_same(other.row.key) == 0

    def __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    def __le__(self, other: Self) -> Bool:
        return not self.__gt__(other)

    def __ge__(self, other: Self) -> Bool:
        return not self.__lt__(other)


struct LanceBitmapBound(Copyable, Movable):
    var key: Optional[LanceScalarKey]
    var included: Bool

    def __init__(out self, var key: Optional[LanceScalarKey] = None, included: Bool = True):
        self.key = key^
        self.included = included


struct LanceBitmapQuery(Copyable, Movable):
    var kind: UInt8  # 0 equals, 1 range, 2 is-in, 3 is-null, 4 text, 5 prefix
    var values: List[LanceScalarKey]
    var lower: LanceBitmapBound
    var upper: LanceBitmapBound

    def __init__(out self):
        self.kind = 3
        self.values = List[LanceScalarKey]()
        self.lower = LanceBitmapBound()
        self.upper = LanceBitmapBound()

    @staticmethod
    def equals(var key: LanceScalarKey) -> Self:
        var result = Self()
        result.kind = 0
        result.values.append(key^)
        return result^

    @staticmethod
    def is_in(var values: List[LanceScalarKey]) -> Self:
        var result = Self()
        result.kind = 2
        result.values = values^
        return result^

    @staticmethod
    def range_of(var lower: LanceBitmapBound, var upper: LanceBitmapBound) -> Self:
        var result = Self()
        result.kind = 1
        result.lower = lower^
        result.upper = upper^
        return result^

    @staticmethod
    def is_null() -> Self:
        return Self()

    @staticmethod
    def full_text() -> Self:
        var result = Self()
        result.kind = 4
        return result^

    @staticmethod
    def like_prefix(var key: LanceScalarKey) -> Self:
        var result = Self.equals(key^)
        result.kind = 5
        return result^


struct LanceOldRows(Copyable, Movable):
    var _ids: RoaringRowSet
    var _fragments: Bool

    def __init__(out self, values: List[UInt64], *, fragments: Bool = False) raises:
        self._ids = RoaringRowSet()
        self._fragments = fragments
        if len(values) > self._ids.max_values:
            raise Error("old-row filter value limit exceeded")
        for value in values:
            if fragments and value > UInt64(UInt32.MAX):
                raise Error("fragment ID exceeds UInt32")
            _ = self._ids.insert(value)

    def retain(self, rows: RoaringRowSet, control: Optional[QueryControl]) raises -> RoaringRowSet:
        if not self._fragments:
            return rows.intersection(self._ids, control=control.copy())
        var result = RoaringRowSet(max_values=rows.max_values, max_bytes=rows.max_bytes)
        for id in rows.values(max_bytes=rows.max_bytes, control=control.copy()):
            if control:
                control.value().checkpoint(0)
            if self._ids.contains(id >> 32):
                _ = result.insert(id)
        return result^


struct LanceBitmapIndex(Copyable, Movable):
    """Owned bounded target; updates return a new index, preserving old readers.

    max_rows bounds input rows, key count and sum of posting cardinalities.
    max_bytes bounds logical retained state and input copy separately, excluding
    capacity/allocator overhead. Operations can also hold old state, a sort
    buffer and temporary posting sets; this is not a peak RSS limit.
    """
    var target: UInt8
    var max_rows: Int
    var max_bytes: Int
    var _keys: List[LanceScalarKey]
    var _postings: List[RoaringRowSet]
    var _nulls: RoaringRowSet
    var _rows: Int
    var _bytes: Int

    def __init__(out self, target: UInt8, *, max_rows: Int = 1_000_000,
                 max_bytes: Int = 64 * 1024 * 1024) raises:
        _ = LanceScalarKey.null(target)
        if max_rows <= 0 or max_bytes <= 0:
            raise Error("bitmap index limits must be positive")
        self.target = target
        self.max_rows = max_rows
        self.max_bytes = max_bytes
        self._keys = List[LanceScalarKey]()
        self._postings = List[RoaringRowSet]()
        self._nulls = RoaringRowSet(max_values=max_rows, max_bytes=max_bytes)
        self._rows = 0
        self._bytes = 0

    def _empty_set(self) raises -> RoaringRowSet:
        return RoaringRowSet(max_values=self.max_rows, max_bytes=self.max_bytes)

    def _check(self, count: Int, bytes: Int) raises:
        if count < 0 or count > self.max_rows:
            raise Error("bitmap index row limit exceeded")
        if bytes < 0 or bytes > self.max_bytes:
            raise Error("bitmap index byte limit exceeded")

    def _input(self, rows: List[LanceBitmapRow], control: Optional[QueryControl]) raises -> Int:
        self._check(len(rows), len(rows) * size_of[_OrderedRow]())
        if control:
            control.value().validate_candidate_count(len(rows))
            control.value().checkpoint(0)
        var bytes = len(rows) * size_of[_OrderedRow]()
        for i in range(len(rows)):
            if control:
                control.value().checkpoint(i)
            rows[i].key.validate(self.target)
            bytes += len(rows[i].key._bytes)
            self._check(len(rows), bytes)
        return bytes

    @staticmethod
    def build(target: UInt8, rows: List[LanceBitmapRow], *, max_rows: Int = 1_000_000,
              max_bytes: Int = 64 * 1024 * 1024,
              control: Optional[QueryControl] = None) raises -> Self:
        var empty = Self(target, max_rows=max_rows, max_bytes=max_bytes)
        return empty.updated(rows, control=control.copy())

    def updated(self, rows: List[LanceBitmapRow], *,
                old_filter: Optional[LanceOldRows] = None,
                control: Optional[QueryControl] = None) raises -> Self:
        _ = self._input(rows, control)
        var ordered = List[_OrderedRow](capacity=len(rows))
        for i in range(len(rows)):
            if control:
                control.value().checkpoint(i)
            ordered.append(_OrderedRow(rows[i].copy()))
        # Existing Mojo stable merge sort; comparator matches source Arrow ASC,
        # nulls-first ordering. Bounds checked before this non-cancellable sort.
        sort[stable=True](Span(ordered))
        if control:
            control.value().checkpoint(0)
        var sorted_rows = List[LanceBitmapRow](capacity=len(rows))
        for i in range(len(ordered)):
            if control:
                control.value().checkpoint(i)
            sorted_rows.append(ordered[i].row.copy())
        ordered.clear()
        return self.merge_sorted([sorted_rows^], old_filter=old_filter.copy(), control=control.copy())

    def _retained(self, rows: RoaringRowSet, old_filter: Optional[LanceOldRows],
                  control: Optional[QueryControl]) raises -> RoaringRowSet:
        if old_filter:
            return old_filter.value().retain(rows, control)
        return rows.copy()

    def _emit(mut self, key: LanceScalarKey, var rows: RoaringRowSet) raises:
        var bytes = rows._bytes
        if not key.is_null:
            bytes += size_of[LanceScalarKey]() + size_of[RoaringRowSet]() + len(key._bytes)
            self._check(len(self._keys) + 1, self._bytes + bytes)
        self._check(self._rows + rows.count(), self._bytes + bytes)
        self._rows += rows.count()
        self._bytes += bytes
        if key.is_null:
            self._nulls = rows^
        else:
            self._keys.append(key.copy())
            self._postings.append(rows^)

    def _finish_run(self, key: LanceScalarKey, var rows: RoaringRowSet,
                    mut old_pos: Int, mut emitted_null: Bool, mut result: Self,
                    old_filter: Optional[LanceOldRows], control: Optional[QueryControl]) raises:
        if key.is_null:
            if not self._nulls.is_empty():
                rows = rows.union_with(self._retained(self._nulls, old_filter, control), control=control.copy())
            emitted_null = True
        else:
            while old_pos < len(self._keys) and self._keys[old_pos]._compare_same(key) < 0:
                if control:
                    control.value().checkpoint(0)
                result._emit(self._keys[old_pos], self._retained(self._postings[old_pos], old_filter, control))
                old_pos += 1
            if old_pos < len(self._keys) and self._keys[old_pos]._compare_same(key) == 0:
                rows = rows.union_with(self._retained(self._postings[old_pos], old_filter, control), control=control.copy())
                old_pos += 1
        result._emit(key, rows^)

    def merge_sorted(self, batches: List[List[LanceBitmapRow]], *,
                     old_filter: Optional[LanceOldRows] = None,
                     control: Optional[QueryControl] = None) raises -> Self:
        if control:
            control.value().validate_candidate_count(self._rows)
            control.value().checkpoint(0)
        self._check(len(batches), 0)
        var count = 0
        var bytes = 0
        for batch in batches:
            count += len(batch)
            bytes += self._input(batch, control)
            self._check(count, bytes)
        if control:
            control.value().validate_candidate_count(count)
        var result = Self(self.target, max_rows=self.max_rows, max_bytes=self.max_bytes)
        var current = Optional[LanceScalarKey]()
        var rows = self._empty_set()
        var old_pos = 0
        var emitted_null = False
        var ordinal = 0
        for batch in batches:
            for entry in batch:
                if control:
                    control.value().checkpoint(ordinal)
                ordinal += 1
                var comparison = current.value()._compare_same(entry.key) if current else -1
                if comparison > 0:
                    raise Error("bitmap input must be sorted by value with nulls first")
                if not current or comparison != 0:
                    if current:
                        self._finish_run(current.value(), rows^, old_pos, emitted_null, result, old_filter, control)
                    current = Optional(entry.key.copy())
                    rows = self._empty_set()
                _ = rows.insert(entry.id)
        if current:
            self._finish_run(current.value(), rows^, old_pos, emitted_null, result, old_filter, control)
        while old_pos < len(self._keys):
            if control:
                control.value().checkpoint(0)
            result._emit(self._keys[old_pos], self._retained(self._postings[old_pos], old_filter, control))
            old_pos += 1
        if not emitted_null and not self._nulls.is_empty():
            result._emit(LanceScalarKey.null(self.target), self._retained(self._nulls, old_filter, control))
        return result^

    def keys(self) -> List[LanceScalarKey]:
        return self._keys.copy()

    def null_rows(self) -> RoaringRowSet:
        return self._nulls.copy()

    def _lower(self, key: LanceScalarKey, *, after: Bool = False) -> Int:
        var low = 0
        var high = len(self._keys)
        while low < high:
            var middle = low + (high - low) // 2
            var comparison = self._keys[middle]._compare_same(key)
            if comparison < 0 or (after and comparison == 0):
                low = middle + 1
            else:
                high = middle
        return low

    def lookup(self, key: LanceScalarKey) raises -> RoaringRowSet:
        key.validate(self.target)
        if key.is_null:
            return self._nulls.copy()
        var at = self._lower(key)
        if at < len(self._keys) and self._keys[at]._compare_same(key) == 0:
            return self._postings[at].copy()
        return self._empty_set()

    def search(self, query: LanceBitmapQuery, *, track_nulls: Bool = True,
               control: Optional[QueryControl] = None) raises -> NullableRowSet:
        if control:
            control.value().validate_candidate_count(self._rows)
            control.value().validate_candidate_count(len(query.values))
            control.value().checkpoint(0)
        if query.kind == 4:
            raise Error("full text search is not supported for bitmap indexes")
        if query.kind == 5:
            raise Error("LIKE prefix queries are not supported for bitmap indexes")
        self._check(len(query.values), len(query.values) * size_of[LanceScalarKey]())
        var query_bytes = len(query.values) * size_of[LanceScalarKey]()
        for i in range(len(query.values)):
            if control:
                control.value().checkpoint(i)
            query.values[i].validate(self.target)
            query_bytes += len(query.values[i]._bytes)
            self._check(len(query.values), query_bytes)
        if query.lower.key:
            query.lower.key.value().validate(self.target)
            query_bytes += len(query.lower.key.value()._bytes)
        if query.upper.key:
            query.upper.key.value().validate(self.target)
            query_bytes += len(query.upper.key.value()._bytes)
        self._check(len(query.values), query_bytes)
        var rows = self._empty_set()
        var nulls = self._empty_set()
        var query_for_null = query.kind == 3
        if query.kind == 0:
            if len(query.values) != 1:
                raise Error("bitmap equality requires one value")
            query_for_null = query.values[0].is_null
            rows = self.lookup(query.values[0])
        elif query.kind == 1:
            var low = 0
            var high = len(self._keys)
            if query.lower.key:
                low = self._lower(query.lower.key.value(), after=not query.lower.included)
            if query.upper.key:
                high = self._lower(query.upper.key.value(), after=query.upper.included)
            for i in range(low, high):
                rows = rows.union_with(self._postings[i], control=control.copy())
        elif query.kind == 2:
            for i in range(len(query.values)):
                if control:
                    control.value().checkpoint(i)
                query_for_null = query_for_null or query.values[i].is_null
                rows = rows.union_with(self.lookup(query.values[i]), control=control.copy())
        elif query.kind == 3:
            rows = self._nulls.copy()
        else:
            raise Error("unsupported bitmap query")
        if track_nulls and not query_for_null:
            nulls = self._nulls.copy()
        return NullableRowSet(rows^, nulls^)

    def remapped(self, mapping: Dict[UInt64, Optional[UInt64]], *,
                 control: Optional[QueryControl] = None) raises -> Self:
        self._check(len(mapping), len(mapping) * (size_of[UInt64]() + size_of[Optional[UInt64]]()))
        if control:
            control.value().validate_candidate_count(self._rows)
            control.value().checkpoint(0)
        var result = Self(self.target, max_rows=self.max_rows, max_bytes=self.max_bytes)
        for i in range(len(self._keys) + 1):
            var key = LanceScalarKey.null(self.target) if i == len(self._keys) else self._keys[i].copy()
            var input = self._nulls.copy() if key.is_null else self._postings[i].copy()
            var rows = self._empty_set()
            var ordinal = 0
            for id in input.values(max_bytes=self.max_bytes, control=control.copy()):
                if control:
                    control.value().checkpoint(ordinal)
                ordinal += 1
                var mapped = mapping[id].copy() if id in mapping else Optional(id)
                if mapped:
                    _ = rows.insert(mapped.value())
            result._emit(key, rows^)
        return result^
