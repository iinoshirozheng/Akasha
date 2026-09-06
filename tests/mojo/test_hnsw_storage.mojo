from akasha.common.config import I8_MAX_SAFE_DIMENSION, MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_storage import (
    _validate_append_slot_count,
    HNSW_EMPTY_NEIGHBOR,
    HnswStorage,
)
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _vector(a: Float32, b: Float32, c: Float32) -> List[Float32]:
    var values: List[Float32] = [a, b, c]
    return values^


def _valid_graph() raises -> HnswStorage:
    var graph = HnswStorage(3, 2, 4)
    var a = _vector(1.0, 2.0, 3.0)
    var b = _vector(4.0, 5.0, 6.0)
    _ = graph.append(1, a^, 0)
    _ = graph.append(2, b^, 1)
    var links: List[UInt32] = [UInt32(1)]
    graph.set_neighbors(UInt32(0), 0, links^)
    graph.validate_structure()
    return graph^


def test_append_uses_dense_slot_ordinals_and_flat_vectors() raises:
    var graph = HnswStorage(3, 2, 4)
    var first = _vector(1.0, 2.0, 3.0)
    var second = _vector(4.0, 5.0, 6.0)

    assert_equal(graph.append(10, first^, 0), UInt32(0))
    assert_equal(graph.append(-7, second^, 2), UInt32(1))
    assert_equal(graph.slot_count(), 2)
    assert_equal(graph.id_at(UInt32(0)), 10)
    assert_equal(graph.id_at(UInt32(1)), -7)
    assert_equal(graph.vector_offset(UInt32(0)), 0)
    assert_equal(graph.vector_offset(UInt32(1)), 3)
    assert_equal(graph.vector_value(UInt32(0), 2), Float32(3.0))
    assert_equal(graph.vector_value(UInt32(1), 0), Float32(4.0))
    assert_equal(len(graph.vector_scalars), 6)

    var first_lookup = graph.current_slot(10)
    var second_lookup = graph.current_slot(-7)
    assert_true(Bool(first_lookup))
    assert_true(Bool(second_lookup))
    assert_equal(first_lookup.value(), UInt32(0))
    assert_equal(second_lookup.value(), UInt32(1))
    assert_false(Bool(graph.current_slot(99)))


def test_level_capacities_and_neighbor_tapes_are_exactly_packed() raises:
    var graph = HnswStorage(3, 2, 4)
    var v0 = _vector(1.0, 0.0, 0.0)
    var v1 = _vector(0.0, 1.0, 0.0)
    _ = graph.append(1, v0^, 0)
    _ = graph.append(2, v1^, 3)

    assert_equal(graph.level(UInt32(0)), 0)
    assert_equal(graph.level(UInt32(1)), 3)
    assert_equal(graph.level_capacity(UInt32(0), 0), 4)
    assert_equal(graph.level_capacity(UInt32(1), 0), 4)
    assert_equal(graph.level_capacity(UInt32(1), 1), 2)
    assert_equal(graph.level_capacity(UInt32(1), 2), 2)
    assert_equal(graph.level_capacity(UInt32(1), 3), 2)
    assert_equal(graph.allocated_neighbor_slot_count(UInt32(0)), 4)
    assert_equal(graph.allocated_neighbor_slot_count(UInt32(1)), 10)
    assert_equal(len(graph.neighbor_slots), 14)
    assert_equal(len(graph.neighbor_counts), 5)
    assert_equal(len(graph.neighbor_bases), 2)
    assert_equal(len(graph.neighbor_count_bases), 2)
    for index in range(len(graph.neighbor_slots)):
        assert_equal(graph.neighbor_slots[index], HNSW_EMPTY_NEIGHBOR)


def test_neighbor_set_add_remove_and_duplicate_suppression() raises:
    var graph = HnswStorage(3, 2, 3)
    for id in range(5):
        var values = _vector(Float32(id), 1.0, 2.0)
        _ = graph.append(id, values^, 2)

    var initial: List[UInt32] = [UInt32(1), UInt32(2), UInt32(3)]
    graph.set_neighbors(UInt32(0), 0, initial^)
    assert_equal(graph.neighbor_count(UInt32(0), 0), 3)
    assert_equal(graph.neighbor_at(UInt32(0), 0, 0), UInt32(1))
    assert_equal(graph.neighbor_at(UInt32(0), 0, 2), UInt32(3))
    assert_true(graph.contains_neighbor(UInt32(0), 0, UInt32(2)))
    assert_false(graph.add_neighbor(UInt32(0), 0, UInt32(2)))
    with assert_raises():
        _ = graph.add_neighbor(UInt32(0), 0, UInt32(4))

    assert_true(graph.remove_neighbor(UInt32(0), 0, UInt32(2)))
    assert_false(graph.contains_neighbor(UInt32(0), 0, UInt32(2)))
    assert_equal(graph.neighbor_count(UInt32(0), 0), 2)
    assert_equal(graph.neighbor_at(UInt32(0), 0, 1), UInt32(3))
    assert_true(graph.add_neighbor(UInt32(0), 0, UInt32(4)))
    assert_equal(graph.neighbor_at(UInt32(0), 0, 2), UInt32(4))
    assert_false(graph.remove_neighbor(UInt32(0), 0, UInt32(2)))

    var upper: List[UInt32] = [UInt32(2), UInt32(3)]
    graph.set_neighbors(UInt32(1), 2, upper^)
    assert_equal(graph.neighbor_count(UInt32(1), 2), 2)


def test_replacement_and_delete_hide_stale_slots_but_keep_history() raises:
    var graph = HnswStorage(3, 2, 4)
    var original = _vector(1.0, 2.0, 3.0)
    assert_equal(graph.append(42, original^, 0), UInt32(0))
    assert_true(graph.is_current(UInt32(0)))

    assert_equal(graph.mark_replaced(42), UInt32(0))
    assert_false(graph.is_current(UInt32(0)))
    assert_true(graph.is_replaced(UInt32(0)))
    assert_false(graph.is_deleted(UInt32(0)))
    assert_false(Bool(graph.current_slot(42)))
    assert_equal(graph.id_at(UInt32(0)), 42)

    var replacement = _vector(3.0, 2.0, 1.0)
    assert_equal(graph.append(42, replacement^, 1), UInt32(1))
    assert_equal(graph.current_slot(42).value(), UInt32(1))
    assert_true(graph.is_current(UInt32(1)))
    assert_true(graph.mark_deleted(42))
    assert_false(graph.mark_deleted(42))
    assert_false(graph.is_current(UInt32(1)))
    assert_true(graph.is_deleted(UInt32(1)))
    assert_false(graph.is_replaced(UInt32(1)))
    assert_false(Bool(graph.current_slot(42)))

    var revived = _vector(9.0, 8.0, 7.0)
    assert_equal(graph.append(42, revived^, 0), UInt32(2))
    assert_equal(graph.current_slot(42).value(), UInt32(2))
    assert_equal(graph.id_at(UInt32(0)), 42)
    assert_equal(graph.id_at(UInt32(1)), 42)
    assert_equal(graph.id_at(UInt32(2)), 42)


def test_flat_storage_distance_access_does_not_materialize_vectors() raises:
    var graph = HnswStorage(3, 2, 4)
    var x = _vector(1.0, 2.0, 3.0)
    var y = _vector(4.0, 5.0, 6.0)
    _ = graph.append(1, x^, 0)
    _ = graph.append(2, y^, 0)

    var dot = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 3)
    var l2 = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 3)
    var query = _vector(1.0, 1.0, 1.0)
    assert_equal(graph.distance_to_slot(dot, query, UInt32(1)), Float32(-15.0))
    assert_equal(graph.distance_to_slot(l2, query, UInt32(1)), Float32(50.0))
    assert_equal(
        graph.distance_between(dot, UInt32(0), UInt32(1)), Float32(-32.0)
    )
    assert_equal(
        graph.distance_between(l2, UInt32(0), UInt32(1)), Float32(27.0)
    )


def test_flat_distances_match_dispatcher_for_prepared_vectors() raises:
    var raw_query = _vector(3.0, 4.0, 0.0)
    var raw_first = _vector(4.0, 0.0, 3.0)
    var raw_second = _vector(-1.0, 2.0, 2.0)

    var kinds: List[MetricKind] = [
        MetricKind.l2(),
        MetricKind.dot(),
        MetricKind.cosine(),
    ]
    for metric in kinds:
        var dispatcher = MetricDispatcher(metric, ScalarKind.f32(), 3)
        var prepared_query = dispatcher.prepare_query(raw_query.copy())
        var prepared_first = dispatcher.prepare_graph_vector(raw_first.copy())
        var prepared_second = dispatcher.prepare_graph_vector(raw_second.copy())
        var expected_query = dispatcher.canonical_prepared(
            prepared_query.copy(), prepared_first.copy()
        )
        var expected_between = dispatcher.canonical_prepared(
            prepared_first.copy(), prepared_second.copy()
        )

        var graph = HnswStorage(3, 2, 4)
        _ = graph.append(1, prepared_first^, 0)
        _ = graph.append(2, prepared_second^, 0)
        assert_equal(
            graph.distance_to_slot(dispatcher, prepared_query, UInt32(0)),
            expected_query,
        )
        assert_equal(
            graph.distance_between(dispatcher, UInt32(0), UInt32(1)),
            expected_between,
        )


def test_compact_storage_requires_matching_dispatcher_identity() raises:
    var dispatcher = MetricDispatcher(MetricKind.cosine(), ScalarKind.bf16(), 3)
    var graph = HnswStorage(
        3,
        2,
        4,
        scalar_kind=ScalarKind.bf16(),
        metric_kind=MetricKind.cosine(),
    )
    var raw = _vector(1.0, 0.0, 0.0)
    var stored = dispatcher.prepare_graph_vector(raw.copy())
    var query = dispatcher.prepare_query(raw^)
    _ = graph.append(1, stored^, 0)
    assert_equal(
        graph.distance_to_slot(dispatcher, query, UInt32(0)), Float32(0.0)
    )
    assert_equal(
        graph.distance_between(dispatcher, UInt32(0), UInt32(0)), Float32(0.0)
    )
    var wrong_scalar = MetricDispatcher(
        MetricKind.cosine(), ScalarKind.f32(), 3
    )
    with assert_raises():
        _ = graph.distance_to_slot(wrong_scalar, query.copy(), UInt32(0))
    var wrong_metric = MetricDispatcher(
        MetricKind.dot(), ScalarKind.bf16(), 3
    )
    with assert_raises():
        _ = graph.distance_between(wrong_metric, UInt32(0), UInt32(0))

    var i8_cosine = HnswStorage(
        3,
        2,
        4,
        scalar_kind=ScalarKind.i8(),
        metric_kind=MetricKind.cosine(),
    )
    with assert_raises():
        _ = i8_cosine.append(1, [127.0, 0.0, 0.0, 0.5], 0)
    with assert_raises():
        _ = i8_cosine.append(
            1, [0.0, 0.0, 0.0, Float32(1.0 / 127.0)], 0
        )

    var i8_dot = HnswStorage(
        3,
        2,
        4,
        scalar_kind=ScalarKind.i8(),
        metric_kind=MetricKind.dot(),
    )
    with assert_raises():
        _ = i8_dot.append(1, [1.0, 0.0, 0.0, 0.0], 0)


def test_constructor_append_and_access_bounds_are_checked() raises:
    with assert_raises():
        _ = HnswStorage(0, 2, 4)
    with assert_raises():
        _ = HnswStorage(4_294_967_296, 2, 4)
    with assert_raises():
        _ = HnswStorage(3, 0, 4)
    with assert_raises():
        _ = HnswStorage(3, 2, 0)
    with assert_raises():
        _ = HnswStorage(
            I8_MAX_SAFE_DIMENSION + 1,
            2,
            4,
            scalar_kind=ScalarKind.i8(),
            metric_kind=MetricKind.dot(),
        )

    var graph = HnswStorage(3, 2, 4)
    var short: List[Float32] = [1.0, 2.0]
    var good = _vector(1.0, 2.0, 3.0)
    with assert_raises():
        _ = graph.append(1, short^, 0)
    with assert_raises():
        _ = graph.append(1, good.copy(), -1)
    _ = graph.append(1, good^, 0)
    var duplicate = _vector(3.0, 2.0, 1.0)
    with assert_raises():
        _ = graph.append(1, duplicate^, 0)
    with assert_raises():
        _ = graph.id_at(UInt32(1))
    with assert_raises():
        _ = graph.level_capacity(UInt32(0), 1)
    with assert_raises():
        _ = graph.neighbor_at(UInt32(0), 0, 0)
    with assert_raises():
        _ = graph.vector_value(UInt32(0), 3)


def test_neighbor_validation_rejects_sentinel_invalid_and_duplicate_edges() raises:
    var graph = HnswStorage(3, 2, 4)
    for id in range(3):
        var values = _vector(Float32(id), 1.0, 2.0)
        _ = graph.append(id, values^, 1)

    var sentinel: List[UInt32] = [HNSW_EMPTY_NEIGHBOR]
    var out_of_range: List[UInt32] = [UInt32(9)]
    var self_edge: List[UInt32] = [UInt32(0)]
    var duplicates: List[UInt32] = [UInt32(1), UInt32(1)]
    var overflow: List[UInt32] = [
        UInt32(1),
        UInt32(2),
        UInt32(1),
        UInt32(2),
        UInt32(1),
    ]
    with assert_raises():
        graph.set_neighbors(UInt32(0), 0, sentinel^)
    with assert_raises():
        graph.set_neighbors(UInt32(0), 0, out_of_range^)
    with assert_raises():
        graph.set_neighbors(UInt32(0), 0, self_edge^)
    with assert_raises():
        graph.set_neighbors(UInt32(0), 0, duplicates^)
    with assert_raises():
        graph.set_neighbors(UInt32(0), 0, overflow^)
    with assert_raises():
        _ = graph.add_neighbor(UInt32(0), 0, HNSW_EMPTY_NEIGHBOR)
    with assert_raises():
        _ = graph.contains_neighbor(UInt32(0), 0, HNSW_EMPTY_NEIGHBOR)
    with assert_raises():
        _ = graph.remove_neighbor(UInt32(0), 0, UInt32(9))


def test_append_slot_limit_reserves_uint32_max_as_sentinel() raises:
    assert_equal(
        _validate_append_slot_count(UInt64(UInt32.MAX) - UInt64(1)),
        UInt32.MAX - UInt32(1),
    )
    with assert_raises():
        _ = _validate_append_slot_count(UInt64(UInt32.MAX))
    with assert_raises():
        _ = _validate_append_slot_count(UInt64(UInt32.MAX) + UInt64(1))


def test_validate_structure_rejects_every_truncated_or_extended_tape() raises:
    var vector_truncated = _valid_graph()
    _ = vector_truncated.vector_scalars.pop()
    with assert_raises():
        vector_truncated.validate_structure()

    var counts_truncated = _valid_graph()
    _ = counts_truncated.neighbor_counts.pop()
    with assert_raises():
        counts_truncated.validate_structure()

    var counts_extended = _valid_graph()
    counts_extended.neighbor_counts.append(UInt32(0))
    with assert_raises():
        counts_extended.validate_structure()

    var neighbors_truncated = _valid_graph()
    _ = neighbors_truncated.neighbor_slots.pop()
    with assert_raises():
        neighbors_truncated.validate_structure()

    var neighbors_extended = _valid_graph()
    neighbors_extended.neighbor_slots.append(HNSW_EMPTY_NEIGHBOR)
    with assert_raises():
        neighbors_extended.validate_structure()


def test_validate_structure_rejects_bad_bases_before_tape_indexing() raises:
    var neighbor_base = _valid_graph()
    neighbor_base.neighbor_bases[1] = Int.MAX
    with assert_raises():
        neighbor_base.validate_structure()

    var count_base = _valid_graph()
    count_base.neighbor_count_bases[1] = Int.MAX
    with assert_raises():
        count_base.validate_structure()


def test_validate_structure_rejects_excessive_count_and_mutated_config() raises:
    var excessive = _valid_graph()
    excessive.neighbor_counts[0] = UInt32(5)
    with assert_raises():
        excessive.validate_structure()

    var invalid_dimension = _valid_graph()
    invalid_dimension.dimension = 0
    with assert_raises():
        invalid_dimension.validate_structure()

    var invalid_m = _valid_graph()
    invalid_m.m = 0
    with assert_raises():
        invalid_m.validate_structure()

    var invalid_m0 = _valid_graph()
    invalid_m0.m0 = 4_294_967_296
    with assert_raises():
        invalid_m0.validate_structure()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
