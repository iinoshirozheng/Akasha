"""Owned Arrow C Data buffers and recursive release callbacks.

Shared by vector and payload exporters. This is the existing scanner ownership
implementation extracted without changing its ABI or lifetime rules.
"""

from akasha.storage.read_generation import ReadGeneration
from std.memory import ArcPointer, OwnedPointer
from std.sys.info import size_of


comptime ARROW_ARRAY_SIZE = 80
comptime ARROW_ARRAY_RELEASE_OFFSET = 64
comptime ARROW_ARRAY_PRIVATE_OFFSET = 72


struct _BufferBudget:
    var limit: Int
    var used: Int

    def __init__(out self, limit: Int) raises:
        if limit <= 0:
            raise Error("scanner buffer limit must be positive")
        self.limit = limit
        self.used = 0

    def reserve(mut self, count: Int) raises:
        if count < 0 or count > self.limit - self.used:
            raise Error("scanner batch buffer resource limit exceeded")
        self.used += count


struct _ArrayData(Movable):
    # Word allocations guarantee 8-byte alignment for every supported primitive.
    var allocations: List[List[UInt64]]
    var buffers: List[Int64]
    var root: Optional[ArcPointer[ReadGeneration]]
    var materialized_bytes: Int
    var borrowed_bytes: Int

    def __init__(out self):
        self.allocations = List[List[UInt64]]()
        self.buffers = List[Int64]()
        self.root = Optional[ArcPointer[ReadGeneration]]()
        self.materialized_bytes = 0
        self.borrowed_bytes = 0

    def allocate(mut self, count: Int, mut budget: _BufferBudget) raises -> Int:
        if count < 0 or count > Int.MAX - 7:
            raise Error("scanner buffer length overflow")
        var words = (count + 7) // 8
        budget.reserve(words * 8)
        self.materialized_bytes += count
        if count == 0:
            return 0
        self.allocations.append(List[UInt64](length=words, fill=UInt64(0)))
        return Int(
            Span(self.allocations[len(self.allocations) - 1]).unsafe_ptr()
        )


struct _ArrayOwner(Movable):
    var data: _ArrayData
    var children: List[ArrowArrayExport]
    var child_pointers: List[Int64]

    def __init__(
        out self, var data: _ArrayData, var children: List[ArrowArrayExport]
    ):
        self.data = data^
        self.children = children^
        self.child_pointers = List[Int64](capacity=len(self.children))
        for index in range(len(self.children)):
            self.child_pointers.append(Int64(self.children[index].address()))


def _release_array(array: OpaquePointer[MutUntrackedOrigin]) abi("C"):
    """May receive a relocated parent or child, on an arbitrary consumer thread.
    """
    var words = array.unsafe_bitcast[Int64]()
    if words[unsafe_offset=8] == 0:
        return
    var address = words[unsafe_offset=9]
    words[unsafe_offset=8] = 0
    words[unsafe_offset=9] = 0
    # Destruction releases only children still owned here. A moved child has
    # release=NULL in its old header and retains its own independent owner.
    var owner = OwnedPointer[_ArrayOwner](
        unsafe_from_opaque_pointer=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(address)
        )
    )
    _ = owner^


struct ArrowArrayExport(Movable):
    var _header: List[Int64]
    var materialized_bytes: Int
    var borrowed_bytes: Int

    def __init__(
        out self,
        length: Int,
        null_count: Int,
        var data: _ArrayData,
        var children: List[ArrowArrayExport],
    ):
        comptime assert (
            size_of[OpaquePointer[MutUntrackedOrigin]]() == 8
        ), "Arrow export requires a 64-bit ABI"
        comptime assert (
            size_of[type_of(_release_array)]() == 8
        ), "Arrow export requires an 8-byte C callback"
        self.materialized_bytes = data.materialized_bytes
        self.borrowed_bytes = data.borrowed_bytes
        for index in range(len(children)):
            self.materialized_bytes += children[index].materialized_bytes
            self.borrowed_bytes += children[index].borrowed_bytes
        var owner = OwnedPointer(_ArrayOwner(data^, children^))
        var allocation = owner^.unsafe_take_allocation()
        var address = Int(allocation^.unsafe_leak())
        var state = Pointer[_ArrayOwner, MutUntrackedOrigin](
            unsafe_from_address=address
        )
        var buffers = Int(Span(state[].data.buffers).unsafe_ptr()) if len(
            state[].data.buffers
        ) else 0
        var child_pointers = Int(
            Span(state[].child_pointers).unsafe_ptr()
        ) if len(state[].children) else 0
        self._header = [
            Int64(length),
            Int64(null_count),
            0,
            Int64(len(state[].data.buffers)),
            Int64(len(state[].children)),
            Int64(buffers),
            Int64(child_pointers),
            0,
            0,
            Int64(address),
        ]
        Pointer[type_of(_release_array), MutUntrackedOrigin](
            unsafe_from_address=self.address() + ARROW_ARRAY_RELEASE_OFFSET
        )[] = _release_array

    def __deinit__(deinit self):
        _release_array(
            Pointer[NoneType, MutUntrackedOrigin](
                unsafe_from_address=self.address()
            )
        )

    def address(self) -> Int:
        return Int(Span(self._header).unsafe_ptr())


def _store[T: TrivialRegisterPassable](address: Int, index: Int, value: T):
    Pointer[T, MutUntrackedOrigin](unsafe_from_address=address)[
        unsafe_offset=index
    ] = value


def _set_bit(address: Int, index: Int):
    var bytes = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=address)
    bytes[unsafe_offset=index // 8] |= UInt8(1) << UInt8(index % 8)


def _checked_bytes(count: Int, width: Int) raises -> Int:
    if count < 0 or count > Int.MAX // width:
        raise Error("scanner buffer length overflow")
    return count * width
