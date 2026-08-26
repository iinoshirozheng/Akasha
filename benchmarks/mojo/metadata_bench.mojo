from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.index.metadata import MetadataIndex
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.index_evaluator import evaluate_expression
from std.time import perf_counter_ns


def _condition(var condition: FilterCondition) raises -> FilterExpression:
    return FilterExpression.condition(condition^)


def _benchmark(point_count: Int, iterations: Int) raises -> Float64:
    var index = MetadataIndex()
    index.begin_bulk()
    var build_start = perf_counter_ns()
    for point_id in range(point_count):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField(
                "group",
                PayloadValue.string("g" + String(point_id % 8)),
            )
        )
        fields.append(
            DocumentField("page", PayloadValue.integer(Int64(point_id)))
        )
        index.upsert(point_id, fields^)
    index.finish_bulk()
    var build_elapsed = perf_counter_ns() - build_start

    var children = List[FilterExpression]()
    children.append(
        _condition(FilterCondition.equal("group", PayloadValue.string("g3")))
    )
    children.append(
        _condition(
            FilterCondition.greater_or_equal(
                "page", PayloadValue.integer(Int64(point_count - 10_000))
            )
        )
    )
    var expression = FilterExpression.all(children^)
    var checksum = 0
    var query_start = perf_counter_ns()
    for _ in range(iterations):
        checksum += evaluate_expression(index, expression).count()
    var query_elapsed = perf_counter_ns() - query_start

    var build_ns_per_point = Float64(build_elapsed) / Float64(point_count)
    print(
        "metadata points",
        point_count,
        "build ns/point",
        build_ns_per_point,
        "query ns",
        Float64(query_elapsed) / Float64(iterations),
        "checksum",
        checksum,
    )
    return build_ns_per_point


def main() raises:
    var small_build = _benchmark(10_000, 20)
    var large_build = _benchmark(100_000, 10)
    if large_build > small_build * 8.0:
        raise Error("metadata bulk build scaling regressed")
