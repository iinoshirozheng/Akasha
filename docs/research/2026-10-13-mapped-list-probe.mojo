from akasha.storage.checksum import BinaryWriter
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.mapped_file import MappedFile
from max.algorithm import parallelize
from std.ffi import c_int, external_call
from std.memory import ArcPointer, bitcast, unsafe_memcpy
from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from std.time import sleep
from std.utils import BlockingScopedLock, BlockingSpinLock


struct _MappedRowState(Movable):
    var mapping: MappedFile
    var offset: Int
    var count: Int
    var lock: BlockingSpinLock
    var cache: List[Float32]
    var materialized: Bool
    var builds: Int
    var delay_for_test: Float64

    def __init__(out self, var mapping: MappedFile, offset: Int, count: Int) raises:
        if offset < 0 or count < 0 or offset > mapping.byte_length():
            raise Error("invalid mapped row")
        if count > (mapping.byte_length() - offset) // 4:
            raise Error("invalid mapped row")
        self.mapping = mapping^
        self.offset = offset
        self.count = count
        self.lock = BlockingSpinLock()
        self.cache = List[Float32]()
        self.materialized = False
        self.builds = 0
        self.delay_for_test = 0.0


@fieldwise_init
struct _MappedRow(Movable):
    var owner: ArcPointer[_MappedRowState]

    def clone(self) -> Self:
        return Self(self.owner.copy())

    def load[width: Int](self, index: Int) raises -> SIMD[DType.float32, width]:
        if index < 0 or width > self.owner[].count or index > self.owner[].count - width:
            raise Error("mapped row load outside range")
        return self.owner[].mapping.load_scalars[DType.float32, width](
            self.owner[].offset + index * 4
        )

    def values(self) -> ref[origin_of(self.owner[].cache, self)] List[Float32]:
        # Update only individual fields through the stable pointee; never pass
        # a whole mutable state across a lock wait/copy-back boundary.
        var state = Pointer(to=self.owner[])
        with BlockingScopedLock(state[].lock):
            if not state[].materialized:
                if state[].delay_for_test > 0:
                    sleep(state[].delay_for_test)
                # The constructor checked the whole row. This private state
                # exclusively owns the moved mapping, which has no close API.
                # Preserve the legacy non-raising accessor without suppressing
                # errors or constructing a List over somebody else's buffer.
                var ready = List[Float32](unsafe_uninit_length=state[].count)
                if state[].count:
                    unsafe_memcpy(
                        dest=ready.unsafe_ptr().unsafe_bitcast[UInt8](),
                        src=state[].mapping._base.value().unsafe_offset(state[].offset),
                        count=state[].count * 4,
                    )
                state[].cache = ready^
                state[].builds += 1
                state[].materialized = True
        return self.owner[].cache


def _path(suffix: String) -> String:
    return String("/tmp/akasha-mapped-list-probe-", Int(external_call["getpid", c_int]()), "-", suffix)


def _make(path: String) raises -> _MappedRow:
    var writer = BinaryWriter()
    writer.write_u8(0xAA)  # Existing record payloads need not be aligned.
    for word in [UInt32(0), UInt32(0x80000000), UInt32(0x3FC00000), UInt32(0xC0200000)]:
        writer.write_u32(word)
    write_file_sync(path, writer.take_bytes())
    return _MappedRow(ArcPointer(_MappedRowState(MappedFile.open_readonly(path), 1, 4)))


def test_checked_unaligned_reads_do_not_materialize_a_list() raises:
    var path = _path("direct")
    var row = _make(path)
    var values = row.load[4](0)
    assert_equal(bitcast[DType.uint32](values[0]), UInt32(0))
    assert_equal(bitcast[DType.uint32](values[1]), UInt32(0x80000000))
    assert_equal(values[2], Float32(1.5))
    assert_equal(values[3], Float32(-2.5))
    assert_equal(len(row.owner[].cache), 0)
    assert_equal(row.owner[].builds, 0)
    with assert_raises():
        _ = row.load[4](1)
    with assert_raises():
        _ = row.load[1](-1)
    with assert_raises():
        _ = row.load[1](Int.MAX)
    remove_file_if_exists(path)


def test_retained_owner_keeps_list_borrow_and_mapping() raises:
    var path = _path("owner")
    var wrapper = Optional(_make(path))
    var acquired = wrapper.value().clone()
    wrapper = None
    assert_true(not Bool(wrapper))
    ref first = acquired.values()
    var address = Int(first.unsafe_ptr())
    assert_equal(first[2], Float32(1.5))
    ref second = acquired.values()
    assert_equal(Int(second.unsafe_ptr()), address)
    assert_equal(acquired.owner[].builds, 1)
    assert_equal(bitcast[DType.uint32](second[1]), UInt32(0x80000000))
    assert_equal(acquired.load[1](3)[0], Float32(-2.5))
    remove_file_if_exists(path)


def test_concurrent_public_list_access_materializes_once() raises:
    var path = _path("concurrent")
    var row = _make(path)
    row.owner[].delay_for_test = 0.05
    var failures = List[Int](length=8, fill=0)
    var addresses = List[Int](length=8, fill=0)
    def run(index: Int) {imm row, mut failures, mut addresses}:
        var acquired = row.clone()
        for _ in range(100):
            ref values = acquired.values()
            if len(values) != 4 or values[2] != Float32(1.5):
                failures[index] += 1
            addresses[index] = Int(values.unsafe_ptr())
    parallelize(run, 8, 8)
    for index in range(8):
        assert_equal(failures[index], 0)
        assert_equal(addresses[index], addresses[0])
    assert_true(addresses[0] != 0)
    assert_equal(row.owner[].builds, 1)
    remove_file_if_exists(path)


def test_empty_materialization_is_nonraising_without_a_base_pointer() raises:
    var path = _path("empty")
    write_file_sync(path, List[UInt8]())
    var row = _MappedRow(ArcPointer(_MappedRowState(MappedFile.open_readonly(path), 0, 0)))
    ref values = row.values()
    assert_equal(len(values), 0)
    assert_equal(row.owner[].builds, 1)
    with assert_raises():
        _ = row.load[1](0)
    remove_file_if_exists(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
