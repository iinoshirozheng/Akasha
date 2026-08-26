struct Bitmap(Movable):
    """An owned dense candidate bitmap with cached cardinality."""

    var _size: Int
    var _count: Int
    var _words: List[UInt64]

    def __init__(out self, size: Int = 0) raises:
        if size < 0:
            raise Error("bitmap size cannot be negative")
        self._size = size
        self._count = 0
        self._words = List[UInt64](length=_word_count(size), fill=UInt64(0))

    @staticmethod
    def full(size: Int) raises -> Bitmap:
        var result = Bitmap(size)
        for index in range(len(result._words)):
            result._words[index] = UInt64.MAX
        result._mask_unused_tail()
        result._count = size
        return result^

    def size(self) -> Int:
        return self._size

    def count(self) -> Int:
        return self._count

    def resize(mut self, size: Int) raises:
        if size < self._size:
            raise Error("bitmap resize cannot shrink")
        var required = _word_count(size)
        while len(self._words) < required:
            self._words.append(UInt64(0))
        self._size = size

    def set(mut self, index: Int) raises:
        self._validate_index(index)
        var word_index = index // 64
        var mask = UInt64(1) << UInt64(index % 64)
        if (self._words[word_index] & mask) == UInt64(0):
            self._words[word_index] |= mask
            self._count += 1

    def clear(mut self, index: Int) raises:
        self._validate_index(index)
        var word_index = index // 64
        var mask = UInt64(1) << UInt64(index % 64)
        if (self._words[word_index] & mask) != UInt64(0):
            self._words[word_index] &= ~mask
            self._count -= 1

    def contains(self, index: Int) raises -> Bool:
        self._validate_index(index)
        var word_index = index // 64
        var mask = UInt64(1) << UInt64(index % 64)
        return (self._words[word_index] & mask) != UInt64(0)

    def clone(self) raises -> Bitmap:
        var result = Bitmap(self._size)
        result._count = self._count
        result._words = self._words.copy()
        return result^

    def set_ordinals(self) -> List[Int]:
        """Return set ordinals in ascending order by scanning bitmap words."""
        var result = List[Int](capacity=self._count)
        for word_index in range(len(self._words)):
            var word = self._words[word_index]
            if word == UInt64(0):
                continue
            for bit in range(64):
                var ordinal = word_index * 64 + bit
                if ordinal >= self._size:
                    break
                var mask = UInt64(1) << UInt64(bit)
                if (word & mask) != UInt64(0):
                    result.append(ordinal)
        return result^

    def intersection(self, other: Bitmap) raises -> Bitmap:
        self._validate_compatible(other)
        var result = Bitmap(self._size)
        for index in range(len(self._words)):
            var word = self._words[index] & other._words[index]
            result._words[index] = word
            result._count += _popcount(word)
        return result^

    def union_with(self, other: Bitmap) raises -> Bitmap:
        self._validate_compatible(other)
        var result = Bitmap(self._size)
        for index in range(len(self._words)):
            var word = self._words[index] | other._words[index]
            result._words[index] = word
        result._mask_unused_tail()
        result._recount_words()
        return result^

    def difference(self, other: Bitmap) raises -> Bitmap:
        self._validate_compatible(other)
        var result = Bitmap(self._size)
        for index in range(len(self._words)):
            var word = self._words[index] & ~other._words[index]
            result._words[index] = word
        result._mask_unused_tail()
        result._recount_words()
        return result^

    def _validate_index(self, index: Int) raises:
        if index < 0 or index >= self._size:
            raise Error("bitmap index out of bounds")

    def _validate_compatible(self, other: Bitmap) raises:
        if self._size != other._size:
            raise Error("bitmap sizes must match")

    def _mask_unused_tail(mut self):
        if self._size == 0 or self._size % 64 == 0:
            return
        var used = self._size % 64
        var mask = (UInt64(1) << UInt64(used)) - UInt64(1)
        self._words[len(self._words) - 1] &= mask

    def _recount_words(mut self):
        self._count = 0
        for word in self._words:
            self._count += _popcount(word)


def _word_count(size: Int) -> Int:
    return (size + 63) // 64


def _popcount(value: UInt64) -> Int:
    var remaining = value
    var count = 0
    while remaining != UInt64(0):
        remaining &= remaining - UInt64(1)
        count += 1
    return count
