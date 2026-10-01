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
        topk.offer(point.id, _score_validated_field(query, value, field))
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
    if view.visible_count == 0:
        return FieldSearchExecution([], stats^, "field_exact")
    if field.kind == 1:
        return _search_sparse_field(view, field, query, k, expression, control)
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


def _search_sparse_field(
    view: ReadGeneration,
    field: VectorFieldSpec,
    query: VectorValue,
    k: Int,
    expression: Optional[FilterExpression],
    control: Optional[QueryControl],
) raises -> FieldSearchExecution:
    var owner = _sparse_artifact(view, field, control)
    ref index = owner[]
    var stats = field_exact_stats(field)
    stats.storage_name = "field-postings"
    if len(index.rows) == 0:
        return FieldSearchExecution([], stats^, "field_sparse")
    var scores = index.scores(query.sparse_values(), control)
    var topk = BoundedTopK[DType.float64](
        min(k, len(index.rows)), smaller_is_better=False
    )
    for row in range(len(index.rows)):
        if control:
            control.value().checkpoint(row)
        ref location = index.rows[row]
        ref entry = view.run(location.layer).memtable.entry_ref_at(
            location.ordinal
        )
        if expression and not matches_expression(
            entry.fields(), expression.value()
        ):
            stats.filtered_rejections += 1
            continue
        topk.offer(location.id, scores.get(row, Float64(0)))
        stats.base_visited += 1
    if control:
        control.value().checkpoint(0)
    var results = topk.sorted_entries()
    stats.distance_evaluations = len(scores)
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "field_sparse")
