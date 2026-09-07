from akasha import (
    CollectionConfig,
    MetricKind,
    PersistentCollection,
    ScalarKind,
    SearchResult,
)


comptime _DATASET_SEED = 1_729


def _component(point_id: Int, salt: Int) -> Float32:
    return Float32(
        ((_DATASET_SEED + point_id + 1) * (salt * 17 + 11)) % 97 + 1
    ) / 97.0


def _vector(point_id: Int) -> List[Float32]:
    return [
        _component(point_id, 1),
        _component(point_id, 2),
        _component(point_id, 3),
        _component(point_id, 4),
    ]


def _assert_same_ids(
    left: List[SearchResult], right: List[SearchResult]
) raises:
    if len(left) != len(right):
        raise Error("reopened HNSW result count changed")
    for index in range(len(left)):
        if left[index].id != right[index].id:
            raise Error("reopened HNSW result IDs changed")


def main() raises:
    var path = String("/tmp/akasha-configured-hnsw-example")
    var config = CollectionConfig.defaults(4)
    config.ann_metric = MetricKind.cosine()
    config.scalar_kind = ScalarKind.bf16()
    config.m = 8
    config.m0 = 16
    config.ef_construction = 64
    config.default_ef_search = 48
    config.max_ef_search = 192
    config.max_level = 16
    config.level_seed = UInt64(0xC0DEC0DE12345678)

    var collection = PersistentCollection.open_with_config(path, config)
    for point_id in range(96):
        collection.upsert(point_id, _vector(point_id))

    var query: List[Float32] = [0.9, 0.4, 0.7, 0.2]
    var approximate = collection.search_cosine_approx(query, 5, 64)
    var approximate_stats = collection.last_search_stats()
    print(
        "approx",
        approximate_stats.backend_name,
        approximate_stats.metric_name,
        approximate_stats.scalar_name,
        approximate_stats.storage_name,
        "ef",
        approximate_stats.effective_ef,
        "visited",
        approximate_stats.upper_visited + approximate_stats.base_visited,
        "distances",
        approximate_stats.distance_evaluations,
    )

    var mismatched = collection.search_l2_approx(query, 5, 64)
    var mismatch_stats = collection.last_search_stats()
    print(
        "mismatched metric planner",
        collection.last_dense_plan_reason(),
        "backend",
        mismatch_stats.backend_name,
        "storage",
        mismatch_stats.storage_name,
    )

    collection.flush()
    collection.close()

    var reopened = PersistentCollection.open_with_config(path, config)
    var reopened_approximate = reopened.search_cosine_approx(query, 5, 64)
    _assert_same_ids(approximate, reopened_approximate)
    var reopened_mismatched = reopened.search_l2_approx(query, 5, 64)
    _assert_same_ids(mismatched, reopened_mismatched)
    print(
        "reopen verified",
        len(reopened_approximate),
        "results with config fingerprint",
        reopened.collection_config().fingerprint(),
    )
    reopened.close()
