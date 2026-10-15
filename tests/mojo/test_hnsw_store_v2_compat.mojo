from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.storage.filesystem import read_file_bytes, write_file_sync
from akasha.storage.hnsw_store import decode_hnsw_snapshot_owned, encode_hnsw_snapshot, open_hnsw_snapshot_view
from akasha.storage.checksum import crc32_range
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def _config(scalar: ScalarKind) -> CollectionConfig:
    var config = CollectionConfig.defaults(2)
    config.ann_metric = MetricKind.dot()
    config.scalar_kind = scalar.copy()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 128
    config.max_level = 4
    config.level_seed = UInt64(0x17A5A17A5)
    return config^


def _u64(bytes: List[UInt8], offset: Int) -> UInt64:
    var result = UInt64(0)
    for i in range(8):
        result |= UInt64(bytes[offset + i]) << UInt64(i * 8)
    return result


def _put_u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for i in range(4):
        bytes[offset + i] = UInt8(value >> UInt32(i * 8))


def test_frozen_v2_compact_fixtures_migrate_without_changing_queries_or_vectors() raises:
    for scalar in [ScalarKind.bf16(), ScalarKind.f16(), ScalarKind.i8()]:
        var config = _config(scalar)
        var path = "tests/fixtures/hnsw-v2-" + scalar.name() + ".bin"
        var bytes = read_file_bytes(path)
        assert_equal(bytes[4], UInt8(2))
        var owned = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(77))
        var mapped = open_hnsw_snapshot_view(path, config, UInt64(77))
        var rewritten = encode_hnsw_snapshot(owned, UInt64(77))
        assert_equal(rewritten[4], UInt8(3))
        var migrated = decode_hnsw_snapshot_owned(rewritten^, config, UInt64(77))
        assert_equal(migrated.graph.vector_bytes, owned.graph.vector_bytes)
        assert_equal(migrated.graph.vector_scales, owned.graph.vector_scales)
        assert_equal(migrated.point_count() - migrated.inactive_count(), 7)
        var queries: List[List[Float32]] = [[0.1, 0.9], [-1.0, 0.5]]
        for query in queries:
            var a = owned.search(query, 5, ef_search=32)
            var b = mapped.search(query, 5, ef_search=32)
            var c = migrated.search(query, 5, ef_search=32)
            assert_equal(len(a), len(b))
            assert_equal(len(a), len(c))
            for i in range(len(a)):
                assert_equal(a[i].id, b[i].id)
                assert_equal(a[i].score, b[i].score)
                assert_equal(a[i].id, c[i].id)
                assert_equal(a[i].score, c[i].score)
        mapped.close()
        assert_equal(read_file_bytes(path), bytes)


def test_legacy_v2_still_rejects_crc_valid_directed_only_edges() raises:
    var config = _config(ScalarKind.f16())
    var bytes = read_file_bytes("tests/fixtures/hnsw-v2-f16.bin")
    var original = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(77))
    var changed = False
    var edge_position = Int(_u64(bytes, 136))
    for source in range(original.graph.slot_count()):
        for level in range(original.graph.level(UInt32(source)) + 1):
            var degree = original.graph.neighbor_count(UInt32(source), level)
            if not changed and level == 0 and degree > 0:
                for target in range(original.graph.slot_count()):
                    if target == source:
                        continue
                    var existing = False
                    for edge in range(degree):
                        existing |= original.graph.neighbor_at(UInt32(source), 0, edge) == UInt32(target)
                    var reverse = False
                    for edge in range(original.graph.neighbor_count(UInt32(target), 0)):
                        reverse |= original.graph.neighbor_at(UInt32(target), 0, edge) == UInt32(source)
                    if not existing and not reverse:
                        _put_u32(bytes, edge_position, UInt32(target))
                        changed = True
                        break
            edge_position += degree * 4
    assert_true(changed)
    _put_u32(bytes, len(bytes) - 4, crc32_range(bytes, 0, len(bytes) - 4))
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(77))
    var path = String("/tmp/akasha-v2-directed-", Int(external_call["getpid", c_int]()), ".bin")
    write_file_sync(path, bytes)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, UInt64(77))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
