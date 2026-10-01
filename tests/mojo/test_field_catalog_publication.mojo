from akasha.common.config import CollectionConfig
from akasha.document.vector_schema import FieldCatalog, legacy_vector_fields
from akasha.storage.collection_config import (
    _CollectionConfigPublishOps,
    decode_collection_config_bytes,
    encode_collection_config,
)
from akasha.storage.field_catalog import (
    decode_field_catalog_bytes,
    encode_field_catalog,
    load_field_catalog,
    publish_field_catalog,
    _publish_field_catalog_with_ops,
)
from akasha.storage.filesystem import (
    atomic_replace,
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    sync_directory,
    write_file_sync,
)
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_false, assert_raises, TestSuite


def _directory(suffix: String) raises -> String:
    var path = String(
        "/tmp/akasha-field-publication-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
    )
    ensure_directory(path)
    return path


def _catalog() raises -> FieldCatalog:
    return decode_field_catalog_bytes(
        read_file_bytes("tests/fixtures/field-catalog/named-f32-v2.bin")
    )


def _legacy(catalog: FieldCatalog) raises -> List[UInt8]:
    return encode_collection_config(catalog.field_at(0).hnsw.value())


struct _FaultOps(_CollectionConfigPublishOps):
    var failure: Int
    var cleanups: Int
    var writes: Int
    var renames: Int
    var syncs: Int
    var cleanup_failure: Bool

    def __init__(out self, failure: Int, cleanup_failure: Bool = False):
        self.failure = failure
        self.cleanups = 0
        self.writes = 0
        self.renames = 0
        self.syncs = 0
        self.cleanup_failure = cleanup_failure

    def remove_temp(mut self, path: String) raises:
        self.cleanups += 1
        if self.cleanup_failure and self.cleanups > 1:
            raise Error("secondary cleanup failure")
        remove_file_if_exists(path)

    def write_temp(mut self, path: String, bytes: List[UInt8]) raises:
        self.writes += 1
        if self.failure == 1:
            raise Error("publication fault")
        write_file_sync(path, bytes)
        if self.failure == 2:
            raise Error("publication fault")

    def replace_temp(mut self, source: String, destination: String) raises:
        self.renames += 1
        if self.failure == 3:
            raise Error("publication fault")
        atomic_replace(source, destination)
        if self.failure == 4:
            raise Error("publication fault")

    def sync_parent(mut self, directory: String) raises:
        self.syncs += 1
        if self.failure == 5:
            raise Error("publication fault")
        sync_directory(directory)


def test_new_identity_and_retry_ignore_stale_temporary_bytes() raises:
    var path = _directory("new")
    var catalog = FieldCatalog(
        1, 0, legacy_vector_fields(CollectionConfig.defaults(3))
    )
    var absent = List[UInt8]()
    write_file_sync(path + "/collection.bin.tmp", [1, 2, 3])
    publish_field_catalog(path, catalog, absent)
    var expected = encode_field_catalog(catalog)
    assert_equal(read_file_bytes(path + "/collection.bin"), expected)
    assert_false(path_exists(path + "/collection.bin.tmp"))
    var retry = _FaultOps(0)
    _publish_field_catalog_with_ops(path, catalog, absent, retry)
    assert_equal(retry.writes, 0)
    assert_equal(retry.renames, 0)
    assert_equal(retry.syncs, 1)


def test_upgrade_preserves_default_identity_and_authoritative_sources() raises:
    var path = _directory("upgrade")
    var catalog = _catalog()
    var legacy = _legacy(catalog)
    write_file_sync(path + "/collection.bin", legacy)
    var wal = read_file_bytes(
        "tests/fixtures/field-envelopes/combined-wal-v4.bin"
    )
    write_file_sync(path + "/wal.bin", wal)
    write_file_sync(path + "/sparse.wal", [9, 8, 7])
    publish_field_catalog(path, catalog, legacy)
    var upgraded = load_field_catalog(path)
    assert_equal(upgraded.legacy_cutover_sequence, UInt64(7))
    assert_equal(
        upgraded.field_at(0).hnsw.value(), catalog.field_at(0).hnsw.value()
    )
    assert_equal(read_file_bytes(path + "/wal.bin"), wal)
    var sparse: List[UInt8] = [9, 8, 7]
    assert_equal(read_file_bytes(path + "/sparse.wal"), sparse)
    with assert_raises():
        _ = decode_collection_config_bytes(
            read_file_bytes(path + "/collection.bin")
        )


def test_preflight_identity_mismatch_does_not_touch_files() raises:
    var catalog = _catalog()
    var expected = _legacy(catalog)
    var other = encode_collection_config(CollectionConfig.defaults(4))
    for state in range(4):
        var path = _directory("mismatch-" + String(state))
        var actual = other.copy()
        if state == 1:
            actual = encode_field_catalog(
                FieldCatalog(
                    1, 0, legacy_vector_fields(CollectionConfig.defaults(3))
                )
            )
        elif state == 2:
            actual = [1, 2, 3]
        if state != 3:
            write_file_sync(path + "/collection.bin", actual)
        var temporary: List[UInt8] = [4, 5, 6]
        write_file_sync(path + "/collection.bin.tmp", temporary)
        with assert_raises():
            publish_field_catalog(path, catalog, expected)
        if state != 3:
            assert_equal(read_file_bytes(path + "/collection.bin"), actual)
        else:
            assert_false(path_exists(path + "/collection.bin"))
        assert_equal(read_file_bytes(path + "/collection.bin.tmp"), temporary)


def test_invalid_transition_is_rejected_before_any_filesystem_mutation() raises:
    var path = _directory("invalid")
    var catalog = _catalog()
    var expected = _legacy(catalog)
    var legacy = decode_field_catalog_bytes(expected)
    var changed_default = encode_collection_config(CollectionConfig.defaults(4))
    var v2_expected = encode_field_catalog(catalog)
    var ops = _FaultOps(0)
    with assert_raises():
        _publish_field_catalog_with_ops(path, legacy, expected, ops)
    with assert_raises():
        _publish_field_catalog_with_ops(path, catalog, changed_default, ops)
    with assert_raises():
        _publish_field_catalog_with_ops(path, catalog, v2_expected, ops)
    with assert_raises():
        _publish_field_catalog_with_ops(path, catalog, [1, 2, 3], ops)
    assert_equal(ops.cleanups, 0)
    assert_equal(ops.writes, 0)
    assert_equal(ops.renames, 0)
    assert_equal(ops.syncs, 0)


def test_each_publication_failure_preserves_one_identity_and_retry_syncs() raises:
    var catalog = _catalog()
    var legacy = _legacy(catalog)
    var target = encode_field_catalog(catalog)
    for failure in range(1, 6):
        var path = _directory("fault-" + String(failure))
        write_file_sync(path + "/collection.bin", legacy)
        var ops = _FaultOps(failure)
        with assert_raises():
            _publish_field_catalog_with_ops(path, catalog, legacy, ops)
        assert_equal(
            read_file_bytes(path + "/collection.bin"),
            target if failure >= 4 else legacy,
        )
        assert_false(path_exists(path + "/collection.bin.tmp"))
        var retry = _FaultOps(0)
        _publish_field_catalog_with_ops(path, catalog, legacy, retry)
        assert_equal(read_file_bytes(path + "/collection.bin"), target)
        assert_equal(retry.writes, 0 if failure >= 4 else 1)
        assert_equal(retry.syncs, 1)


def test_cleanup_failure_keeps_the_primary_publication_error() raises:
    var path = _directory("cleanup")
    var catalog = _catalog()
    var legacy = _legacy(catalog)
    write_file_sync(path + "/collection.bin", legacy)
    var ops = _FaultOps(2, cleanup_failure=True)
    var message = String()
    try:
        _publish_field_catalog_with_ops(path, catalog, legacy, ops)
    except error:
        message = String(error)
    assert_equal(message, "publication fault")
    assert_equal(read_file_bytes(path + "/collection.bin"), legacy)
    publish_field_catalog(path, catalog, legacy)
    assert_equal(load_field_catalog(path).format_version, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
