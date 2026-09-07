from akasha import CollectionConfig, MetricKind, ScalarKind
from akasha.storage.checksum import crc32_range
from akasha.storage.collection_config import (
    _CollectionConfigPublishOps,
    _publish_collection_config_with_ops,
)
from akasha.storage import (
    collection_config_exists,
    decode_collection_config_bytes,
    encode_collection_config,
    load_collection_config,
    publish_collection_config,
)
from akasha.storage.filesystem import (
    atomic_replace,
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


comptime _ENCODED_SIZE = 60
comptime _CHECKSUM_OFFSET = 56


struct _FailOnceSyncOps(_CollectionConfigPublishOps):
    var sync_attempts: Int

    def __init__(out self):
        self.sync_attempts = 0

    def remove_temp(mut self, path: String) raises:
        remove_file_if_exists(path)

    def write_temp(
        mut self, path: String, bytes: List[UInt8]
    ) raises:
        write_file_sync(path, bytes)

    def replace_temp(
        mut self, source: String, destination: String
    ) raises:
        atomic_replace(source, destination)

    def sync_parent(mut self, directory: String) raises:
        self.sync_attempts += 1
        if self.sync_attempts == 1:
            raise Error("injected directory sync failure")


struct _WriteAndCleanupFailOps(_CollectionConfigPublishOps):
    var cleanup_attempts: Int

    def __init__(out self):
        self.cleanup_attempts = 0

    def remove_temp(mut self, path: String) raises:
        self.cleanup_attempts += 1
        if self.cleanup_attempts > 1:
            raise Error("injected cleanup failure")
        remove_file_if_exists(path)

    def write_temp(
        mut self, path: String, bytes: List[UInt8]
    ) raises:
        raise Error("injected primary write failure")

    def replace_temp(
        mut self, source: String, destination: String
    ) raises:
        pass

    def sync_parent(mut self, directory: String) raises:
        pass


def _config(metric: MetricKind, scalar: ScalarKind) -> CollectionConfig:
    return CollectionConfig(
        dimension=32,
        ann_metric=metric,
        scalar_kind=scalar,
        m=16,
        m0=32,
        ef_construction=128,
        default_ef_search=64,
        max_ef_search=512,
        max_level=32,
        rebuild_inactive_percent=25,
        delta_max_points=10_000,
        level_seed=UInt64(0xA5A5A5A5A5A5A5A5),
    )


def _test_directory(suffix: String) -> String:
    var process_id = external_call["getpid", c_int]()
    return String(
        "/tmp/akasha-collection-config-",
        Int(process_id),
        "-",
        suffix,
    )


def _assert_bytes_equal(lhs: List[UInt8], rhs: List[UInt8]) raises:
    assert_equal(len(lhs), len(rhs))
    for index in range(len(lhs)):
        assert_equal(lhs[index], rhs[index])


def _prefix(bytes: List[UInt8], count: Int) -> List[UInt8]:
    var result = List[UInt8](capacity=count)
    for index in range(count):
        result.append(bytes[index])
    return result^


def _with_valid_checksum(var bytes: List[UInt8]) -> List[UInt8]:
    var checksum = crc32_range(bytes, 4, _CHECKSUM_OFFSET)
    for byte_index in range(4):
        bytes[_CHECKSUM_OFFSET + byte_index] = UInt8(
            checksum >> UInt32(byte_index * 8)
        )
    return bytes^


def _set_u16(
    var bytes: List[UInt8], offset: Int, value: UInt16
) -> List[UInt8]:
    bytes[offset] = UInt8(value)
    bytes[offset + 1] = UInt8(value >> UInt16(8))
    return _with_valid_checksum(bytes^)


def _set_u32(
    var bytes: List[UInt8], offset: Int, value: UInt32
) -> List[UInt8]:
    for byte_index in range(4):
        bytes[offset + byte_index] = UInt8(
            value >> UInt32(byte_index * 8)
        )
    return _with_valid_checksum(bytes^)


def test_round_trips_every_valid_metric_scalar_combination_deterministically(
) raises:
    for metric_tag in range(3):
        for scalar_tag in range(4):
            if metric_tag == 1 and scalar_tag == 3:
                continue
            var config = _config(
                MetricKind.from_tag(UInt8(metric_tag)),
                ScalarKind.from_tag(UInt8(scalar_tag)),
            )
            var first = encode_collection_config(config)
            var second = encode_collection_config(config)
            assert_equal(len(first), _ENCODED_SIZE)
            _assert_bytes_equal(first, second)
            var decoded = decode_collection_config_bytes(first^)
            assert_equal(decoded, config)


def test_round_trips_default_and_inclusive_boundary_configurations() raises:
    var defaults = CollectionConfig.defaults(7)
    var default_bytes = encode_collection_config(defaults)
    assert_equal(
        decode_collection_config_bytes(default_bytes^), defaults
    )

    var minimum = CollectionConfig(
        dimension=1,
        ann_metric=MetricKind.dot(),
        scalar_kind=ScalarKind.i8(),
        m=2,
        m0=2,
        ef_construction=2,
        default_ef_search=1,
        max_ef_search=1,
        max_level=1,
        rebuild_inactive_percent=1,
        delta_max_points=1,
        level_seed=UInt64(0),
    )
    var minimum_bytes = encode_collection_config(minimum)
    assert_equal(
        decode_collection_config_bytes(minimum_bytes^), minimum
    )

    var maximum = CollectionConfig(
        dimension=4_294_967_295,
        ann_metric=MetricKind.cosine(),
        scalar_kind=ScalarKind.f16(),
        m=65_535,
        m0=65_535,
        ef_construction=4_294_967_295,
        default_ef_search=4_294_967_295,
        max_ef_search=4_294_967_295,
        max_level=63,
        rebuild_inactive_percent=90,
        delta_max_points=4_294_967_295,
        level_seed=UInt64.MAX,
    )
    var maximum_bytes = encode_collection_config(maximum)
    assert_equal(
        decode_collection_config_bytes(maximum_bytes^), maximum
    )


def test_default_config_matches_and_decodes_independent_golden_vector() raises:
    # Independent struct.pack/zlib fixture; CRC32 is 0x253BCFF8.
    var golden: List[UInt8] = [
        0x41, 0x4B, 0x43, 0x46, 0x01, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00, 0x01, 0x00, 0x10, 0x00,
        0x20, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00,
        0x20, 0x00, 0x19, 0x00, 0x10, 0x27, 0x00, 0x00,
        0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xF8, 0xCF, 0x3B, 0x25,
    ]
    var encoded = encode_collection_config(CollectionConfig.defaults(7))
    _assert_bytes_equal(encoded, golden)
    assert_equal(
        decode_collection_config_bytes(golden^),
        CollectionConfig.defaults(7),
    )


def test_rejects_every_truncation_and_extra_bytes() raises:
    var complete = encode_collection_config(CollectionConfig.defaults(8))
    for cut in range(len(complete)):
        var truncated = _prefix(complete, cut)
        with assert_raises():
            _ = decode_collection_config_bytes(truncated^)

    complete.append(0)
    with assert_raises():
        _ = decode_collection_config_bytes(complete^)


def test_rejects_magic_version_flags_reserved_tags_and_checksum() raises:
    var magic = encode_collection_config(CollectionConfig.defaults(8))
    magic[0] = UInt8(0)
    with assert_raises():
        _ = decode_collection_config_bytes(magic^)

    var version = encode_collection_config(CollectionConfig.defaults(8))
    version = _set_u16(version^, 4, UInt16(2))
    with assert_raises():
        _ = decode_collection_config_bytes(version^)

    var flags = encode_collection_config(CollectionConfig.defaults(8))
    flags = _set_u16(flags^, 6, UInt16(1))
    with assert_raises():
        _ = decode_collection_config_bytes(flags^)

    var reserved_offsets: List[Int] = [
        18, 19, 35, 48, 49, 50, 51, 52, 53, 54, 55
    ]
    for offset in reserved_offsets:
        var reserved = encode_collection_config(CollectionConfig.defaults(8))
        reserved[offset] = UInt8(1)
        reserved = _with_valid_checksum(reserved^)
        with assert_raises():
            _ = decode_collection_config_bytes(reserved^)

    var metric = encode_collection_config(CollectionConfig.defaults(8))
    metric[12] = UInt8(99)
    metric = _with_valid_checksum(metric^)
    with assert_raises():
        _ = decode_collection_config_bytes(metric^)

    var scalar = encode_collection_config(CollectionConfig.defaults(8))
    scalar[13] = UInt8(99)
    scalar = _with_valid_checksum(scalar^)
    with assert_raises():
        _ = decode_collection_config_bytes(scalar^)

    var checksum = encode_collection_config(CollectionConfig.defaults(8))
    checksum[20] ^= UInt8(1)
    with assert_raises():
        _ = decode_collection_config_bytes(checksum^)


def test_decode_revalidates_cross_field_constraints() raises:
    var small_m0 = encode_collection_config(CollectionConfig.defaults(8))
    small_m0 = _set_u16(small_m0^, 16, UInt16(15))
    with assert_raises():
        _ = decode_collection_config_bytes(small_m0^)

    var small_construction = encode_collection_config(
        CollectionConfig.defaults(8)
    )
    small_construction = _set_u32(small_construction^, 20, UInt32(31))
    with assert_raises():
        _ = decode_collection_config_bytes(small_construction^)

    var small_max_search = encode_collection_config(
        CollectionConfig.defaults(8)
    )
    small_max_search = _set_u32(small_max_search^, 28, UInt32(63))
    with assert_raises():
        _ = decode_collection_config_bytes(small_max_search^)

    var incompatible = encode_collection_config(CollectionConfig.defaults(8))
    incompatible[13] = ScalarKind.i8().tag()
    incompatible = _with_valid_checksum(incompatible^)
    with assert_raises():
        _ = decode_collection_config_bytes(incompatible^)


def test_encode_validates_before_narrowing() raises:
    var invalid = CollectionConfig.defaults(8)
    invalid.dimension = 4_294_967_296
    with assert_raises():
        _ = encode_collection_config(invalid)

    invalid = CollectionConfig.defaults(8)
    invalid.scalar_kind = ScalarKind.i8()
    with assert_raises():
        _ = encode_collection_config(invalid)


def test_publish_load_exists_and_idempotent_republish() raises:
    var directory = _test_directory("storage")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/collection.bin")
    remove_file_if_exists(directory + "/collection.bin.tmp")
    assert_equal(collection_config_exists(directory), False)

    var config = CollectionConfig.defaults(13)
    publish_collection_config(directory, config)
    assert_true(collection_config_exists(directory))
    assert_equal(load_collection_config(directory), config)
    var first_bytes = read_file_bytes(directory + "/collection.bin")

    publish_collection_config(directory, config)
    var second_bytes = read_file_bytes(directory + "/collection.bin")
    _assert_bytes_equal(first_bytes, second_bytes)
    assert_equal(path_exists(directory + "/collection.bin.tmp"), False)

    remove_file_if_exists(directory + "/collection.bin")


def test_incompatible_publish_preserves_original_and_removes_temp() raises:
    var directory = _test_directory("conflict")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/collection.bin")
    remove_file_if_exists(directory + "/collection.bin.tmp")
    var original = CollectionConfig.defaults(17)
    publish_collection_config(directory, original)
    var original_bytes = read_file_bytes(directory + "/collection.bin")

    var stale: List[UInt8] = [1, 2, 3]
    write_file_sync(directory + "/collection.bin.tmp", stale)
    var incompatible = CollectionConfig.defaults(17)
    incompatible.ann_metric = MetricKind.cosine()
    with assert_raises():
        publish_collection_config(directory, incompatible)

    var remaining = read_file_bytes(directory + "/collection.bin")
    _assert_bytes_equal(original_bytes, remaining)
    assert_equal(load_collection_config(directory), original)
    assert_equal(path_exists(directory + "/collection.bin.tmp"), False)

    remove_file_if_exists(directory + "/collection.bin")


def test_invalid_first_publish_creates_no_files() raises:
    var directory = _test_directory("invalid")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/collection.bin")
    remove_file_if_exists(directory + "/collection.bin.tmp")
    var invalid = CollectionConfig.defaults(9)
    invalid.m = 1

    with assert_raises():
        publish_collection_config(directory, invalid)

    assert_equal(path_exists(directory + "/collection.bin"), False)
    assert_equal(path_exists(directory + "/collection.bin.tmp"), False)


def test_retry_after_rename_and_sync_failure_syncs_existing_file_again() raises:
    var directory = _test_directory("sync-retry")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/collection.bin")
    remove_file_if_exists(directory + "/collection.bin.tmp")
    var config = CollectionConfig.defaults(11)
    var ops = _FailOnceSyncOps()

    with assert_raises():
        _publish_collection_config_with_ops(directory, config, ops)
    assert_true(collection_config_exists(directory))
    assert_equal(ops.sync_attempts, 1)

    _publish_collection_config_with_ops(directory, config, ops)
    assert_equal(ops.sync_attempts, 2)
    assert_equal(load_collection_config(directory), config)

    remove_file_if_exists(directory + "/collection.bin")


def test_cleanup_failure_does_not_mask_primary_publication_error() raises:
    var directory = _test_directory("error-preservation")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/collection.bin")
    remove_file_if_exists(directory + "/collection.bin.tmp")
    var ops = _WriteAndCleanupFailOps()

    var message = String()
    try:
        _publish_collection_config_with_ops(
            directory, CollectionConfig.defaults(5), ops
        )
    except error:
        message = String(error)

    assert_equal(message, "injected primary write failure")
    assert_equal(ops.cleanup_attempts, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
