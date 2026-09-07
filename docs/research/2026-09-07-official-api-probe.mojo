from std.bit import pop_count, count_trailing_zeros
from std.collections.binary_heap import BinaryHeap
from std.collections.bitset import BitSet
from std.python import Python, PythonObject
from std.python.numpy import from_numpy_array
from std.testing import assert_equal, assert_true, assert_raises


struct Item(Copyable, Movable, Comparable):
    var id: Int
    var score: Float32

    def __init__(out self, id: Int, score: Float32):
        self.id = id
        self.score = score

    def __lt__(self, other: Self) -> Bool:
        return before(self, other)

    def __gt__(self, other: Self) -> Bool:
        return before(other, self)

    def __eq__(self, other: Self) -> Bool:
        return self.id == other.id and self.score == other.score

    def __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    def __le__(self, other: Self) -> Bool:
        return not before(other, self)

    def __ge__(self, other: Self) -> Bool:
        return not before(self, other)


def before(lhs: Item, rhs: Item) -> Bool:
    if lhs.score != rhs.score:
        return lhs.score < rhs.score
    return lhs.id < rhs.id


def reference_popcount(value: UInt64) -> Int:
    var rest = value
    var count = 0
    while rest != 0:
        rest &= rest - 1
        count += 1
    return count


def borrow_readonly(array: PythonObject) raises -> Float32:
    var values = from_numpy_array[DType.float32](array)
    return values[2]


def main() raises:
    var samples: List[UInt64] = [0, 1, UInt64.MAX, UInt64(1) << 63]
    var state = UInt64(1234567)
    for _ in range(1024):
        state = state * UInt64(6364136223846793005) + UInt64(1)
        samples.append(state)
    for value in samples:
        assert_equal(Int(pop_count(value)), reference_popcount(value))
    for bit in range(64):
        assert_equal(Int(count_trailing_zeros(UInt64(1) << UInt64(bit))), bit)
    print("PASS bit intrinsics: 1028 popcounts and 64 bit positions")

    var heap = BinaryHeap[Int](capacity=4)
    heap.push(2)
    heap.push(5)
    heap.push(-1)
    assert_equal(heap.peek(), 5)
    assert_equal(heap.pop(), 5)
    assert_equal(heap.pop(), 2)
    heap.clear()
    assert_equal(len(heap), 0)
    print("PASS official BinaryHeap capacity/push/peek/pop/clear")

    var items = List[Item]()
    items.append(Item(9, 1.0))
    items.append(Item(3, 1.0))
    items.append(Item(7, -2.0))
    sort(Span(items))
    assert_equal(items[0].id, 7)
    assert_equal(items[1].id, 3)
    assert_equal(items[2].id, 9)
    var ranked_heap = BinaryHeap[Item](capacity=3)
    for item in items:
        ranked_heap.push(item.copy())
    assert_equal(ranked_heap.pop().id, 9)
    assert_equal(ranked_heap.pop().id, 3)
    assert_equal(ranked_heap.pop().id, 7)
    print("PASS official sort with score and ID comparator")

    var values: List[Float32] = [1.0, 2.0, 3.0]
    var copied = values.copy()
    copied[0] = 99.0
    assert_equal(values[0], 1.0)
    var appended = List[Float32]()
    appended.extend(Span(values))
    assert_equal(appended[2], 3.0)
    var bits = BitSet[129]()
    bits.set(128)
    bits.clear(128)
    assert_equal(len(bits), 0)
    print("PASS official List copy/extend and fixed-size BitSet")

    var np = Python.import_module("numpy")
    var pa = Python.import_module("pyarrow")
    var array = np.arange(8, dtype="float32")
    var span = from_numpy_array[DType.float32](array)
    assert_equal(span[2], 2.0)
    span[2] = 42.0
    assert_equal(Float32(py=array[2]), 42.0)
    var sliced = array.__getitem__(Python.import_module("builtins").slice(2, 6))
    assert_equal(borrow_readonly(sliced), 4.0)
    var arrow = pa.array(array)
    var readonly = arrow.to_numpy(zero_copy_only=True)
    assert_true(not Bool(py=readonly.flags.writeable))
    assert_equal(borrow_readonly(readonly), 42.0)
    assert_equal(Int(py=readonly.__array_interface__["data"][0]), Int(py=array.__array_interface__["data"][0]))
    with assert_raises():
        _ = from_numpy_array[DType.float64](array)
    var strided = array.__getitem__(Python.import_module("builtins").slice(0, 8, 2))
    with assert_raises():
        _ = from_numpy_array[DType.float32](strided)
    var matrix = array.reshape(2, 4)
    with assert_raises():
        _ = from_numpy_array[DType.float32](matrix)
    with assert_raises():
        _ = from_numpy_array[DType.float32](readonly)
    print("PASS NumPy/Arrow pointer identity, readonly borrow, slice, dtype/stride/rank/mutability rejection")
