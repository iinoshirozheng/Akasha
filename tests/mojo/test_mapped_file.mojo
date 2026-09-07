from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.mapped_file import MappedFile
from std.ffi import c_int, external_call
from std.sys.info import platform_map
from std.sys._libc_errno import get_errno
from std.testing import (
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)


comptime _PAGE_BYTES = 4096
comptime _F_GETFD = 1
comptime _EBADF = platform_map["EBADF", linux=9, macos=9]()


def _fixture_path(suffix: String) -> String:
    var process_id = external_call["getpid", c_int]()
    return String("/tmp/akasha-mapped-file-", Int(process_id), "-", suffix)


def _write_page_fixture(path: String) raises:
    var bytes = List[UInt8](capacity=_PAGE_BYTES)
    for index in range(_PAGE_BYTES):
        bytes.append(UInt8(index % 251))
    write_file_sync(path, bytes)


def _fcntl_getfd(descriptor: Int32) -> Int32:
    return external_call["fcntl", c_int, num_fixed_args=2](
        c_int(descriptor), c_int(_F_GETFD)
    )


def _assert_descriptor_open(descriptor: Int32) raises:
    assert_true(_fcntl_getfd(descriptor) >= 0)


def _assert_descriptor_closed(descriptor: Int32) raises:
    assert_equal(_fcntl_getfd(descriptor), Int32(-1))
    assert_equal(get_errno().value, Int32(_EBADF))


def test_readonly_page_and_checked_slice() raises:
    var path = _fixture_path("page")
    remove_file_if_exists(path)
    _write_page_fixture(path)

    var mapped = MappedFile.open_readonly(path)
    assert_equal(mapped.byte_length(), _PAGE_BYTES)
    assert_equal(mapped.byte_at(0), UInt8(0))
    assert_equal(
        mapped.byte_at(_PAGE_BYTES - 1), UInt8((_PAGE_BYTES - 1) % 251)
    )

    var bytes = mapped.checked_slice(UInt64(127), UInt64(257))
    assert_equal(bytes.byte_length(), 257)
    assert_equal(bytes.byte_at(0), UInt8(127 % 251))
    assert_equal(bytes.byte_at(256), UInt8((127 + 256) % 251))


def test_close_is_idempotent_and_disables_access() raises:
    var path = _fixture_path("close")
    remove_file_if_exists(path)
    _write_page_fixture(path)

    var mapped = MappedFile.open_readonly(path)
    var bytes = mapped.checked_slice(UInt64(0), UInt64(1))
    mapped.close()
    mapped.close()
    with assert_raises():
        _ = mapped.byte_at(0)
    with assert_raises():
        _ = mapped.checked_slice(UInt64(0), UInt64(0))
    with assert_raises():
        _ = bytes.byte_at(0)


def test_empty_file_has_zero_length_without_mapping_pages() raises:
    var path = _fixture_path("empty")
    remove_file_if_exists(path)
    write_file_sync(path, List[UInt8]())

    var mapped = MappedFile.open_readonly(path)
    assert_equal(mapped.byte_length(), 0)
    var empty = mapped.checked_slice(UInt64(0), UInt64(0))
    assert_equal(empty.byte_length(), 0)
    with assert_raises():
        _ = mapped.byte_at(0)
    with assert_raises():
        _ = empty.byte_at(0)


def test_nonexistent_file_and_invalid_ranges_raise() raises:
    var missing = _fixture_path("missing")
    remove_file_if_exists(missing)
    with assert_raises():
        _ = MappedFile.open_readonly(missing)
    with assert_raises():
        _ = MappedFile.open_readonly("/tmp")

    var path = _fixture_path("ranges")
    remove_file_if_exists(path)
    _write_page_fixture(path)
    var mapped = MappedFile.open_readonly(path)

    with assert_raises():
        _ = mapped.byte_at(-1)
    with assert_raises():
        _ = mapped.byte_at(_PAGE_BYTES)
    with assert_raises():
        _ = mapped.checked_slice(UInt64(_PAGE_BYTES + 1), UInt64(0))
    with assert_raises():
        _ = mapped.checked_slice(UInt64(_PAGE_BYTES), UInt64(1))
    with assert_raises():
        _ = mapped.checked_slice(UInt64.MAX, UInt64(2))

    var at_end = mapped.checked_slice(UInt64(_PAGE_BYTES), UInt64(0))
    assert_equal(at_end.byte_length(), 0)


def _read_with_scoped_mapping(path: String) raises -> UInt8:
    var mapped = MappedFile.open_readonly(path)
    var bytes = mapped.checked_slice(UInt64(64), UInt64(1))
    return bytes.byte_at(0)


def _descriptor_from_scoped_mapping(path: String) raises -> Int32:
    var mapped = MappedFile.open_readonly(path)
    var descriptor = mapped._descriptor_for_testing()
    _assert_descriptor_open(descriptor)
    _ = mapped.byte_at(0)
    return descriptor


def test_mapping_and_slice_lifetime_cleanup() raises:
    var path = _fixture_path("lifetime")
    remove_file_if_exists(path)
    _write_page_fixture(path)

    assert_equal(_read_with_scoped_mapping(path), UInt8(64))
    # Exercise a second independent mapping after the first owner and its
    # borrowed slice leave scope through the destructor path.
    var reopened = MappedFile.open_readonly(path)
    assert_true(reopened.byte_length() > 0)
    assert_equal(reopened.byte_at(64), UInt8(64))

    var descriptor = reopened._descriptor_for_testing()
    reopened.close()
    _assert_descriptor_closed(descriptor)


def test_scoped_owner_destructor_closes_observed_descriptor() raises:
    var path = _fixture_path("scoped-descriptor")
    remove_file_if_exists(path)
    _write_page_fixture(path)

    var descriptor = _descriptor_from_scoped_mapping(path)
    _assert_descriptor_closed(descriptor)


def test_explicit_move_transfers_the_only_descriptor_owner() raises:
    var path = _fixture_path("move")
    remove_file_if_exists(path)
    _write_page_fixture(path)

    var source = MappedFile.open_readonly(path)
    var descriptor = source._descriptor_for_testing()
    var moved = source^
    _assert_descriptor_open(descriptor)
    assert_equal(moved.byte_at(0), UInt8(0))
    assert_equal(moved.byte_at(_PAGE_BYTES - 1), UInt8((_PAGE_BYTES - 1) % 251))

    moved.close()
    _assert_descriptor_closed(descriptor)

    # The OS reuses the just-closed lowest descriptor. A second owner close
    # must not close this unrelated handle, proving close is exactly once.
    var sentinel = open(path, "r")
    assert_equal(sentinel.handle, Int(descriptor))
    moved.close()
    assert_true(_fcntl_getfd(Int32(sentinel.handle)) >= 0)
    sentinel.close()


def test_default_owner_is_closed_and_harmless() raises:
    var mapped = MappedFile()
    assert_equal(mapped.byte_length(), 0)
    mapped.close()
    mapped.close()
    with assert_raises():
        _ = mapped.byte_at(0)
    with assert_raises():
        _ = mapped.checked_slice(UInt64(0), UInt64(0))


def test_packed_unaligned_load_checks_full_range_and_lifetime() raises:
    var path = _fixture_path("packed")
    _write_page_fixture(path)
    var mapped = MappedFile.open_readonly(path)
    var values = mapped.load_scalars[DType.uint16, 4](1)
    for lane in range(4):
        assert_equal(
            values[lane], UInt16(1 + 2 * lane) | (UInt16(2 + 2 * lane) << 8)
        )
    with assert_raises():
        _ = mapped.load_scalars[DType.uint16, 4](_PAGE_BYTES - 7)
    with assert_raises():
        _ = mapped.load_scalars[DType.uint16, 4](-1)
    mapped.close()
    with assert_raises():
        _ = mapped.load_scalars[DType.uint16, 4](0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
