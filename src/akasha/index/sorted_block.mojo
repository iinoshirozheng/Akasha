from akasha.document.value import PayloadValue
from akasha.index.bitmap import Bitmap
from akasha.query.filter_ast import FilterCondition


struct _IntEntry(Movable):
    var name: String
    var value: Int64
    var ordinal: Int

    def __init__(out self, name: String, value: Int64, ordinal: Int):
        self.name = String(copy=name)
        self.value = value
        self.ordinal = ordinal


struct _FloatEntry(Movable):
    var name: String
    var value: Float64
    var ordinal: Int

    def __init__(out self, name: String, value: Float64, ordinal: Int):
        self.name = String(copy=name)
        self.value = value
        self.ordinal = ordinal


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
        _sort_int_entries(self._integers)
        _sort_float_entries(self._floats)
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
        if not self._bulk_loading:
            for index in range(len(self._integers)):
                if (
                    self._integers[index].name == name
                    and self._integers[index].value == value
                    and self._integers[index].ordinal == ordinal
                ):
                    return
        self._integers.append(_IntEntry(name, value, ordinal))
        if self._bulk_loading:
            return
        var cursor = len(self._integers) - 1
        while cursor > 0 and _int_after(
            self._integers[cursor - 1], self._integers[cursor]
        ):
            self._integers.swap_elements(cursor - 1, cursor)
            cursor -= 1

    def _add_float(mut self, name: String, value: Float64, ordinal: Int):
        if not self._bulk_loading:
            for index in range(len(self._floats)):
                if (
                    self._floats[index].name == name
                    and self._floats[index].value == value
                    and self._floats[index].ordinal == ordinal
                ):
                    return
        self._floats.append(_FloatEntry(name, value, ordinal))
        if self._bulk_loading:
            return
        var cursor = len(self._floats) - 1
        while cursor > 0 and _float_after(
            self._floats[cursor - 1], self._floats[cursor]
        ):
            self._floats.swap_elements(cursor - 1, cursor)
            cursor -= 1

    def _remove_int(mut self, name: String, value: Int64, ordinal: Int):
        for index in range(len(self._integers)):
            if (
                self._integers[index].name == name
                and self._integers[index].value == value
                and self._integers[index].ordinal == ordinal
            ):
                var cursor = index
                while cursor + 1 < len(self._integers):
                    self._integers.swap_elements(cursor, cursor + 1)
                    cursor += 1
                _ = self._integers.pop()
                return

    def _remove_float(mut self, name: String, value: Float64, ordinal: Int):
        for index in range(len(self._floats)):
            if (
                self._floats[index].name == name
                and self._floats[index].value == value
                and self._floats[index].ordinal == ordinal
            ):
                var cursor = index
                while cursor + 1 < len(self._floats):
                    self._floats.swap_elements(cursor, cursor + 1)
                    cursor += 1
                _ = self._floats.pop()
                return

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


def _sort_int_entries(mut entries: List[_IntEntry]):
    var start = len(entries) // 2
    while start > 0:
        start -= 1
        _sift_int(entries, start, len(entries))
    var end = len(entries)
    while end > 1:
        end -= 1
        entries.swap_elements(0, end)
        _sift_int(entries, 0, end)


def _sift_int(mut entries: List[_IntEntry], root: Int, end: Int):
    var current = root
    while current * 2 + 1 < end:
        var child = current * 2 + 1
        if child + 1 < end and _int_after(entries[child + 1], entries[child]):
            child += 1
        if not _int_after(entries[child], entries[current]):
            return
        entries.swap_elements(current, child)
        current = child


def _sort_float_entries(mut entries: List[_FloatEntry]):
    var start = len(entries) // 2
    while start > 0:
        start -= 1
        _sift_float(entries, start, len(entries))
    var end = len(entries)
    while end > 1:
        end -= 1
        entries.swap_elements(0, end)
        _sift_float(entries, 0, end)


def _sift_float(mut entries: List[_FloatEntry], root: Int, end: Int):
    var current = root
    while current * 2 + 1 < end:
        var child = current * 2 + 1
        if child + 1 < end and _float_after(entries[child + 1], entries[child]):
            child += 1
        if not _float_after(entries[child], entries[current]):
            return
        entries.swap_elements(current, child)
        current = child
