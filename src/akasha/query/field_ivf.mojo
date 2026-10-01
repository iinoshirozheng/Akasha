"""L2 coarse partitions with native F64 scoring of selected field owners."""

from akasha.compute.field_metrics import (
    _score_validated_field,
    validate_field_query,
)
from akasha.compute.topk import BoundedTopK
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.field_dense import dense_f32_projection
from akasha.index.field_ivf import FieldIvfIndex, IvfOptions
from akasha.index.quantization import PqCodebook
from akasha.query.control import QueryControl
from akasha.query.evaluator import matches_expression
from akasha.query.field_search import (
    FieldSearchExecution,
    field_exact_stats,
    gather_field_rows,
)
from akasha.query.filter_ast import FilterExpression
from akasha.storage.read_generation import ReadGeneration
from std.memory import ArcPointer
from std.utils import BlockingScopedLock


def _build_ivf(
    view: ReadGeneration,
    field: VectorFieldSpec,
    nlist: Int,
    iterations: Int,
    control: Optional[QueryControl],
) raises -> FieldIvfIndex:
    var rows = gather_field_rows(view, field.id, control)
    if len(rows) == 0:
        return FieldIvfIndex(rows^, [], [])
    var vectors = List[List[Float32]](capacity=len(rows))
    for row in range(len(rows)):
        if control:
            control.value().checkpoint(row)
        ref location = rows[row]
        ref entry = view.run(location.layer).memtable.entry_ref_at(
            location.ordinal
        )
        ref value = entry.vector_at(entry.field_ordinal(field.id)).value()
        value.validate(field)
        vectors.append(dense_f32_projection(value))
    var count = min(nlist, len(rows))
    var codebook = PqCodebook.train(
        vectors, 1, count, iterations=iterations, control=control
    )
    var centroids = List[List[Float32]](capacity=count)
    var partitions = List[List[Int]](capacity=count)
    for partition in range(count):
        var centroid = List[Float32](capacity=field.dimension)
        for column in range(field.dimension):
            centroid.append(codebook.value(0, partition, column))
        centroids.append(centroid^)
        partitions.append(List[Int]())
    for row in range(len(rows)):
        if control:
            control.value().checkpoint(row)
        var codes = codebook.encode(vectors[row])
        partitions[Int(codes[0])].append(row)
    return FieldIvfIndex(rows^, centroids^, partitions^)


def _ivf_artifact(
    view: ReadGeneration,
    field: VectorFieldSpec,
    nlist: Int,
    iterations: Int,
    control: Optional[QueryControl],
) raises -> ArcPointer[FieldIvfIndex]:
    var state = view.field_ivf[].get(field.id, nlist, iterations)
    with BlockingScopedLock(state[].lock):
        if control:
            control.value().checkpoint(0)
        if state[].ready:
            return state[].ready.value().copy()
        try:
            state[].begin()
            if control:
                control.value().checkpoint(0)
            var built = ArcPointer(
                _build_ivf(view, field, nlist, iterations, control)
            )
            if control:
                control.value().checkpoint(0)
            state[].publish(built.copy())
            return built^
        except error:
            state[].fail(String(error))
            raise error^


def search_generation_field_ivf(
    view: ReadGeneration,
    field: VectorFieldSpec,
    query: VectorValue,
    k: Int,
    expression: Optional[FilterExpression],
    nlist: Int,
    nprobe: Int,
    iterations: Int,
    control: Optional[QueryControl] = None,
) raises -> FieldSearchExecution:
    if k <= 0:
        raise Error("k must be positive")
    IvfOptions(nlist, nprobe, iterations).validate()
    if field.kind != 0:
        raise Error("IVF requires a dense vector field")
    validate_field_query(query, field)
    if expression:
        expression.value().validate()
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(view.visible_count)
    var stats = field_exact_stats(field)
    stats.storage_name = "field-ivf"
    if view.visible_count == 0:
        return FieldSearchExecution([], stats^, "field_ivf")
    var index = _ivf_artifact(view, field, nlist, iterations, control)
    stats.ivf_partitions = len(index[].partitions)
    var probes = min(nprobe, stats.ivf_partitions)
    stats.ivf_probed_partitions = probes
    if probes == 0:
        return FieldSearchExecution([], stats^, "field_ivf")
    var projected = dense_f32_projection(query)
    var nearest = BoundedTopK[DType.float64](probes, smaller_is_better=True)
    for partition in range(stats.ivf_partitions):
        if control:
            control.value().checkpoint(partition)
        ref centroid = index[].centroids[partition]
        var distance = Float64(0)
        for column in range(field.dimension):
            var difference = Float64(projected[column]) - Float64(
                centroid[column]
            )
            distance += difference * difference
        nearest.offer(partition, distance)
    stats.distance_evaluations = stats.ivf_partitions
    var topk = BoundedTopK[DType.float64](
        min(k, len(index[].rows)), smaller_is_better=field.metric == 1
    )
    for selected in nearest.sorted_entries():
        for row in index[].partitions[selected.id]:
            if control:
                control.value().checkpoint(stats.base_visited)
            stats.base_visited += 1
            ref location = index[].rows[row]
            ref entry = view.run(location.layer).memtable.entry_ref_at(
                location.ordinal
            )
            if expression and not matches_expression(
                entry.fields(), expression.value()
            ):
                stats.filtered_rejections += 1
                continue
            ref value = entry.vector_at(entry.field_ordinal(field.id)).value()
            topk.offer(entry.id, _score_validated_field(query, value, field))
            stats.reranked_candidates += 1
            stats.distance_evaluations += 1
    if control:
        control.value().checkpoint(0)
    stats.base_candidates = stats.base_visited
    var results = topk.sorted_entries()
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "field_ivf")
