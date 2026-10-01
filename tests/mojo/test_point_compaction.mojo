from akasha.common.config import CollectionConfig
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.storage.point_store import PointStore
from akasha.storage.committed_compaction import (
    capture_compaction_inputs,
    build_compaction_output,
    publish_compaction_output,
    discard_compaction_output,
)
from akasha.storage.manifest import load_manifest
from akasha.storage.filesystem import (
    path_exists,
    read_file_bytes,
    write_file_sync,
)
from akasha.storage.committed_compaction import (
    begin_compaction,
    build_compaction,
    finish_compaction,
)
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.read_generation import ReadGenerationCache
from akasha.storage.retired_files import RetiredFileQueue
from std.memory import ArcPointer
from std.ffi import c_int, external_call
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def _path(suffix: String) -> String:
    return String(
        "/tmp/akasha-point-compaction-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
    )


def _fields() raises -> List[VectorFieldSpec]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "native", 0, 2, 0, 0, 2))
    return fields^


def _write(mut store: PointStore, id: Int, value: Float16) raises:
    var batch: List[PointMutation] = [
        PointMutation(
            id,
            1,
            [
                FieldUpdate.set(
                    2, VectorValue.dense[DType.float16]([value, Float16(0)])
                )
            ],
        )
    ]
    _ = store.apply_batch(batch)
    store.flush()


def test_point_compaction_rebases_over_later_delta_and_preserves_wal() raises:
    var path = _path("rebase")
    var store = PointStore.open(path, _fields())
    _write(store, 1, 1)
    _write(store, 2, 2)
    var captured = capture_compaction_inputs(path, 2)
    assert_true(Bool(captured))
    var output = build_compaction_output(path, 2, captured.value())
    assert_equal(output.sparse_name, "")
    _write(store, 3, 3)
    var tail: List[PointMutation] = [PointMutation.delete(1)]
    _ = store.apply_batch(tail)
    var wal = read_file_bytes(path + "/wal.bin")
    assert_true(
        Bool(publish_compaction_output(path, 2, captured.value(), output))
    )
    assert_equal(read_file_bytes(path + "/wal.bin"), wal)
    var published = load_manifest(path, 2)
    assert_equal(len(published.segments), 2)
    assert_equal(published.segments[0].sparse_name, "")
    assert_equal(published.last_sequence, UInt64(3))
    # A later checkpoint must use the rebased manifest, never the stale capture.
    store.flush()
    assert_equal(load_manifest(path, 2).segments[0].name, output.segment_name)
    store.close()
    var reopened = PointStore.open(path, _fields())
    assert_false(Bool(reopened.get(1)))
    assert_equal(
        reopened.get(2)
        .value()
        .field_at(0)
        .value()
        .dense_values[DType.float16]()[0],
        Float16(2),
    )
    assert_equal(
        reopened.get(3)
        .value()
        .field_at(0)
        .value()
        .dense_values[DType.float16]()[0],
        Float16(3),
    )
    assert_equal(reopened.last_sequence(), UInt64(4))
    reopened.close()


def test_point_compaction_discards_only_its_own_output_when_inputs_replaced() raises:
    var path = _path("conflict")
    var store = PointStore.open(path, _fields())
    _write(store, 1, 1)
    _write(store, 2, 2)
    var captured = capture_compaction_inputs(path, 2)
    var output = build_compaction_output(path, 2, captured.value())
    store.compact()
    var manifest = read_file_bytes(path + "/manifest.bin")
    assert_false(
        Bool(publish_compaction_output(path, 2, captured.value(), output))
    )
    discard_compaction_output(path, output)
    assert_false(path_exists(path + "/" + output.segment_name))
    assert_true(path_exists(path))
    assert_equal(read_file_bytes(path + "/manifest.bin"), manifest)
    store.close()


def test_point_compaction_corruption_does_not_publish_or_modify_sources() raises:
    var path = _path("corrupt")
    var store = PointStore.open(path, _fields())
    _write(store, 1, 1)
    _write(store, 2, 2)
    var captured = capture_compaction_inputs(path, 2)
    var source = path + "/" + captured.value().manifest.segments[1].name
    var bytes = read_file_bytes(source)
    bytes[len(bytes) - 1] ^= 1
    write_file_sync(source, bytes)
    var manifest = read_file_bytes(path + "/manifest.bin")
    with assert_raises():
        _ = build_compaction_output(path, 2, captured.value())
    assert_equal(read_file_bytes(path + "/manifest.bin"), manifest)
    assert_equal(read_file_bytes(source), bytes)
    store.close()


def test_point_compaction_uses_existing_generation_leases_and_publication() raises:
    var path = _path("leases")
    var store = PointStore.open(path, _fields())
    _write(store, 1, 1)
    _write(store, 2, 2)
    var pins = ArcPointer(GenerationPinRegistry(path, 2))
    var cache = ArcPointer(ReadGenerationCache())
    var retired = ArcPointer(RetiredFileQueue())
    var before = load_manifest(path, 2)
    pins[].pin(before.generation)
    var inputs = begin_compaction(path, 2, pins)
    var output = build_compaction(path, 2, inputs.value(), pins)
    assert_true(
        finish_compaction(
            path, 2, inputs.value(), output, False, pins, retired, cache
        )
    )
    assert_equal(cache[].generation, before.generation + 1)
    assert_equal(pins[].active_count(), 1)
    for index in range(len(before.segments)):
        assert_true(path_exists(path + "/" + before.segments[index].name))
    pins[].unpin(before.generation)
    for index in range(len(before.segments)):
        assert_false(path_exists(path + "/" + before.segments[index].name))
    assert_equal(pins[].cleanup_error(), "")
    store.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
