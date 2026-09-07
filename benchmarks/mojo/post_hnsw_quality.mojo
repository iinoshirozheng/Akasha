from akasha import (
    BatchMutation,
    CollectionConfig,
    DocumentField,
    FilterCondition,
    FilterExpression,
    MetricKind,
    PayloadValue,
    PersistentCollection,
)
from akasha.common.config import ScalarKind
from akasha.index.flat import SearchResult
from akasha.index.hnsw_core import HnswEligibility
from akasha.query.index_evaluator import evaluate_expression
from hnsw_quality import SplitMix64, _query_vector, recall_at_k
from std.sys.arg import argv
from std.time import perf_counter_ns


# This diagnostic deliberately uses the production candidate seam outside the
# timed public search call. It never substitutes exact IDs for missing ANN IDs.
def _candidates(
    mut collection: PersistentCollection,
    query: List[Float32],
    k: Int,
    ef: Int,
    mode: Int,
    expression: FilterExpression,
) raises -> List[Int]:
    if mode == 0:
        return collection._hnsw._search_candidates(query, k, ef)
    var bitmap = evaluate_expression(collection._metadata, expression)
    if not collection._ensure_hnsw_id_lookup():
        raise Error("quality diagnostic requires a usable HNSW ID lookup")
    var allowed = HnswEligibility(bitmap^, collection._hnsw_id_lookup.value())
    return collection._hnsw._search_allowed_candidates(
        query,
        k,
        ef,
        collection._config.max_ef_search,
        allowed,
        collection._memtable,
    )


def _search(
    mut collection: PersistentCollection,
    query: List[Float32],
    k: Int,
    ef: Int,
    metric: Int,
    mode: Int,
    expression: FilterExpression,
    ann: Bool,
) raises -> List[SearchResult]:
    if metric == 0:
        if ann:
            if mode == 0:
                return collection.search_dot_approx(query, k, ef_search=ef)
            return collection.search_dot_approx_where(
                query, k, ef_search=ef, expression=expression
            )
        if mode == 0:
            return collection.search_dot(query, k)
        return collection.search_dot_where(query, k, expression)
    if metric == 1:
        if ann:
            if mode == 0:
                return collection.search_l2_approx(query, k, ef_search=ef)
            return collection.search_l2_approx_where(
                query, k, ef_search=ef, expression=expression
            )
        if mode == 0:
            return collection.search_l2(query, k)
        return collection.search_l2_where(query, k, expression)
    if ann:
        if mode == 0:
            return collection.search_cosine_approx(query, k, ef_search=ef)
        return collection.search_cosine_approx_where(
            query, k, ef_search=ef, expression=expression
        )
    if mode == 0:
        return collection.search_cosine(query, k)
    return collection.search_cosine_where(query, k, expression)


def _fields(id: Int, seed: UInt64) raises -> List[DocumentField]:
    var mixed = (UInt64(id) + seed) * UInt64(0x9E3779B97F4A7C15)
    var fields = List[DocumentField]()
    fields.append(
        DocumentField("correlated", PayloadValue.integer(Int64((id % 8) // 2)))
    )
    fields.append(
        DocumentField(
            "independent", PayloadValue.integer(Int64((mixed >> 32) % 4))
        )
    )
    fields.append(DocumentField("rare", PayloadValue.integer(Int64(id % 32))))
    fields.append(DocumentField("payload", PayloadValue.string("x" * 256)))
    return fields^


def _append(
    mut collection: PersistentCollection,
    ids: List[Int],
    start: Int,
    end: Int,
    dimension: Int,
    seed: UInt64,
    mut rng: SplitMix64,
    clustered: Bool,
) raises:
    for batch_start in range(start, end, 1024):
        var mutations = List[BatchMutation]()
        for ordinal in range(batch_start, min(batch_start + 1024, end)):
            var id = ids[ordinal]
            mutations.append(
                BatchMutation.document_upsert(
                    id,
                    _query_vector(rng, id, dimension, clustered),
                    _fields(id, seed),
                )
            )
        _ = collection.apply_batch(mutations)


def main() raises:
    var args = argv()
    if len(args) != 13:
        raise Error(
            "usage: quality PATH POINTS DIM QUERIES SEED METRIC_TAG SCALAR_TAG"
            " BASE_PERCENT UPDATE_PERCENT EF CLUSTERED MIN_RECALL"
        )
    var point_count = Int(args[2])
    var dimension = Int(args[3])
    var query_count = Int(args[4])
    var seed = UInt64(Int(args[5]))
    var metric = Int(args[6])
    var scalar = Int(args[7])
    var base_percent = Int(args[8])
    var update_percent = Int(args[9])
    var ef = Int(args[10])
    var clustered = Int(args[11]) != 0
    var minimum_recall = Float64(args[12])
    if (
        point_count < 128
        or query_count < 1
        or base_percent < 0
        or base_percent > 100
        or update_percent < 0
        or update_percent > 50
    ):
        raise Error("invalid quality workload shape")
    var config = CollectionConfig.defaults(dimension)
    config.ann_metric = MetricKind.from_tag(UInt8(metric))
    config.scalar_kind = ScalarKind.from_tag(UInt8(scalar))
    config.m = 24
    config.m0 = 48
    config.ef_construction = 192
    config.default_ef_search = ef
    config.max_ef_search = max(ef, 512)
    config.max_level = 16
    config.delta_max_points = point_count * 4
    config.rebuild_inactive_percent = 90
    config.level_seed = seed
    config.validate()
    var rng = SplitMix64(seed)
    var ids = List[Int](capacity=point_count)
    for id in range(point_count):
        ids.append(id)
    for index in range(point_count - 1, 0, -1):
        ids.swap_elements(index, Int(rng.next_u64() % UInt64(index + 1)))
    var collection = PersistentCollection.open_with_config(args[1], config)
    var start = perf_counter_ns()
    var base_count = (point_count * base_percent) // 100
    _append(collection, ids, 0, base_count, dimension, seed, rng, clustered)
    var base_ingest_ns = perf_counter_ns() - start
    start = perf_counter_ns()
    if base_count > 0:
        collection.rebuild_hnsw()
    var checkpoint_build_ns = perf_counter_ns() - start
    start = perf_counter_ns()
    _append(
        collection,
        ids,
        base_count,
        point_count,
        dimension,
        seed,
        rng,
        clustered,
    )
    var delta_ingest_ns = perf_counter_ns() - start
    start = perf_counter_ns()
    var updates = List[BatchMutation]()
    for ordinal in range((point_count * update_percent) // 100):
        var id = ids[ordinal]
        updates.append(
            BatchMutation.document_upsert(
                id,
                _query_vector(rng, id, dimension, clustered),
                _fields(id, seed),
            )
        )
    var deleted = 0
    if update_percent > 0:
        for ordinal in range(point_count // 2, point_count, 20):
            updates.append(BatchMutation.delete(ids[ordinal]))
            deleted += 1
    if len(updates) > 0:
        _ = collection.apply_batch(updates)
    var mutation_ns = perf_counter_ns() - start
    if not collection._hnsw_available:
        raise Error("quality build lost the HNSW path")
    collection._hnsw.validate_structure()
    print(
        "build points="
        + String(point_count)
        + " dimension="
        + String(dimension)
        + " seed="
        + String(seed)
        + " metric="
        + config.ann_metric.name()
        + " scalar="
        + config.scalar_name()
        + " base_slots="
        + String(collection._hnsw.base_slot_count())
        + " delta_slots="
        + String(collection._hnsw.delta_slot_count())
        + " deleted="
        + String(deleted)
        + " base_ingest_ns="
        + String(base_ingest_ns)
        + " checkpoint_build_ns="
        + String(checkpoint_build_ns)
        + " delta_ingest_ns="
        + String(delta_ingest_ns)
        + " mutation_ns="
        + String(mutation_ns)
    )
    for mode in range(4):
        var label = "all"
        if mode == 1:
            label = "correlated"
        elif mode == 2:
            label = "independent"
        elif mode == 3:
            label = "selective"
        var recall_sum = Float64(0)
        var candidate_recall_sum = Float64(0)
        var fallback_queries = 0
        var sample_count = 0
        for query_index in range(query_count + 3):
            var query = _query_vector(rng, query_index, dimension, clustered)
            var field = "correlated" if mode == 1 else "independent"
            var expression = FilterExpression.condition(
                FilterCondition.equal(
                    field, PayloadValue.integer(Int64((query_index % 8) // 2))
                )
            )
            if mode == 3:
                expression = FilterExpression.condition(
                    FilterCondition.equal(
                        "rare", PayloadValue.integer(Int64(query_index % 32))
                    )
                )
            var expected = List[SearchResult]()
            var actual = List[SearchResult]()
            var exact_ns = 0
            var ann_ns = 0
            # Alternate the paired measurement order across queries.
            for phase in range(2):
                var call_start = perf_counter_ns()
                if (query_index + phase) % 2 == 0:
                    expected = _search(
                        collection,
                        query,
                        10,
                        ef,
                        metric,
                        mode,
                        expression,
                        False,
                    )
                    exact_ns = perf_counter_ns() - call_start
                else:
                    actual = _search(
                        collection,
                        query,
                        10,
                        ef,
                        metric,
                        mode,
                        expression,
                        True,
                    )
                    ann_ns = perf_counter_ns() - call_start
            var stats = collection.last_search_stats()
            var reason = collection.last_dense_plan_reason()
            if query_index < 3:
                continue
            var fallback = stats.fallback_reason != ""
            var recall = recall_at_k(expected, actual)
            var candidates = _candidates(
                collection, query, 10, ef, mode, expression
            )
            var hits = 0
            for target in expected:
                for id in candidates:
                    if id == target.id:
                        hits += 1
                        break
            var candidate_recall = 1.0 if len(expected) == 0 else Float64(
                hits
            ) / Float64(len(expected))
            recall_sum += recall
            candidate_recall_sum += candidate_recall
            fallback_queries += Int(fallback)
            sample_count += 1
            # The ANN-only cells must not silently pass on exact fallback.
            if mode < 3 and fallback:
                raise Error(
                    "ANN-only quality workload unexpectedly used exact fallback"
                )
            print(
                "query mode="
                + label
                + " ordinal="
                + String(query_index - 3)
                + " candidate_recall="
                + String(candidate_recall)
                + " final_recall="
                + String(recall)
                + " fallback="
                + String(Int(fallback))
                + " plan="
                + reason
                + " exact_ns="
                + String(exact_ns)
                + " collection_ann_ns="
                + String(ann_ns)
                + " candidates="
                + String(len(candidates))
                + " distances="
                + String(stats.distance_evaluations)
            )
        print(
            "quality mode="
            + label
            + " queries="
            + String(sample_count)
            + " candidate_recall="
            + String(candidate_recall_sum / Float64(sample_count))
            + " final_recall="
            + String(recall_sum / Float64(sample_count))
            + " fallback_rate="
            + String(Float64(fallback_queries) / Float64(sample_count))
        )
        if mode < 3 and recall_sum / Float64(sample_count) < minimum_recall:
            raise Error(
                "quality workload missed the explicitly requested recall"
                " threshold"
            )
    collection.close()
