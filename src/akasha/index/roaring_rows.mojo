"""Materialized UInt64 row sets from roaring-rs 0.11.4 (Apache-2.0).

Ports point mutation, array/bitmap containers and binary set operations.
The upper UInt32 map uses Mojo Dict; iteration sorts its keys to preserve the
source BTreeMap order. Range/run containers and portable serialization are
separate, not simulated by a dense bitmap over the UInt64 universe.
"""
from std.bit import count_trailing_zeros, pop_count
from std.sys import size_of
from akasha.index.sorted_postings import _lower_bound
from akasha.query.control import QueryControl


struct _Container(Comparable, Copyable, Movable):
    var key: UInt16
    var array: List[UInt16]
    var words: List[UInt64]
    var count: Int

    def __init__(out self, key: UInt16):
        self.key = key
        self.array = List[UInt16]()
        self.words = List[UInt64]()
        self.count = 0

    def __lt__(self, other: Self) -> Bool:
        return self.key < other.key
    def __le__(self, other: Self) -> Bool:
        return self.key <= other.key
    def __gt__(self, other: Self) -> Bool:
        return self.key > other.key
    def __ge__(self, other: Self) -> Bool:
        return self.key >= other.key
    def __eq__(self, other: Self) -> Bool:
        return self.key == other.key
    def __ne__(self, other: Self) -> Bool:
        return self.key != other.key

    def bytes(self) -> Int:
        return size_of[Self]() + (8192 if len(self.words) else self.count * 2)

    def contains(self, value: UInt16) -> Bool:
        if len(self.words):
            return Bool(self.words[Int(value) // 64] & (UInt64(1) << UInt64(value % 64)))
        var position = _lower_bound(self.array, value)
        return position < len(self.array) and self.array[position] == value

    def values(self) -> List[UInt16]:
        if not len(self.words):
            return self.array.copy()
        var result = List[UInt16](capacity=self.count)
        for i in range(1024):
            var word = self.words[i]
            while word:
                result.append(UInt16(i * 64 + Int(count_trailing_zeros(word))))
                word &= word - 1
        return result^

    def to_bitmap(mut self):
        if len(self.words):
            return
        self.words = List[UInt64](length=1024, fill=0)
        for value in self.array:
            self.words[Int(value) // 64] |= UInt64(1) << UInt64(value % 64)
        self.array = List[UInt16]()

    def normalize(mut self):
        # Container::ensure_correct_store; point paths never create Run stores.
        if len(self.words) and self.count <= 4096:
            self.array = self.values()
            self.words = List[UInt64]()
        elif not len(self.words) and self.count > 4096:
            self.to_bitmap()

    def insert(mut self, value: UInt16) -> Bool:
        if len(self.words):
            var index = Int(value) // 64
            var mask = UInt64(1) << UInt64(value % 64)
            if self.words[index] & mask:
                return False
            self.words[index] |= mask
        else:
            var position = _lower_bound(self.array, value)
            if position < len(self.array) and self.array[position] == value:
                return False
            self.array.insert(position, value)
        self.count += 1
        self.normalize()
        return True

    def remove(mut self, value: UInt16) -> Bool:
        if len(self.words):
            var index = Int(value) // 64
            var mask = UInt64(1) << UInt64(value % 64)
            if not (self.words[index] & mask):
                return False
            self.words[index] &= ~mask
        else:
            var position = _lower_bound(self.array, value)
            if position == len(self.array) or self.array[position] != value:
                return False
            _ = self.array.pop(position)
        self.count -= 1
        self.normalize()
        return True

    def combine(self, other: Self, operation: Int) -> Self:
        # 0 union, 1 intersection, 2 left difference, 3 symmetric difference.
        var result = Self(self.key)
        if not len(self.words) and not len(other.words):
            # roaring array_store/scalar.rs merge visitors.
            var i = 0
            var j = 0
            while i < len(self.array) and j < len(other.array):
                var a = self.array[i]
                var b = other.array[j]
                if a < b:
                    if operation != 1:
                        result.array.append(a)
                    i += 1
                elif a > b:
                    if operation == 0 or operation == 3:
                        result.array.append(b)
                    j += 1
                else:
                    if operation == 0 or operation == 1:
                        result.array.append(a)
                    i += 1
                    j += 1
            if operation != 1:
                while i < len(self.array):
                    result.array.append(self.array[i])
                    i += 1
            if operation == 0 or operation == 3:
                while j < len(other.array):
                    result.array.append(other.array[j])
                    j += 1
            result.count = len(result.array)
        elif len(self.words) and len(other.words):
            result.words = List[UInt64](capacity=1024)
            for i in range(1024):
                var a = self.words[i]
                var b = other.words[i]
                var word = a | b if operation == 0 else a & b if operation == 1 else a & ~b if operation == 2 else a ^ b
                result.words.append(word)
                result.count += Int(pop_count(word))
        elif operation == 1 or (operation == 2 and not len(self.words)):
            # Array/bitmap intersection and array-minus-bitmap filter array.
            ref array = self.array if not len(self.words) else other.array
            ref bitmap = other if not len(self.words) else self
            for value in array:
                var present = bitmap.contains(value)
                if (operation == 1 and present) or (operation == 2 and not present):
                    result.array.append(value)
            result.count = len(result.array)
        else:
            # Bitmap OR/XOR array and bitmap-minus-array mutate only its bits.
            result = self.copy() if len(self.words) else other.copy()
            ref array = other.array if len(self.words) else self.array
            for value in array:
                var index = Int(value) // 64
                var mask = UInt64(1) << UInt64(value % 64)
                var old = result.words[index]
                var word = old | mask if operation == 0 else old & ~mask if operation == 2 else old ^ mask
                result.words[index] = word
                result.count += Int(pop_count(word)) - Int(pop_count(old))
        result.normalize()
        return result^


struct _Roaring32(Copyable, Movable):
    var containers: List[_Container]

    def __init__(out self):
        self.containers = List[_Container]()

    def position(self, key: UInt16) -> Int:
        return _lower_bound(self.containers, _Container(key))

    def bytes(self) -> Int:
        var result = size_of[Self]()
        for container in self.containers:
            result += container.bytes()
        return result

    def count(self) -> Int:
        var result = 0
        for container in self.containers:
            result += container.count
        return result

    def contains(self, value: UInt32) -> Bool:
        var key = UInt16(value >> 16)
        var position = self.position(key)
        return position < len(self.containers) and self.containers[position].key == key and self.containers[position].contains(UInt16(value))

    def insertion_bytes(self, value: UInt32) -> Int:
        var key = UInt16(value >> 16)
        var position = self.position(key)
        if position == len(self.containers) or self.containers[position].key != key:
            return size_of[_Container]() + 2
        return 2 if self.containers[position].count < 4096 else 0

    def insert(mut self, value: UInt32) -> Bool:
        var key = UInt16(value >> 16)
        var position = self.position(key)
        if position == len(self.containers) or self.containers[position].key != key:
            self.containers.insert(position, _Container(key))
        return self.containers[position].insert(UInt16(value))

    def remove(mut self, value: UInt32) -> Bool:
        var key = UInt16(value >> 16)
        var position = self.position(key)
        if position == len(self.containers) or self.containers[position].key != key:
            return False
        var removed = self.containers[position].remove(UInt16(value))
        if self.containers[position].count == 0:
            _ = self.containers.pop(position)
        return removed

    def combine(self, other: Self, operation: Int) -> Self:
        # RoaringBitmap ordered container merge; no row-id materialization.
        var result = Self()
        var i = 0
        var j = 0
        while i < len(self.containers) or j < len(other.containers):
            if j == len(other.containers) or (i < len(self.containers) and self.containers[i].key < other.containers[j].key):
                if operation != 1:
                    result.containers.append(self.containers[i].copy())
                i += 1
            elif i == len(self.containers) or other.containers[j].key < self.containers[i].key:
                if operation == 0 or operation == 3:
                    result.containers.append(other.containers[j].copy())
                j += 1
            else:
                var combined = self.containers[i].combine(other.containers[j], operation)
                if combined.count:
                    result.containers.append(combined^)
                i += 1
                j += 1
        return result^


struct RoaringRowSet(Copyable, Movable):
    """Owned materialized UInt64 set; limits apply to logical native state bytes.

    Dict/list capacity and allocator overhead are not a peak-RSS guarantee.
    Operation results use the left operand's limits; failures leave inputs intact.
    """
    var _maps: Dict[UInt32, _Roaring32]
    var _count: Int
    var _bytes: Int
    var max_values: Int
    var max_bytes: Int

    def __init__(out self, *, max_values: Int = 10_000_000,
                 max_bytes: Int = 64 * 1024 * 1024) raises:
        if max_values <= 0 or max_bytes <= 0:
            raise Error("row-set limits must be positive")
        self._maps = Dict[UInt32, _Roaring32]()
        self._count = 0
        self._bytes = 0
        self.max_values = max_values
        self.max_bytes = max_bytes

    def _check(self, count: Int, bytes: Int) raises:
        if count < 0 or count > self.max_values:
            raise Error("row-set value limit exceeded")
        if bytes < 0 or bytes > self.max_bytes:
            raise Error("row-set byte limit exceeded")

    def count(self) -> Int:
        return self._count

    def is_empty(self) -> Bool:
        return self._count == 0

    def contains(self, value: UInt64) raises -> Bool:
        var key = UInt32(value >> 32)
        return key in self._maps and self._maps[key].contains(UInt32(value))

    def insert(mut self, value: UInt64) raises -> Bool:
        if self.contains(value):
            return False
        var key = UInt32(value >> 32)
        var extra = size_of[UInt32]() + size_of[_Roaring32]() + size_of[_Container]() + 2
        if key in self._maps:
            extra = self._maps[key].insertion_bytes(UInt32(value))
        self._check(self._count + 1, self._bytes + extra)
        if key not in self._maps:
            self._maps[key] = _Roaring32()
        _ = self._maps[key].insert(UInt32(value))
        self._count += 1
        self._bytes += extra
        return True

    def remove(mut self, value: UInt64) raises -> Bool:
        var key = UInt32(value >> 32)
        if key not in self._maps:
            return False
        var old_bytes = self._maps[key].bytes()
        if not self._maps[key].remove(UInt32(value)):
            return False
        self._count -= 1
        self._bytes += self._maps[key].bytes() - old_bytes
        if len(self._maps[key].containers) == 0:
            _ = self._maps.pop(key)
            self._bytes -= size_of[UInt32]() + size_of[_Roaring32]()
        return True

    def _keys(self) -> List[UInt32]:
        var keys = List[UInt32](capacity=len(self._maps))
        for key in self._maps.keys():
            keys.append(key)
        sort(Span(keys))
        return keys^

    def values(self, *, max_bytes: Int = 64 * 1024 * 1024,
               control: Optional[QueryControl] = None) raises -> List[UInt64]:
        if max_bytes < 0 or self._count > max_bytes // 8:
            raise Error("row-set output byte limit exceeded")
        if control:
            control.value().validate_candidate_count(self._count)
            control.value().checkpoint(0)
        var result = List[UInt64](capacity=self._count)
        for key in self._keys():
            for container in self._maps[key].containers:
                if control:
                    control.value().checkpoint(0)
                var prefix = (UInt64(key) << 32) | (UInt64(container.key) << 16)
                for low in container.values():
                    result.append(prefix | UInt64(low))
        return result^

    def _combine(self, other: Self, operation: Int,
                 control: Optional[QueryControl]) raises -> Self:
        if control:
            control.value().validate_candidate_count(self._count + other._count)
            control.value().checkpoint(0)
        var result = Self(max_values=self.max_values, max_bytes=self.max_bytes)
        var keys = self._keys()
        if operation == 0 or operation == 3:
            for key in other._maps.keys():
                if key not in self._maps:
                    keys.append(key)
        for key in keys:
            if control:
                control.value().checkpoint(0)
            var combined: _Roaring32
            if key in self._maps and key in other._maps:
                combined = self._maps[key].combine(other._maps[key], operation)
            elif key in self._maps:
                if operation == 1:
                    continue
                combined = self._maps[key].copy()
            else:
                combined = other._maps[key].copy()
            var count = combined.count()
            if count:
                var bytes = size_of[UInt32]() + combined.bytes()
                result._check(result._count + count, result._bytes + bytes)
                result._count += count
                result._bytes += bytes
                result._maps[key] = combined^
        return result^

    def union_with(self, other: Self, *, control: Optional[QueryControl] = None) raises -> Self:
        return self._combine(other, 0, control)

    def intersection(self, other: Self, *, control: Optional[QueryControl] = None) raises -> Self:
        return self._combine(other, 1, control)

    def difference(self, other: Self, *, control: Optional[QueryControl] = None) raises -> Self:
        return self._combine(other, 2, control)

    def symmetric_difference(self, other: Self, *, control: Optional[QueryControl] = None) raises -> Self:
        return self._combine(other, 3, control)
