from akasha.document.value import PayloadValue
from akasha.index.bitmap import Bitmap
from akasha.query.filter_ast import FilterCondition


struct _KeywordPosting(Movable):
    var name: String
    var value: PayloadValue
    var ordinals: Bitmap

    def __init__(
        out self, name: String, var value: PayloadValue, var ordinals: Bitmap
    ):
        self.name = String(copy=name)
        self.value = value^
        self.ordinals = ordinals^


struct KeywordIndex:
    """Bitmap postings for strict String and Bool equality predicates."""

    var _size: Int
    var _postings: List[_KeywordPosting]

    def __init__(out self, size: Int = 0) raises:
        if size < 0:
            raise Error("keyword index size cannot be negative")
        self._size = size
        self._postings = List[_KeywordPosting]()

    def size(self) -> Int:
        return self._size

    def resize(mut self, size: Int) raises:
        if size < self._size:
            raise Error("keyword index resize cannot shrink")
        for index in range(len(self._postings)):
            self._postings[index].ordinals.resize(size)
        self._size = size

    def add(mut self, name: String, value: PayloadValue, ordinal: Int) raises:
        self._validate_value(value)
        self._validate_ordinal(ordinal)
        for index in range(len(self._postings)):
            if self._same_key(self._postings[index], name, value):
                self._postings[index].ordinals.set(ordinal)
                return

        var ordinals = Bitmap(self._size)
        ordinals.set(ordinal)
        self._postings.append(_KeywordPosting(name, value.clone(), ordinals^))
        var cursor = len(self._postings) - 1
        while cursor > 0 and self._posting_after(
            self._postings[cursor - 1], self._postings[cursor]
        ):
            self._postings.swap_elements(cursor - 1, cursor)
            cursor -= 1

    def remove(
        mut self, name: String, value: PayloadValue, ordinal: Int
    ) raises:
        self._validate_value(value)
        self._validate_ordinal(ordinal)
        for index in range(len(self._postings)):
            if self._same_key(self._postings[index], name, value):
                self._postings[index].ordinals.clear(ordinal)
                return

    def evaluate(self, condition: FilterCondition) raises -> Bitmap:
        condition.validate()
        self._validate_value(condition.value)
        var result = Bitmap(self._size)
        var operator_kind = condition.operator_kind()
        for index in range(len(self._postings)):
            if (
                self._postings[index].name != condition.name
                or self._postings[index].value.kind() != condition.value.kind()
            ):
                continue
            var equal = self._same_value(
                self._postings[index].value, condition.value
            )
            if (operator_kind == FilterCondition.EQUAL and equal) or (
                operator_kind == FilterCondition.NOT_EQUAL and not equal
            ):
                result = result.union_with(self._postings[index].ordinals)
        return result^

    def _validate_value(self, value: PayloadValue) raises:
        if not (value.is_string() or value.is_boolean()):
            raise Error("keyword index requires String or Bool values")

    def _validate_ordinal(self, ordinal: Int) raises:
        if ordinal < 0 or ordinal >= self._size:
            raise Error("keyword index ordinal out of bounds")

    def _same_key(
        self, posting: _KeywordPosting, name: String, value: PayloadValue
    ) raises -> Bool:
        return posting.name == name and self._same_value(posting.value, value)

    def _same_value(
        self, left: PayloadValue, right: PayloadValue
    ) raises -> Bool:
        if left.kind() != right.kind():
            return False
        if left.is_string():
            return left.as_string() == right.as_string()
        if left.is_boolean():
            return left.as_bool() == right.as_bool()
        return False

    def _posting_after(
        self, left: _KeywordPosting, right: _KeywordPosting
    ) raises -> Bool:
        if left.name != right.name:
            return left.name > right.name
        if left.value.kind() != right.value.kind():
            return left.value.kind() > right.value.kind()
        if left.value.is_string():
            return left.value.as_string() > right.value.as_string()
        return left.value.as_bool() and not right.value.as_bool()
