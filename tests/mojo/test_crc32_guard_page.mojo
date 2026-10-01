from akasha.storage.checksum import crc32_update
from std.ffi import c_int, c_long, c_size_t, external_call
from std.sys.info import platform_map
from std.testing import assert_equal, assert_true, TestSuite


def _bitwise(register: UInt32, data: Span[UInt8, _]) -> UInt32:
    var result = register
    for byte in data:
        result ^= UInt32(byte)
        for _ in range(8):
            result = (result >> 1) ^ (
                UInt32(0xEDB88320) if result & 1 else UInt32(0)
            )
    return result


def test_crc_does_not_read_outside_buffers_at_protected_page_edges() raises:
    var page_size = Int(external_call["getpagesize", c_int]())
    assert_true(page_size >= 256)
    comptime flags = 2 | platform_map[
        "MAP_ANONYMOUS", linux=0x20, macos=0x1000
    ]()
    var null_address: Optional[OpaquePointer[MutUntrackedOrigin]] = None
    var mapping = external_call["mmap", OpaquePointer[MutUntrackedOrigin]](
        null_address, c_size_t(3 * page_size), c_int(0), c_int(flags),
        c_int(-1), c_long(0),
    )
    assert_true(Int(mapping) != -1)
    try:
        var data = mapping.unsafe_bitcast[UInt8]().unsafe_offset(page_size)
        assert_equal(
            external_call["mprotect", c_int](
                data, c_size_t(page_size), c_int(3)
            ),
            c_int(0),
        )
        for index in range(page_size):
            data[unsafe_offset=index] = UInt8((index * 73 + 19) % 251)
        for length in range(130):
            for offset in [0, page_size - length]:
                var view = Span(
                    unsafe_ptr=data.unsafe_offset(offset), length=length
                )
                for initial in [UInt32(0), UInt32.MAX, UInt32(0x12345678)]:
                    assert_equal(
                        crc32_update(initial, view), _bitwise(initial, view)
                    )
    except error:
        _ = external_call["munmap", c_int](mapping, c_size_t(3 * page_size))
        raise error
    assert_equal(
        external_call["munmap", c_int](mapping, c_size_t(3 * page_size)),
        c_int(0),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
