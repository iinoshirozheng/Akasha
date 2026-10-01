from akasha.document.value import PayloadValue
from akasha.index.bitmap import Bitmap
from akasha.index.sorted_postings import insert_posting, remove_posting
from akasha.query.filter_ast import FilterCondition


struct _KeywordEntry(Comparable, Copyable, Movable):
    var name: String
    var kind: UInt8
    var string_value: String
    var bool_value: Bool
    var ordinal: Int

    def __init__(
        out self, name: String, value: PayloadValue, ordinal: Int
    ) raises:
        self.name = String(copy=name)
        self.kind = value.kind()
        self.string_value = String()
        self.bool_value = False
        self.ordinal = ordinal
        if value.is_string():
            self.string_value = value.as_string()
        elif value.is_boolean():
            self.bool_value = value.as_bool()
        else:
            raise Error("keyword index requires String or Bool values")

    def __lt__(self, other: Self) -> Bool:
        return _keyword_after(other, self)

    def __gt__(self, other: Self) -> Bool:
        return _keyword_after(self, other)

    def __eq__(self, other: Self) -> Bool:
        return not (_keyword_after(self, other) or _keyword_after(other, self))

    def __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    def __le__(self, other: Self) -> Bool:
        return not _keyword_after(self, other)

    def __ge__(self, other: Self) -> Bool:
        return not _keyword_after(other, self)


struct KeywordIndex:
    """Sparse sorted postings for strict String and Bool predicates."""

    var _size: Int
    var _entries: List[_KeywordEntry]
    var _bulk_loading: Bool

    def __init__(out self, size: Int = 0) raises:
        if size < 0:
            raise Error("keyword index size cannot be negative")
        self._size = size
        self._entries = List[_KeywordEntry]()
        self._bulk_loading = False

    def size(self) -> Int:
        return self._size

    def entry_count(self) -> Int:
        return len(self._entries)

    def resize(mut self, size: Int) raises:
        if size < self._size:
            raise Error("keyword index resize cannot shrink")
        self._size = size

    def begin_bulk(mut self) raises:
        if self._bulk_loading or len(self._entries) != 0:
            raise Error("keyword bulk load requires an empty index")
        self._bulk_loading = True

    def finish_bulk(mut self) raises:
        if not self._bulk_loading:
            raise Error("keyword bulk load is not active")
        # Mojo 1.0's stable merge sort moves descriptors without copying strings.
        # It avoids the default quicksort's input-dependent scaling at the cost
        # of one temporary entry buffer (72 bytes/entry on the pinned target).
        sort[stable=True](Span(self._entries))
        self._bulk_loading = False

    def add(mut self, name: String, value: PayloadValue, ordinal: Int) raises:
        self._validate_value(value)
        self._validate_ordinal(ordinal)
        insert_posting(
            self._entries,
            _KeywordEntry(name, value, ordinal),
            self._bulk_loading,
        )

    def remove(
        mut self, name: String, value: PayloadValue, ordinal: Int
    ) raises:
        self._validate_value(value)
        self._validate_ordinal(ordinal)
        remove_posting(
            self._entries,
            _KeywordEntry(name, value, ordinal),
            self._bulk_loading,
        )

    def evaluate(self, condition: FilterCondition) raises -> Bitmap:
        condition.validate()
        self._validate_value(condition.value)
        if self._bulk_loading:
            raise Error("keyword bulk load must finish before queries")
        var result = Bitmap(self._size)
        var start = _keyword_family_start(
            self._entries, condition.name, condition.value.kind()
        )
        var end = _keyword_family_end(
            self._entries, condition.name, condition.value.kind(), start
        )
        if condition.operator_kind() == FilterCondition.NOT_EQUAL:
            for index in range(start, end):
                if not _same_value(self._entries[index], condition.value):
                    result.set(self._entries[index].ordinal)
            return result^

        var lower = _keyword_value_lower(
            self._entries, condition.value, start, end
        )
        var upper = _keyword_value_upper(
            self._entries, condition.value, lower, end
        )
        for index in range(lower, upper):
            result.set(self._entries[index].ordinal)
        return result^

    def _validate_value(self, value: PayloadValue) raises:
        if not (value.is_string() or value.is_boolean()):
            raise Error("keyword index requires String or Bool values")

    def _validate_ordinal(self, ordinal: Int) raises:
        if ordinal < 0 or ordinal >= self._size:
            raise Error("keyword index ordinal out of bounds")


def _same_value(entry: _KeywordEntry, value: PayloadValue) raises -> Bool:
    if entry.kind != value.kind():
        return False
    if value.is_string():
        return entry.string_value == value.as_string()
    return entry.bool_value == value.as_bool()


def _keyword_after(left: _KeywordEntry, right: _KeywordEntry) -> Bool:
    if left.name != right.name:
        return left.name > right.name
    if left.kind != right.kind:
        return left.kind > right.kind
    if left.string_value != right.string_value:
        return left.string_value > right.string_value
    if left.bool_value != right.bool_value:
        return left.bool_value and not right.bool_value
    return left.ordinal > right.ordinal


def _keyword_family_before(
    entry: _KeywordEntry, name: String, kind: UInt8
) -> Bool:
    return entry.name < name or (entry.name == name and entry.kind < kind)


def _keyword_family_after(
    entry: _KeywordEntry, name: String, kind: UInt8
) -> Bool:
    return entry.name > name or (entry.name == name and entry.kind > kind)


def _keyword_family_start(
    entries: List[_KeywordEntry], name: String, kind: UInt8
) -> Int:
    var low = 0
    var high = len(entries)
    while low < high:
        var middle = (low + high) // 2
        if _keyword_family_before(entries[middle], name, kind):
            low = middle + 1
        else:
            high = middle
    return low


def _keyword_family_end(
    entries: List[_KeywordEntry], name: String, kind: UInt8, start: Int
) -> Int:
    var low = start
    var high = len(entries)
    while low < high:
        var middle = (low + high) // 2
        if not _keyword_family_after(entries[middle], name, kind):
            low = middle + 1
        else:
            high = middle
    return low


def _keyword_value_before(
    entry: _KeywordEntry, value: PayloadValue
) raises -> Bool:
    if value.is_string():
        return entry.string_value < value.as_string()
    return not entry.bool_value and value.as_bool()


def _keyword_value_after(
    entry: _KeywordEntry, value: PayloadValue
) raises -> Bool:
    if value.is_string():
        return entry.string_value > value.as_string()
    return entry.bool_value and not value.as_bool()


def _keyword_value_lower(
    entries: List[_KeywordEntry],
    value: PayloadValue,
    start: Int,
    end: Int,
) raises -> Int:
    var low = start
    var high = end
    while low < high:
        var middle = (low + high) // 2
        if _keyword_value_before(entries[middle], value):
            low = middle + 1
        else:
            high = middle
    return low


def _keyword_value_upper(
    entries: List[_KeywordEntry],
    value: PayloadValue,
    start: Int,
    end: Int,
) raises -> Int:
    var low = start
    var high = end
    while low < high:
        var middle = (low + high) // 2
        if not _keyword_value_after(entries[middle], value):
            low = middle + 1
        else:
            high = middle
    return low
