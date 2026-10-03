from test_named_hnsw import _fields, _populate, _predicate
from akasha import CollectionConfig, PersistentCollection
from akasha.common.config import MetricKind, ScalarKind
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.vector_value import VectorValue
from akasha.storage.field_hnsw_cache import load_field_hnsw_cache
from akasha.storage.filesystem import (
    path_exists,
    read_file_bytes,
    write_file_sync,
)
from akasha.storage.index_cache import decode_cache_bytes, encode_cache
from akasha.storage.hnsw_store import encode_hnsw_snapshot
from akasha.index.hnsw import HnswIndex
from std.memory import bitcast
from std.python import Python
from std.testing import assert_equal, assert_true, TestSuite
from max.algorithm import parallelize
from std.utils import BlockingScopedLock


def _path() raises -> String:
    return String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-field-cache-"
        )
    )


def _query() raises -> VectorValue:
    return VectorValue.dense[DType.uint8]([UInt8(31), UInt8(4)])


def _seed(path: String) raises:
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _populate(collection)
    _ = collection.search_field("audio", _query(), 7, approximate=True)
    collection.close()
    assert_true(path_exists(path + "/field-hnsw-3.cache"))
    # Closing a WAL-only collection saves a cache, without checkpointing authority.
    assert_true(not path_exists(path + "/manifest.bin"))


def _assert_query(mut collection: PersistentCollection, hit: Bool) raises:
    var snapshot = collection.snapshot()
    for filtered in [False, True]:
        var exact = snapshot.search_field(
            "audio", _query(), 7, _predicate(filtered)
        )
        var actual = snapshot.search_field(
            "audio", _query(), 7, _predicate(filtered), approximate=True
        )
        assert_equal(len(actual), len(exact))
        for i in range(len(actual)):
            assert_equal(actual[i].id, exact[i].id)
            assert_equal(
                bitcast[DType.uint64](actual[i].score),
                bitcast[DType.uint64](exact[i].score),
            )
    var root = snapshot._acquire()
    assert_equal(
        root[].run(0).field_hnsw[].get(3)[].ready.value()[].cache_hit, hit
    )


def test_wal_only_hit_and_metadata_change_rebind_current_ordinals() raises:
    var path = _path()
    _seed(path)
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    var fields: List[DocumentField] = [
        DocumentField("group", PayloadValue.integer(1))
    ]
    var batch: List[PointMutation] = [
        PointMutation(-30, 1, [], Optional(fields^))
    ]
    _ = collection.apply_point_batch(batch)
    _assert_query(collection, True)
    collection.flush()
    collection.close()
    var reopened = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _assert_query(reopened, True)
    reopened.close()
    Python.import_module("shutil").rmtree(path)


def test_wal_vector_presence_and_id_changes_reject_saved_graph() raises:
    for mode in range(4):
        var path = _path()
        _seed(path)
        var previous = read_file_bytes(path + "/field-hnsw-3.cache")
        var collection = PersistentCollection.open_with_fields(
            path, _fields(), maintenance_library_path=""
        )
        var changes = List[FieldUpdate]()
        if mode == 0 or mode == 3:
            changes.append(FieldUpdate.set(3, _query()))
        elif mode == 1:
            changes.append(FieldUpdate.remove(3))
        var batch: List[PointMutation] = [
            PointMutation(
                -999 if mode == 3 else -30,
                UInt8(2 if mode == 2 else 1),
                changes^,
            )
        ]
        _ = collection.apply_point_batch(batch)
        collection.close()
        assert_equal(read_file_bytes(path + "/field-hnsw-3.cache"), previous)
        var reopened = PersistentCollection.open_with_fields(
            path, _fields(), maintenance_library_path=""
        )
        _assert_query(reopened, False)
        reopened.close()
        var cached = PersistentCollection.open_with_fields(
            path, _fields(), maintenance_library_path=""
        )
        _assert_query(cached, True)
        cached.close()
        Python.import_module("shutil").rmtree(path)


def test_cache_corruption_wrong_identity_and_valid_crc_wrong_graph_are_misses() raises:
    var path = _path()
    _seed(path)
    var file = path + "/field-hnsw-3.cache"
    var saved = read_file_bytes(file)
    for mode in range(8):
        var bytes = saved.copy()
        if mode == 0:
            bytes[10] ^= UInt8(1)
        elif mode == 1:
            _ = bytes.pop()
        elif mode == 2:
            bytes = [UInt8(1)]
        else:
            var artifact = decode_cache_bytes(bytes^)
            if mode == 3:
                artifact.kind = 1
            elif mode == 4:
                artifact.generation = 2
            elif mode == 5:
                artifact.source_checksum ^= UInt32(1)
            else:
                var fields = _fields()
                var wrong = HnswIndex(fields[3].hnsw.value())
                for row in range(95, -1, -1):
                    wrong.add(
                        -row if mode == 6 else 1000 - row,
                        [Float32(row + 1), Float32(row % 9)],
                    )
                artifact.payload = encode_hnsw_snapshot(wrong, 0)
            bytes = encode_cache(artifact)
        write_file_sync(file, bytes)
        var collection = PersistentCollection.open_with_fields(
            path, _fields(), maintenance_library_path=""
        )
        _assert_query(collection, False)
        collection.close()
    Python.import_module("shutil").rmtree(path)


def test_changed_field_identity_and_multirun_publication_are_rejected() raises:
    var path = _path()
    _seed(path)
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _assert_query(collection, True)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    for mode in range(3):
        var fields = _fields()
        if mode == 0:
            fields[3].name = "different"
        elif mode == 1:
            fields[3].scalar = 3
        else:
            fields[3].hnsw.value().level_seed += 1
        assert_true(
            not Bool(
                load_field_hnsw_cache(path, root[].run(0).memtable, fields[3])
            )
        )
    var saved = read_file_bytes(path + "/field-hnsw-3.cache")
    var changes: List[FieldUpdate] = [FieldUpdate.set(3, _query())]
    var batch: List[PointMutation] = [PointMutation(-999, 1, changes^)]
    _ = collection.apply_point_batch(batch)
    _ = collection.search_field("audio", _query(), 7, approximate=True)
    collection.flush()
    collection.close()
    assert_equal(read_file_bytes(path + "/field-hnsw-3.cache"), saved)
    # Held snapshots can query after close, and cannot replace the saved file.
    _ = snapshot.search_field(
        "image",
        VectorValue.dense[DType.float16](
            [Float16(1), Float16(1), Float16(1), Float16(1)]
        ),
        7,
        approximate=True,
    )
    assert_true(not path_exists(path + "/field-hnsw-2.cache"))
    assert_equal(read_file_bytes(path + "/field-hnsw-3.cache"), saved)
    Python.import_module("shutil").rmtree(path)


def test_failed_publication_does_not_fail_flush_and_can_retry() raises:
    var path = _path()
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _populate(collection)
    _assert_query(collection, False)
    var temporary = path + "/field-hnsw-3.cache.tmp"
    Python.import_module("os").mkdir(temporary)
    collection.flush()
    assert_true(not path_exists(path + "/field-hnsw-3.cache"))
    Python.import_module("os").rmdir(temporary)
    collection.flush()
    assert_true(path_exists(path + "/field-hnsw-3.cache"))
    collection.close()
    var reopened = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _assert_query(reopened, True)
    reopened.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def _roundtrip_codecs[dtype: DType]() raises:
    for metric in range(3):
        for scalar in range(4):
            if scalar == 3 and metric == 1:
                continue  # I8 graph L2 is intentionally unsupported.
            var path = _path()
            var fields = legacy_vector_fields(CollectionConfig.defaults(2))
            var config = CollectionConfig.defaults(4)
            config.ann_metric = MetricKind(UInt8(metric))
            config.scalar_kind = ScalarKind(UInt8(scalar))
            config.m = 4
            config.m0 = 8
            config.ef_construction = 32
            var query = VectorValue.dense[dtype](
                [
                    Scalar[dtype](3),
                    Scalar[dtype](2),
                    Scalar[dtype](1),
                    Scalar[dtype](4),
                ]
            )
            fields.append(
                VectorFieldSpec(
                    2,
                    "dense",
                    0,
                    query.scalar(),
                    UInt8(metric),
                    1,
                    4,
                    Optional(config^),
                )
            )
            var collection = PersistentCollection.open_with_fields(
                path, fields.copy(), maintenance_library_path=""
            )
            var batch = List[PointMutation]()
            for row in range(19):
                var value = VectorValue.dense[dtype](
                    [
                        Scalar[dtype](row + 1),
                        Scalar[dtype](row % 3 + 1),
                        Scalar[dtype](row % 7 + 1),
                        Scalar[dtype](1),
                    ]
                )
                batch.append(
                    PointMutation(100 - row, 1, [FieldUpdate.set(2, value^)])
                )
            _ = collection.apply_point_batch(batch)
            var before = collection.search_field(
                "dense", query, 3, approximate=True, ef_search=8
            )
            collection.flush()
            collection.close()
            var reopened = PersistentCollection.open_with_fields(
                path, fields^, maintenance_library_path=""
            )
            var after = reopened.search_field(
                "dense", query, 3, approximate=True, ef_search=8
            )
            assert_equal(len(before), len(after))
            for i in range(len(after)):
                assert_equal(after[i].id, before[i].id)
                assert_equal(
                    bitcast[DType.uint64](after[i].score),
                    bitcast[DType.uint64](before[i].score),
                )
            var snapshot = reopened.snapshot()
            var root = snapshot._acquire()
            assert_true(
                root[].run(0).field_hnsw[].get(2)[].ready.value()[].cache_hit
            )
            reopened.close()
            Python.import_module("shutil").rmtree(path)


def test_all_native_authority_types_and_supported_graph_codecs_roundtrip() raises:
    _roundtrip_codecs[DType.float32]()
    _roundtrip_codecs[DType.bfloat16]()
    _roundtrip_codecs[DType.float16]()
    _roundtrip_codecs[DType.int8]()
    _roundtrip_codecs[DType.uint8]()


def test_concurrent_first_queries_share_one_loaded_graph() raises:
    var path = _path()
    _seed(path)
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    var snapshot = collection.snapshot()
    var query = _query()
    var expected = snapshot.search_field("audio", query, 7)
    var failures = List[Int](length=8, fill=0)

    def search(
        index: Int,
    ) {imm snapshot, imm query, imm expected, mut failures}:
        try:
            var actual = snapshot.search_field(
                "audio", query, 7, approximate=True
            )
            assert_equal(len(actual), len(expected))
            for row in range(len(actual)):
                assert_equal(actual[row].id, expected[row].id)
                assert_equal(actual[row].score, expected[row].score)
        except:
            failures[index] += 1

    parallelize(search, 8, 8)
    for failure in failures:
        assert_equal(failure, 0)
    var root = snapshot._acquire()
    var state = root[].run(0).field_hnsw[].get(3)
    assert_equal(state[].build_count, 1)
    assert_true(state[].ready.value()[].cache_hit)
    collection.close()
    Python.import_module("shutil").rmtree(path)


def test_flush_skips_busy_builder_and_search_then_retries() raises:
    var path = _path()
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _populate(collection)
    _assert_query(collection, False)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var state = root[].run(0).field_hnsw[].get(3)
    # Same-thread ownership makes a blocking publication deterministically hang.
    # Neither a builder nor an in-flight search may hold up the writer for cache IO.
    with BlockingScopedLock(state[].lock):
        collection.flush()
    assert_true(not path_exists(path + "/field-hnsw-3.cache"))
    var graph = state[].ready.value().copy()
    with BlockingScopedLock(graph[].query_lock):
        collection.flush()
    assert_true(not path_exists(path + "/field-hnsw-3.cache"))
    collection.flush()
    assert_true(path_exists(path + "/field-hnsw-3.cache"))
    collection.close()
    Python.import_module("shutil").rmtree(path)


def test_close_skips_busy_graph_and_retained_snapshot_still_works() raises:
    var path = _path()
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _populate(collection)
    _assert_query(collection, False)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var state = root[].run(0).field_hnsw[].get(3)
    with BlockingScopedLock(state[].lock):
        collection.close()
    assert_true(not path_exists(path + "/field-hnsw-3.cache"))
    var actual = snapshot.search_field("audio", _query(), 7, approximate=True)
    assert_equal(len(actual), 7)
    Python.import_module("shutil").rmtree(path)
