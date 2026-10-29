from akasha.compute.field_metrics import (
    _score_validated_field,
    validate_field_query,
)
from akasha.compute.topk import BoundedTopK, TopKEntry
from akasha.document.point_state import PointState
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.field_artifacts import FieldRow
from akasha.index.field_sparse import FieldSparseIndex
from akasha.index.sparse_search import search_sparse_postings
from akasha.query.control import QueryControl
from akasha.query.evaluator import matches_expression
from akasha.query.filter_ast import FilterExpression
from akasha.storage.read_generation import ReadGeneration
from std.memory import ArcPointer
from std.utils import BlockingScopedLock


comptime FieldSearchResult = TopKEntry[DType.float64]


@fieldwise_init
struct FieldSearchExecution(Movable):
    var results: List[FieldSearchResult]
    var stats: HnswSearchStats
    var reason: String

    def take_results(mut self) -> List[FieldSearchResult]:
        var results = self.results^
        self.results = List[FieldSearchResult]()
        return results^


def field_exact_stats(field: VectorFieldSpec) -> HnswSearchStats:
    var stats = HnswSearchStats()
    stats.backend_name = "native-f64"
    if field.kind == 1:
        stats.backend_name = "native-f32"
    stats.storage_name = "field-flat"
    stats.scalar_name = "binary"
    if field.scalar == 0:
        stats.scalar_name = "f32"
    elif field.scalar == 1:
        stats.scalar_name = "bf16"
    elif field.scalar == 2:
        stats.scalar_name = "f16"
    elif field.scalar == 3:
        stats.scalar_name = "i8"
    elif field.scalar == 4:
        stats.scalar_name = "u8"
    stats.metric_name = "jaccard"
    if field.metric == 0:
        stats.metric_name = "dot"
    elif field.metric == 1:
        stats.metric_name = "l2"
    elif field.metric == 2:
        stats.metric_name = "cosine"
    elif field.metric == 3:
        stats.metric_name = "hamming"
    return stats^


def gather_field_rows(view: ReadGeneration, field_id: Int, control: Optional[QueryControl]) raises -> List[FieldRow]:
    """Collect present visible rows once when building a field artifact."""
    var rows = List[FieldRow]()
    var scanned = 0
    for layer in range(view.layer_count()):
        ref table = view.run(layer).memtable
        for ordinal in view.visible_ordinals(layer):
            if control:
                control.value().checkpoint(scanned)
            scanned += 1
            ref entry = table.entry_ref_at(ordinal)
            if entry.field_ordinal(field_id) >= 0:
                rows.append(FieldRow(entry.id, layer, ordinal))
    sort(Span(rows))
    return rows^


def search_point_field(
    points: Span[PointState, _],
    field: VectorFieldSpec,
    query: VectorValue,
    k: Int,
    expression: Optional[FilterExpression],
) raises -> List[FieldSearchResult]:
    """Exact native-field search with presence/filter checks before Top-K."""
    if k <= 0:
        raise Error("k must be positive")
    validate_field_query(query, field)
    if expression:
        expression.value().validate()
    if len(points) == 0:
        return List[FieldSearchResult]()
    if field.kind == 1:
        var built = FieldSparseIndex()
        var allowed = List[Bool]()
        var matched = 0
        for row in range(len(points)):
            ref point = points[row]
            var ordinal = point.ordinal_for(field.id)
            if point.tombstone or ordinal < 0:
                continue
            built.add(FieldRow(point.id, 0, row), point.field_at(ordinal).value().sparse_values())
            var admit = not expression or matches_expression(point.payload(), expression.value())
            allowed.append(admit)
            if admit:
                matched += 1
        var outcome = search_sparse_postings(ArcPointer(built^), query.sparse_values(), allowed, k, Bool(expression) and matched < 5_000)
        var sparse_results = List[FieldSearchResult](capacity=len(outcome.results))
        for hit in outcome.results:
            sparse_results.append(FieldSearchResult(hit.id, Float64(hit.score)))
        return sparse_results^
    var topk = BoundedTopK[DType.float64](
        min(k, len(points)),
        smaller_is_better=field.metric == 1
        or field.metric == 3
        or field.metric == 4,
    )
    for index in range(len(points)):
        ref point = points[index]
        if point.tombstone:
            continue
        var ordinal = point.ordinal_for(field.id)
        if ordinal < 0:
            continue
        if expression and not matches_expression(
            point.payload(), expression.value()
        ):
            continue
        ref value = point.field_at(ordinal).value()
        if field.kind == 2 and value.row_count() == 0:
            continue
        var score = _score_validated_field(query, value, field)
        topk.offer(point.id, score)
    return topk.sorted_entries()


def search_generation_field(
    view: ReadGeneration,
    field: VectorFieldSpec,
    query: VectorValue,
    k: Int,
    expression: Optional[FilterExpression],
) raises -> List[FieldSearchResult]:
    var execution = search_generation_field_reported(
        view, field, query, k, expression
    )
    return execution.take_results()


def search_generation_field_reported(
    view: ReadGeneration,
    field: VectorFieldSpec,
    query: VectorValue,
    k: Int,
    expression: Optional[FilterExpression],
    control: Optional[QueryControl] = None,
    excluded_ids: Optional[Dict[Int, Bool]] = None,
) raises -> FieldSearchExecution:
    """Rank visible native owners across immutable runs with one bounded heap.
    """
    if k <= 0:
        raise Error("k must be positive")
    validate_field_query(query, field)
    if expression:
        expression.value().validate()
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(view.visible_count)
    var stats = field_exact_stats(field)
    if field.kind == 1:
        return search_sparse_field(view, field, query, k, expression, control, excluded_ids)
    if view.visible_count == 0:
        return FieldSearchExecution([], stats^, "field_exact")
    var topk = BoundedTopK[DType.float64](
        min(k, view.visible_count),
        smaller_is_better=field.metric == 1
        or field.metric == 3
        or field.metric == 4,
    )
    var scanned = 0
    for layer in range(view.layer_count()):
        var ordinals = view.filtered_ordinals(
            layer, expression.value()
        ) if expression else view.visible_ordinals(layer)
        ref table = view.run(layer).memtable
        for ordinal in ordinals:
            if control:
                control.value().checkpoint(scanned)
            scanned += 1
            ref entry = table.entry_ref_at(ordinal)
            if excluded_ids and entry.id in excluded_ids.value():
                stats.filtered_rejections += 1
                continue
            var field_ordinal = entry.field_ordinal(field.id)
            if field_ordinal < 0:
                continue
            ref value = entry.vector_at(field_ordinal).value()
            if field.kind == 2 and value.row_count() == 0:
                continue
            topk.offer(entry.id, _score_validated_field(query, value, field))
            stats.base_visited += 1
            stats.distance_evaluations += 1
    if control:
        control.value().checkpoint(0)
    var results = topk.sorted_entries()
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "field_exact")


def _sparse_artifact(
    view: ReadGeneration,
    field: VectorFieldSpec,
    control: Optional[QueryControl],
) raises -> ArcPointer[FieldSparseIndex]:
    var state = view.field_sparse[].get(field.id)
    with BlockingScopedLock(state[].lock):
        if control:
            control.value().checkpoint(0)
        if state[].ready:
            return state[].ready.value().copy()
        try:
            state[].begin()
            var built = FieldSparseIndex()
            var scanned = 0
            for layer in range(view.layer_count()):
                ref table = view.run(layer).memtable
                for ordinal in view.visible_ordinals(layer):
                    if control:
                        control.value().checkpoint(scanned)
                    scanned += 1
                    ref entry = table.entry_ref_at(ordinal)
                    var field_ordinal = entry.field_ordinal(field.id)
                    if field_ordinal >= 0:
                        built.add(
                            FieldRow(entry.id, layer, ordinal),
                            entry.vector_at(field_ordinal)
                            .value()
                            .sparse_values(),
                        )
            if control:
                control.value().checkpoint(0)
            var owner = ArcPointer(built^)
            state[].publish(owner.copy())
            return owner^
        except error:
            state[].fail(String(error))
            raise error^


def search_sparse_field(
    view: ReadGeneration, field: VectorFieldSpec, query: VectorValue, k: Int,
    expression: Optional[FilterExpression], control: Optional[QueryControl],
    excluded_ids: Optional[Dict[Int, Bool]] = None, *,
    required_ids: Optional[Dict[Int, Bool]] = None, require_finite: Bool = False,
) raises -> FieldSearchExecution:
    """Source sparse dispatch, including candidate-ID filters for rescoring.

    Qdrant sparse_vector_index/read_view/search.rs and local_shard/query.rs at
    74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0). Exact native admitted
    counts stand in for the upstream cardinality estimator; default threshold 5000.
    """
    var stats = field_exact_stats(field)
    stats.storage_name = "field-postings"
    if control:
        control.value().checkpoint(0)
    if len(query.sparse_values()) == 0:
        return FieldSearchExecution([], stats^, "field_sparse_empty")
    var owner = _sparse_artifact(view, field, control)
    var allowed = List[Bool](length=len(owner[].rows), fill=False)
    var matched = 0
    for row in range(len(owner[].rows)):
        if control:
            control.value().checkpoint(row)
        var location = owner[].rows[row]
        if excluded_ids and location.id in excluded_ids.value():
            continue
        if required_ids and location.id not in required_ids.value():
            continue
        ref entry = view.run(location.layer).memtable.entry_ref_at(location.ordinal)
        if expression and not matches_expression(entry.fields(), expression.value()):
            continue
        allowed[row] = True
        matched += 1
    var filtered = Bool(expression) or Bool(required_ids) or (Bool(excluded_ids) and len(excluded_ids.value()) > 0)
    var plain = filtered and matched < 5_000
    var outcome = search_sparse_postings(owner, query.sparse_values(), allowed, k, plain, control, require_finite=require_finite)
    var results = List[FieldSearchResult](capacity=len(outcome.results))
    for hit in outcome.results:
        results.append(FieldSearchResult(hit.id, Float64(hit.score)))
    stats.distance_evaluations = outcome.evaluated
    stats.base_visited = outcome.evaluated
    stats.filtered_rejections = outcome.rejected
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "field_sparse_plain" if plain else "field_sparse_indexed")
