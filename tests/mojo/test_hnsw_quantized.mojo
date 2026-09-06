from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.bitmap import Bitmap
from akasha.index.hnsw import HnswIndex
from akasha.index.flat import FlatIndex, SearchResult
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.storage.memtable import MemTable
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import (
    decode_hnsw_snapshot_owned,
    encode_hnsw_snapshot,
    hnsw_snapshot_eligibility,
    open_hnsw_snapshot_view,
    write_hnsw_snapshot,
)
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)
from std.collections import Dict


comptime _QUALITY_SEED = UInt64(0xA5A5D00D12345678)
comptime _QUALITY_POINT_COUNT = 256
comptime _QUALITY_DIMENSION = 16
comptime _QUALITY_QUERY_COUNT = 12
comptime _QUALITY_K = 10
comptime _QUALITY_EF_SEARCH = 64


struct _SplitMix64(Movable):
    """Task 1's deterministic benchmark generator."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_u64(mut self) -> UInt64:
        self.state += UInt64(0x9E3779B97F4A7C15)
        var value = self.state
        value = (value ^ (value >> 30)) * UInt64(0xBF58476D1CE4E5B9)
        value = (value ^ (value >> 27)) * UInt64(0x94D049BB133111EB)
        return value ^ (value >> 31)

    def uniform_signed(mut self) -> Float32:
        var bits = UInt32(self.next_u64() & UInt64(0x00FFFFFF))
        return Float32(bits) / 8_388_608.0 - 1.0


struct _QualityCell(Movable):
    var f32_recall: Float64
    var compact_recall: Float64

    def __init__(out self, f32_recall: Float64, compact_recall: Float64):
        self.f32_recall = f32_recall
        self.compact_recall = compact_recall


def _u16_at(bytes: List[UInt8], offset: Int) -> UInt16:
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << UInt16(8))


def _u64_at(bytes: List[UInt8], offset: Int) -> UInt64:
    var result = UInt64(0)
    for index in range(8):
        result |= UInt64(bytes[offset + index]) << UInt64(index * 8)
    return result


def _put_u16(mut bytes: List[UInt8], offset: Int, value: UInt16):
    for index in range(2):
        bytes[offset + index] = UInt8(value >> UInt16(index * 8))


def _put_u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for index in range(4):
        bytes[offset + index] = UInt8(value >> UInt32(index * 8))


def _put_u64(mut bytes: List[UInt8], offset: Int, value: UInt64):
    for index in range(8):
        bytes[offset + index] = UInt8(value >> UInt64(index * 8))


def _seal(mut bytes: List[UInt8]):
    var checksum_offset = len(bytes) - 4
    _put_u32(bytes, checksum_offset, crc32_range(bytes, 0, checksum_offset))


def _assert_owned_and_mapped_reject(
    path: String,
    bytes: List[UInt8],
    config: CollectionConfig,
    sequence: UInt64,
) raises:
    remove_file_if_exists(path)
    write_file_sync(path, bytes)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bytes.copy(), config, sequence)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, sequence)


def _config(metric: MetricKind, scalar: ScalarKind) -> CollectionConfig:
    var config = CollectionConfig.defaults(16)
    config.ann_metric = metric.copy()
    config.scalar_kind = scalar.copy()
    config.m = 8
    config.m0 = 16
    config.ef_construction = 64
    config.default_ef_search = 32
    config.max_ef_search = 256
    config.max_level = 8
    config.level_seed = UInt64(0xA5A5A5A5A5A5A5A5)
    return config^


def _vector(id: Int) -> List[Float32]:
    var values = List[Float32](capacity=16)
    for column in range(16):
        values.append(
            Float32((id * 17 + column * 29 + id * column * 3) % 101) / 13.0
            - 3.0
        )
    return values^


def _graph(config: CollectionConfig, count: Int = 96) raises -> HnswIndex:
    var index = HnswIndex(config)
    for id in range(count):
        index.add(id + 1, _vector(id + 1))
    index.validate_structure()
    return index^


def _assert_same_results(
    expected: List[SearchResult], actual: List[SearchResult], tolerance: Float64
) raises:
    assert_equal(len(actual), len(expected))
    for index in range(len(expected)):
        assert_equal(actual[index].id, expected[index].id)
        assert_almost_equal(
            actual[index].score, expected[index].score, atol=tolerance
        )


def _recall_at_10(
    expected: List[SearchResult], actual: List[SearchResult]
) -> Float64:
    var hits = 0
    for target in expected:
        for candidate in actual:
            if candidate.id == target.id:
                hits += 1
                break
    return Float64(hits) / 10.0


def _quality_vector(
    mut rng: _SplitMix64, point_id: Int, clustered: Bool
) -> List[Float32]:
    var values = List[Float32](capacity=_QUALITY_DIMENSION)
    if not clustered:
        for _ in range(_QUALITY_DIMENSION):
            values.append(rng.uniform_signed())
        return values^
    var cluster = point_id % 8
    for component in range(_QUALITY_DIMENSION):
        var center = Float32(0.0)
        if component % 8 == cluster:
            center = 0.75
        elif component % 8 == (cluster + 1) % 8:
            center = -0.75
        values.append(center + rng.uniform_signed() * 0.08)
    return values^


def _quality_config(
    metric: MetricKind, scalar: ScalarKind
) -> CollectionConfig:
    var config = CollectionConfig.defaults(_QUALITY_DIMENSION)
    config.ann_metric = metric.copy()
    config.scalar_kind = scalar.copy()
    config.m = 24
    config.m0 = 48
    config.ef_construction = 192
    config.max_level = 16
    return config^


def _exact_quality_search(
    index: FlatIndex, metric: MetricKind, query: List[Float32]
) raises -> List[SearchResult]:
    if metric == MetricKind.dot():
        return index.search_dot(query, _QUALITY_K)
    if metric == MetricKind.l2():
        return index.search_l2(query, _QUALITY_K)
    return index.search_cosine(query, _QUALITY_K)


def _quality_lookup(table: MemTable) raises -> HnswIdOrdinalLookup:
    var ordinals = Dict[Int, Int]()
    for ordinal in range(table.slot_count()):
        ordinals[table.id_at(ordinal)] = ordinal
    return HnswIdOrdinalLookup(ordinals^, table.slot_count())


def _measure_direct_quality_cell(
    metric: MetricKind, scalar: ScalarKind, clustered: Bool
) raises -> _QualityCell:
    var rng = _SplitMix64(_QUALITY_SEED)
    var exact = FlatIndex(_QUALITY_DIMENSION)
    var baseline = HnswIndex(_quality_config(metric, ScalarKind.f32()))
    var compact = HnswIndex(_quality_config(metric, scalar))
    for point_id in range(_QUALITY_POINT_COUNT):
        var values = _quality_vector(rng, point_id, clustered)
        baseline.add(point_id, values.copy())
        compact.add(point_id, values.copy())
        exact.add(point_id, values^)

    var f32_recall = Float64(0.0)
    var compact_recall = Float64(0.0)
    for query_id in range(_QUALITY_QUERY_COUNT):
        var query = _quality_vector(
            rng, _QUALITY_POINT_COUNT + query_id, clustered
        )
        var ground_truth = _exact_quality_search(exact, metric, query.copy())
        var f32_results = baseline.search(
            query.copy(), _QUALITY_K, ef_search=_QUALITY_EF_SEARCH
        )
        var compact_results = compact.search(
            query^, _QUALITY_K, ef_search=_QUALITY_EF_SEARCH
        )
        f32_recall += _recall_at_10(ground_truth, f32_results)
        compact_recall += _recall_at_10(ground_truth, compact_results)
    return _QualityCell(
        f32_recall / Float64(_QUALITY_QUERY_COUNT),
        compact_recall / Float64(_QUALITY_QUERY_COUNT),
    )


def _measure_production_quality_cell(
    metric: MetricKind, scalar: ScalarKind, clustered: Bool
) raises -> _QualityCell:
    var rng = _SplitMix64(_QUALITY_SEED)
    var exact = FlatIndex(_QUALITY_DIMENSION)
    var table = MemTable(_QUALITY_DIMENSION)
    var baseline_graph = HnswIndex(
        _quality_config(metric, ScalarKind.f32())
    )
    var compact_graph = HnswIndex(_quality_config(metric, scalar))
    for point_id in range(_QUALITY_POINT_COUNT):
        var values = _quality_vector(rng, point_id, clustered)
        table.apply_upsert(
            point_id, UInt64(point_id + 1), values.copy()
        )
        baseline_graph.add(point_id, values.copy())
        compact_graph.add(point_id, values.copy())
        exact.add(point_id, values^)

    var baseline = SegmentedHnsw.from_owned(baseline_graph^)
    var compact = SegmentedHnsw.from_owned(compact_graph^)
    var lookup = _quality_lookup(table)
    var f32_recall = Float64(0.0)
    var compact_recall = Float64(0.0)
    for query_id in range(_QUALITY_QUERY_COUNT):
        var query = _quality_vector(
            rng, _QUALITY_POINT_COUNT + query_id, clustered
        )
        var ground_truth = _exact_quality_search(exact, metric, query.copy())
        var f32_results = baseline.search(
            query.copy(), _QUALITY_K, _QUALITY_EF_SEARCH, table, lookup
        )
        var compact_results = compact.search(
            query^, _QUALITY_K, _QUALITY_EF_SEARCH, table, lookup
        )
        assert_equal(compact.last_search_query_preparations(), 1)
        assert_true(compact.last_search_stats().distance_evaluations > 1)
        assert_true(
            compact.last_search_stats().reranked_candidates >= _QUALITY_K
        )
        assert_equal(
            compact.last_search_stats().storage_name,
            String("segmented-", scalar.name()),
        )
        f32_recall += _recall_at_10(ground_truth, f32_results)
        compact_recall += _recall_at_10(ground_truth, compact_results)
    return _QualityCell(
        f32_recall / Float64(_QUALITY_QUERY_COUNT),
        compact_recall / Float64(_QUALITY_QUERY_COUNT),
    )


def test_compact_scalars_write_v2_with_exact_vector_widths() raises:
    var kinds: List[ScalarKind] = [
        ScalarKind.bf16(), ScalarKind.f16(), ScalarKind.i8()
    ]
    for scalar in kinds:
        var config = _config(MetricKind.dot(), scalar)
        var graph = _graph(config, 12)
        var first = encode_hnsw_snapshot(graph, UInt64(7))
        var second = encode_hnsw_snapshot(graph, UInt64(7))
        assert_equal(first, second)
        assert_equal(_u16_at(first, 4), UInt16(2))
        assert_equal(_u16_at(first, 8), UInt16(192))
        var width = 1 if scalar == ScalarKind.i8() else 2
        assert_equal(_u64_at(first, 112), UInt64(12 * 16 * width))
        assert_equal(first[152], UInt8(width))
        var vector_bytes_per_point = Int(_u64_at(first, 112)) // 12
        var scale_bytes_per_point = Int(_u64_at(first, 168)) // 12
        if scalar == ScalarKind.i8():
            assert_equal(first[153], UInt8(4))
            assert_equal(_u64_at(first, 168), UInt64(12 * 4))
            assert_equal(vector_bytes_per_point, 16)
            assert_equal(scale_bytes_per_point, 4)
            assert_equal(vector_bytes_per_point + scale_bytes_per_point, 20)
        else:
            assert_equal(first[153], UInt8(0))
            assert_equal(_u64_at(first, 168), UInt64(0))
            assert_equal(vector_bytes_per_point, 32)
            assert_equal(scale_bytes_per_point, 0)
        print(
            "compact-size scalar=", scalar.name(),
            " raw-vector-bytes/point=", vector_bytes_per_point,
            " scale-bytes/point=", scale_bytes_per_point,
            " actual-compact-payload-bytes/point=",
            vector_bytes_per_point + scale_bytes_per_point,
            " f32-vector-bytes/point=", 64,
        )


def test_compact_graphs_are_sidecar_eligible() raises:
    var kinds: List[ScalarKind] = [
        ScalarKind.bf16(), ScalarKind.f16(), ScalarKind.i8()
    ]
    for scalar in kinds:
        var graph = _graph(_config(MetricKind.dot(), scalar), 12)
        var eligibility = hnsw_snapshot_eligibility(graph, UInt64.MAX)
        assert_true(eligibility.eligible)
        assert_equal(
            eligibility.encoded_bytes,
            UInt64(len(encode_hnsw_snapshot(graph, UInt64(1)))),
        )


def test_compact_owned_and_mapped_queries_are_equivalent() raises:
    var directory = String("/tmp/akasha-hnsw-v2-query")
    ensure_directory(directory)
    var kinds: List[ScalarKind] = [
        ScalarKind.bf16(), ScalarKind.f16(), ScalarKind.i8()
    ]
    for scalar in kinds:
        var path = directory + "/" + scalar.name() + ".bin"
        remove_file_if_exists(path)
        var config = _config(MetricKind.cosine(), scalar)
        var graph = _graph(config)
        var query = _vector(177)
        var expected = graph.search(query, 10, ef_search=64)
        var bytes = encode_hnsw_snapshot(graph, UInt64(11))
        var owned = decode_hnsw_snapshot_owned(
            bytes^, config, UInt64(11)
        )
        var owned_results = owned.search(query, 10, ef_search=64)
        _ = write_hnsw_snapshot(path, graph, UInt64(11))
        var mapped = open_hnsw_snapshot_view(path, config, UInt64(11))
        var mapped_results = mapped.search(query, 10, ef_search=64)
        _assert_same_results(expected, owned_results, 1.0e-5)
        _assert_same_results(expected, mapped_results, 1.0e-5)
        assert_equal(graph.last_search_query_preparations(), 1)
        assert_equal(owned.last_search_query_preparations(), 1)
        assert_equal(mapped.last_search_query_preparations(), 1)
        assert_true(graph.last_search_stats.distance_evaluations > 1)
        assert_true(owned.last_search_stats.distance_evaluations > 1)
        assert_true(mapped.last_search_stats().distance_evaluations > 1)
        mapped.close()


def test_segmented_base_and_delta_prepare_once_for_all_scalar_backends() raises:
    var kinds: List[ScalarKind] = [
        ScalarKind.f32(),
        ScalarKind.bf16(),
        ScalarKind.f16(),
        ScalarKind.i8(),
    ]
    for scalar in kinds:
        for mapped_base in [False, True]:
            var config = _config(MetricKind.dot(), scalar)
            var table = MemTable(config.dimension)
            var exact = FlatIndex(config.dimension)
            var base = HnswIndex(config)
            for id in range(1, 17):
                var values = _vector(id)
                table.apply_upsert(id, UInt64(id), values.copy())
                exact.add(id, values.copy())
                base.add(id, values^)

            var segmented: SegmentedHnsw
            if mapped_base:
                var path = (
                    String("/tmp/akasha-hnsw-segmented-")
                    + scalar.name()
                    + "-mapped.bin"
                )
                remove_file_if_exists(path)
                _ = write_hnsw_snapshot(path, base, UInt64(31))
                var view = open_hnsw_snapshot_view(path, config, UInt64(31))
                segmented = SegmentedHnsw.from_mapped(view^)
            else:
                segmented = SegmentedHnsw.from_owned(base^)

            for id in range(17, 25):
                var values = _vector(id)
                table.apply_upsert(id, UInt64(id), values.copy())
                exact.add(id, values.copy())
                segmented.upsert(id, values^)

            var lookup = _quality_lookup(table)
            var query = _vector(177)
            var expected = exact.search_dot(query.copy(), 10)
            var actual = segmented.search(
                query.copy(), 10, 64, table, lookup
            )
            _assert_same_results(expected, actual, 1.0e-6)
            assert_equal(segmented.last_search_query_preparations(), 1)
            assert_true(
                segmented.last_search_stats().distance_evaluations > 1
            )

            var bitmap = Bitmap(table.slot_count())
            for ordinal in range(table.slot_count()):
                bitmap.set(ordinal)
            var allowed = HnswEligibility(bitmap^, lookup)
            var filtered = segmented.search_allowed(
                query^, 10, 64, 64, allowed, table, lookup
            )
            _assert_same_results(expected, filtered, 1.0e-6)
            assert_equal(segmented.last_search_query_preparations(), 1)
            assert_true(
                segmented.last_search_stats().distance_evaluations > 1
            )
            segmented.close()


def test_compact_mapped_distance_requires_bound_dispatcher_identity() raises:
    var directory = String("/tmp/akasha-hnsw-v2-dispatcher-identity")
    ensure_directory(directory)
    var path = directory + "/f16-dot.bin"
    remove_file_if_exists(path)
    var config = _config(MetricKind.dot(), ScalarKind.f16())
    var graph = _graph(config, 12)
    _ = write_hnsw_snapshot(path, graph, UInt64(12))
    var mapped = open_hnsw_snapshot_view(path, config, UInt64(12))

    var wrong_metric = MetricDispatcher(
        MetricKind.l2(), ScalarKind.f16(), config.dimension
    )
    var wrong_metric_query = wrong_metric.prepare_query(_vector(177))
    with assert_raises():
        _ = mapped.distance_to_slot(
            wrong_metric, wrong_metric_query, UInt32(0)
        )

    var wrong_scalar = MetricDispatcher(
        MetricKind.dot(), ScalarKind.f32(), config.dimension
    )
    var wrong_scalar_query = wrong_scalar.prepare_query(_vector(177))
    with assert_raises():
        _ = mapped.distance_to_slot(
            wrong_scalar, wrong_scalar_query, UInt32(0)
        )
    mapped.close()


def test_compact_owned_graphs_keep_only_compact_vector_tapes() raises:
    var kinds: List[ScalarKind] = [
        ScalarKind.bf16(), ScalarKind.f16(), ScalarKind.i8()
    ]
    for scalar in kinds:
        var config = _config(MetricKind.dot(), scalar)
        var graph = _graph(config, 12)
        assert_equal(len(graph.graph.vector_scalars), 0)
        var width = 1 if scalar == ScalarKind.i8() else 2
        assert_equal(len(graph.graph.vector_bytes), 12 * 16 * width)
        assert_equal(
            len(graph.graph.vector_scales),
            12 if scalar == ScalarKind.i8() else 0,
        )
        var decoded = decode_hnsw_snapshot_owned(
            encode_hnsw_snapshot(graph, UInt64(17)), config, UInt64(17)
        )
        assert_equal(len(decoded.graph.vector_scalars), 0)
        assert_equal(len(decoded.graph.vector_bytes), 12 * 16 * width)


def test_i8_cosine_uses_fixed_scale_without_owned_or_durable_scale_tape() raises:
    var directory = String("/tmp/akasha-hnsw-v2-i8-cosine-fixed-scale")
    ensure_directory(directory)
    var path = directory + "/valid.bin"
    remove_file_if_exists(path)
    var config = _config(MetricKind.cosine(), ScalarKind.i8())
    var graph = _graph(config, 12)
    assert_equal(len(graph.graph.vector_bytes), 12 * 16)
    assert_equal(len(graph.graph.vector_scales), 0)

    var bytes = encode_hnsw_snapshot(graph, UInt64(41))
    assert_equal(bytes[152], UInt8(1))
    assert_equal(bytes[153], UInt8(0))
    assert_equal(_u64_at(bytes, 112), UInt64(12 * 16))
    assert_equal(_u64_at(bytes, 168), UInt64(0))
    var query = _vector(177)
    var expected = graph.search(query.copy(), 10, ef_search=64)
    var owned = decode_hnsw_snapshot_owned(
        bytes.copy(), config, UInt64(41)
    )
    assert_equal(len(owned.graph.vector_scales), 0)
    _assert_same_results(
        expected, owned.search(query.copy(), 10, ef_search=64), 1.0e-6
    )
    write_file_sync(path, bytes.copy())
    var mapped = open_hnsw_snapshot_view(path, config, UInt64(41))
    _assert_same_results(
        expected, mapped.search(query^, 10, ef_search=64), 1.0e-6
    )
    mapped.close()

    var bad_scale_width = bytes.copy()
    bad_scale_width[153] = UInt8(4)
    _seal(bad_scale_width)
    _assert_owned_and_mapped_reject(
        directory + "/bad-scale-width.bin",
        bad_scale_width^,
        config,
        UInt64(41),
    )

    var bad_scale_length = bytes.copy()
    _put_u64(bad_scale_length, 168, UInt64(4))
    _seal(bad_scale_length)
    _assert_owned_and_mapped_reject(
        directory + "/bad-scale-length.bin",
        bad_scale_length^,
        config,
        UInt64(41),
    )

    var zero_code_vector = bytes.copy()
    var first_vector = Int(_u64_at(zero_code_vector, 104))
    for component in range(config.dimension):
        zero_code_vector[first_vector + component] = UInt8(0)
    _seal(zero_code_vector)
    _assert_owned_and_mapped_reject(
        directory + "/zero-code-vector.bin",
        zero_code_vector^,
        config,
        UInt64(41),
    )


def test_v2_rejects_bad_versions_tags_widths_ranges_and_i8_codes() raises:
    var directory = String("/tmp/akasha-hnsw-v2-corrupt")
    ensure_directory(directory)
    var config = _config(MetricKind.dot(), ScalarKind.bf16())
    var valid = encode_hnsw_snapshot(_graph(config, 4), UInt64(18))

    var bad_checksum = valid.copy()
    bad_checksum[20] ^= UInt8(1)
    _assert_owned_and_mapped_reject(
        directory + "/bad-checksum.bin", bad_checksum^, config, UInt64(18)
    )

    var bad_version = valid.copy()
    _put_u16(bad_version, 4, UInt16(3))
    _seal(bad_version)
    _assert_owned_and_mapped_reject(
        directory + "/bad-version.bin", bad_version^, config, UInt64(18)
    )

    var bad_tag = valid.copy()
    bad_tag[37] = ScalarKind.i8().tag()
    _seal(bad_tag)
    _assert_owned_and_mapped_reject(
        directory + "/bad-tag.bin", bad_tag^, config, UInt64(18)
    )

    var bad_width = valid.copy()
    bad_width[152] = UInt8(1)
    _seal(bad_width)
    _assert_owned_and_mapped_reject(
        directory + "/bad-width.bin", bad_width^, config, UInt64(18)
    )

    var bad_length = valid.copy()
    _put_u64(bad_length, 112, _u64_at(bad_length, 112) + UInt64(1))
    _seal(bad_length)
    _assert_owned_and_mapped_reject(
        directory + "/bad-length.bin", bad_length^, config, UInt64(18)
    )

    var bad_offset = valid.copy()
    _put_u64(bad_offset, 104, UInt64.MAX)
    _seal(bad_offset)
    _assert_owned_and_mapped_reject(
        directory + "/bad-offset.bin", bad_offset^, config, UInt64(18)
    )

    var i8_config = _config(MetricKind.dot(), ScalarKind.i8())
    var valid_i8 = encode_hnsw_snapshot(_graph(i8_config, 4), UInt64(18))

    var bad_scale_width = valid_i8.copy()
    bad_scale_width[153] = UInt8(0)
    _seal(bad_scale_width)
    _assert_owned_and_mapped_reject(
        directory + "/bad-scale-width.bin",
        bad_scale_width^,
        i8_config,
        UInt64(18),
    )

    var bad_scale_length = valid_i8.copy()
    _put_u64(
        bad_scale_length, 168, _u64_at(bad_scale_length, 168) + UInt64(4)
    )
    _seal(bad_scale_length)
    _assert_owned_and_mapped_reject(
        directory + "/bad-scale-length.bin",
        bad_scale_length^,
        i8_config,
        UInt64(18),
    )

    var bad_scale_alignment = valid_i8.copy()
    _put_u64(
        bad_scale_alignment, 160, _u64_at(bad_scale_alignment, 160) + UInt64(1)
    )
    _seal(bad_scale_alignment)
    _assert_owned_and_mapped_reject(
        directory + "/bad-scale-alignment.bin",
        bad_scale_alignment^,
        i8_config,
        UInt64(18),
    )

    var overlapping_scale = valid_i8.copy()
    _put_u64(overlapping_scale, 160, _u64_at(overlapping_scale, 104))
    _seal(overlapping_scale)
    _assert_owned_and_mapped_reject(
        directory + "/overlapping-scale.bin",
        overlapping_scale^,
        i8_config,
        UInt64(18),
    )

    var bad_i8 = valid_i8.copy()
    bad_i8[Int(_u64_at(bad_i8, 104))] = UInt8(0x80)
    _seal(bad_i8)
    _assert_owned_and_mapped_reject(
        directory + "/bad-i8-code.bin", bad_i8^, i8_config, UInt64(18)
    )

    var zero_scale_with_code = valid_i8.copy()
    _put_u32(
        zero_scale_with_code,
        Int(_u64_at(zero_scale_with_code, 160)),
        UInt32(0),
    )
    _seal(zero_scale_with_code)
    _assert_owned_and_mapped_reject(
        directory + "/zero-scale-with-code.bin",
        zero_scale_with_code^,
        i8_config,
        UInt64(18),
    )


def test_direct_compact_graph_quality_matrix_is_diagnostic() raises:
    var kinds: List[ScalarKind] = [
        ScalarKind.bf16(), ScalarKind.f16(), ScalarKind.i8()
    ]
    for scalar in kinds:
        for metric in [
            MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()
        ]:
            if scalar == ScalarKind.i8() and metric == MetricKind.l2():
                continue
            for clustered in [False, True]:
                var cell = _measure_direct_quality_cell(
                    metric, scalar, clustered
                )
                var loss = cell.f32_recall - cell.compact_recall
                print(
                    "compact-quality dataset=",
                    "eight-cluster" if clustered else "uniform",
                    " metric=", metric.name(),
                    " scalar=", scalar.name(),
                    " f32-recall@10=", cell.f32_recall,
                    " compact-recall@10=", cell.compact_recall,
                    " recall-loss=", loss,
                )


def test_production_rerank_compact_scalar_recall_loss_gate() raises:
    var kinds: List[ScalarKind] = [
        ScalarKind.bf16(), ScalarKind.f16(), ScalarKind.i8()
    ]
    for scalar in kinds:
        for metric in [
            MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()
        ]:
            if scalar == ScalarKind.i8() and metric == MetricKind.l2():
                continue
            for clustered in [False, True]:
                var cell = _measure_production_quality_cell(
                    metric, scalar, clustered
                )
                var loss = cell.f32_recall - cell.compact_recall
                print(
                    "compact-production-quality dataset=",
                    "eight-cluster" if clustered else "uniform",
                    " metric=", metric.name(),
                    " scalar=", scalar.name(),
                    " f32-recall@10=", cell.f32_recall,
                    " compact-recall@10=", cell.compact_recall,
                    " recall-loss=", loss,
                )
                assert_true(loss <= 0.02)


def test_i8_l2_remains_rejected() raises:
    var config = _config(MetricKind.l2(), ScalarKind.i8())
    with assert_raises():
        _ = HnswIndex(config)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
