from akasha.document.value import PayloadValue
from akasha.index.bitmap import Bitmap
from akasha.index.sorted_postings import insert_posting, remove_posting
from akasha.query.filter_ast import FilterCondition


struct _IntEntry(Comparable, Copyable, Movable):
    var name: String
    var value: Int64
    var ordinal: Int

    def __init__(out self, name: String, value: Int64, ordinal: Int):
        self.name = String(copy=name)
        self.value = value
        self.ordinal = ordinal

    def __lt__(self, other: Self) -> Bool:
        return _int_after(other, self)

    def __gt__(self, other: Self) -> Bool:
        return _int_after(self, other)

    def __eq__(self, other: Self) -> Bool:
        return not (_int_after(self, other) or _int_after(other, self))

    def __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    def __le__(self, other: Self) -> Bool:
        return not _int_after(self, other)

    def __ge__(self, other: Self) -> Bool:
        return not _int_after(other, self)


struct _FloatEntry(Comparable, Copyable, Movable):
    var name: String
    var value: Float64
    var ordinal: Int

    def __init__(out self, name: String, value: Float64, ordinal: Int):
        self.name = String(copy=name)
        self.value = value
        self.ordinal = ordinal

    def __lt__(self, other: Self) -> Bool:
        return _float_after(other, self)

    def __gt__(self, other: Self) -> Bool:
        return _float_after(self, other)

    def __eq__(self, other: Self) -> Bool:
        return not (_float_after(self, other) or _float_after(other, self))

    def __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    def __le__(self, other: Self) -> Bool:
        return not _float_after(self, other)

    def __ge__(self, other: Self) -> Bool:
        return not _float_after(other, self)


struct SortedBlockIndex:
    """Sorted typed entries for Int64 and Float64 metadata predicates."""

    var _size: Int
    var _integers: List[_IntEntry]
    var _floats: List[_FloatEntry]
    var _bulk_loading: Bool

    def __init__(out self, size: Int = 0) raises:
        if size < 0:
            raise Error("sorted block index size cannot be negative")
        self._size = size
        self._integers = List[_IntEntry]()
        self._floats = List[_FloatEntry]()
        self._bulk_loading = False

    def size(self) -> Int:
        return self._size

    def resize(mut self, size: Int) raises:
        if size < self._size:
            raise Error("sorted block index resize cannot shrink")
        self._size = size

    def begin_bulk(mut self) raises:
        if (
            self._bulk_loading
            or len(self._integers) != 0
            or len(self._floats) != 0
        ):
            raise Error("sorted block bulk load requires an empty index")
        self._bulk_loading = True

    def finish_bulk(mut self) raises:
        if not self._bulk_loading:
            raise Error("sorted block bulk load is not active")
        # Bound sorting work with the official merge sort. Each call moves
        # entries through temporary descriptors; field strings are not copied.
        # Integer and float buffers are allocated and released sequentially.
        sort[stable=True](Span(self._integers))
        sort[stable=True](Span(self._floats))
        self._bulk_loading = False

    def add(mut self, name: String, value: PayloadValue, ordinal: Int) raises:
        self._validate_ordinal(ordinal)
        if value.is_integer():
            self._add_int(name, value.as_int(), ordinal)
            return
        if value.is_floating():
            self._add_float(name, value.as_float(), ordinal)
            return
        raise Error("sorted block index requires Int64 or Float64 values")

    def remove(
        mut self, name: String, value: PayloadValue, ordinal: Int
    ) raises:
        self._validate_ordinal(ordinal)
        if value.is_integer():
            self._remove_int(name, value.as_int(), ordinal)
            return
        if value.is_floating():
            self._remove_float(name, value.as_float(), ordinal)
            return
        raise Error("sorted block index requires Int64 or Float64 values")

    def evaluate(self, condition: FilterCondition) raises -> Bitmap:
        condition.validate()
        if self._bulk_loading:
            raise Error("sorted block bulk load must finish before queries")
        if condition.value.is_integer():
            return self._evaluate_int(condition)
        if condition.value.is_floating():
            return self._evaluate_float(condition)
        raise Error("sorted block index requires Int64 or Float64 values")

    def _add_int(mut self, name: String, value: Int64, ordinal: Int):
        insert_posting(
            self._integers, _IntEntry(name, value, ordinal), self._bulk_loading
        )

    def _add_float(mut self, name: String, value: Float64, ordinal: Int):
        insert_posting(
            self._floats, _FloatEntry(name, value, ordinal), self._bulk_loading
        )

    def _remove_int(mut self, name: String, value: Int64, ordinal: Int):
        remove_posting(
            self._integers, _IntEntry(name, value, ordinal), self._bulk_loading
        )

    def _remove_float(mut self, name: String, value: Float64, ordinal: Int):
        remove_posting(
            self._floats, _FloatEntry(name, value, ordinal), self._bulk_loading
        )

    def _evaluate_int(self, condition: FilterCondition) raises -> Bitmap:
        var result = Bitmap(self._size)
        var value = condition.value.as_int()
        var start = _int_field_start(self._integers, condition.name)
        var end = _int_field_end(self._integers, condition.name, start)
        var lower = _int_lower_bound(self._integers, value, start, end)
        var upper = _int_upper_bound(self._integers, value, lower, end)
        var first = start
        var last = end
        var operator_kind = condition.operator_kind()
        if operator_kind == FilterCondition.EQUAL:
            first = lower
            last = upper
        elif operator_kind == FilterCondition.LESS_THAN:
            last = lower
        elif operator_kind == FilterCondition.LESS_OR_EQUAL:
            last = upper
        elif operator_kind == FilterCondition.GREATER_THAN:
            first = upper
        elif operator_kind == FilterCondition.GREATER_OR_EQUAL:
            first = lower
        if operator_kind == FilterCondition.NOT_EQUAL:
            for index in range(start, lower):
                result.set(self._integers[index].ordinal)
            first = upper
        for index in range(first, last):
            result.set(self._integers[index].ordinal)
        return result^

    def _evaluate_float(self, condition: FilterCondition) raises -> Bitmap:
        var result = Bitmap(self._size)
        var value = condition.value.as_float()
        var start = _float_field_start(self._floats, condition.name)
        var end = _float_field_end(self._floats, condition.name, start)
        var lower = _float_lower_bound(self._floats, value, start, end)
        var upper = _float_upper_bound(self._floats, value, lower, end)
        var first = start
        var last = end
        var operator_kind = condition.operator_kind()
        if operator_kind == FilterCondition.EQUAL:
            first = lower
            last = upper
        elif operator_kind == FilterCondition.LESS_THAN:
            last = lower
        elif operator_kind == FilterCondition.LESS_OR_EQUAL:
            last = upper
        elif operator_kind == FilterCondition.GREATER_THAN:
            first = upper
        elif operator_kind == FilterCondition.GREATER_OR_EQUAL:
            first = lower
        if operator_kind == FilterCondition.NOT_EQUAL:
            for index in range(start, lower):
                result.set(self._floats[index].ordinal)
            first = upper
        for index in range(first, last):
            result.set(self._floats[index].ordinal)
        return result^

    def _validate_ordinal(self, ordinal: Int) raises:
        if ordinal < 0 or ordinal >= self._size:
            raise Error("sorted block ordinal out of bounds")


def _int_after(left: _IntEntry, right: _IntEntry) -> Bool:
    if left.name != right.name:
        return left.name > right.name
    if left.value != right.value:
        return left.value > right.value
    return left.ordinal > right.ordinal


def _float_after(left: _FloatEntry, right: _FloatEntry) -> Bool:
    if left.name != right.name:
        return left.name > right.name
    if left.value != right.value:
        return left.value > right.value
    return left.ordinal > right.ordinal


def _int_field_start(entries: List[_IntEntry], name: String) -> Int:
    var low = 0
    var high = len(entries)
    while low < high:
        var middle = (low + high) // 2
        if entries[middle].name < name:
            low = middle + 1
        else:
            high = middle
    return low


def _int_field_end(entries: List[_IntEntry], name: String, start: Int) -> Int:
    var low = start
    var high = len(entries)
    while low < high:
        var middle = (low + high) // 2
        if entries[middle].name <= name:
            low = middle + 1
        else:
            high = middle
    return low


def _int_lower_bound(
    entries: List[_IntEntry], value: Int64, start: Int, end: Int
) -> Int:
    var low = start
    var high = end
    while low < high:
        var middle = (low + high) // 2
        if entries[middle].value < value:
            low = middle + 1
        else:
            high = middle
    return low


def _int_upper_bound(
    entries: List[_IntEntry], value: Int64, start: Int, end: Int
) -> Int:
    var low = start
    var high = end
    while low < high:
        var middle = (low + high) // 2
        if entries[middle].value <= value:
            low = middle + 1
        else:
            high = middle
    return low


def _float_field_start(entries: List[_FloatEntry], name: String) -> Int:
    var low = 0
    var high = len(entries)
    while low < high:
        var middle = (low + high) // 2
        if entries[middle].name < name:
            low = middle + 1
        else:
            high = middle
    return low


def _float_field_end(
    entries: List[_FloatEntry], name: String, start: Int
) -> Int:
    var low = start
    var high = len(entries)
    while low < high:
        var middle = (low + high) // 2
        if entries[middle].name <= name:
            low = middle + 1
        else:
            high = middle
    return low


def _float_lower_bound(
    entries: List[_FloatEntry], value: Float64, start: Int, end: Int
) -> Int:
    var low = start
    var high = end
    while low < high:
        var middle = (low + high) // 2
        if entries[middle].value < value:
            low = middle + 1
        else:
            high = middle
    return low


def _float_upper_bound(
    entries: List[_FloatEntry], value: Float64, start: Int, end: Int
) -> Int:
    var low = start
    var high = end
    while low < high:
        var middle = (low + high) // 2
        if entries[middle].value <= value:
            low = middle + 1
        else:
            high = middle
    return low
