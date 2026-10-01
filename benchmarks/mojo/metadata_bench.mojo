from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.index.metadata import MetadataIndex
from akasha.index.keyword import KeywordIndex
from akasha.index.sorted_block import SortedBlockIndex
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.index_evaluator import evaluate_expression
from akasha.storage.checksum import BinaryWriter, crc32
from std.sys.arg import argv
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
    var cache_bytes = index.encode_cache_payload()

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
        "cache_bytes",
        len(cache_bytes),
        "cache_crc32",
        crc32(cache_bytes),
    )
    return build_ns_per_point


def main() raises:
    var args = argv()
    if len(args) == 6 and (args[1] == "sort" or args[1] == "sort-memory"):
        _sort_benchmark(
            args[2], Int(args[3]), args[4], Int(args[5]), args[1] == "sort"
        )
        return
    if len(args) != 1:
        raise Error(
            "usage: metadata-bench [sort|sort-memory keyword|int|float N"
            " PATTERN PREFIX_BYTES]"
        )
    var small_build = _benchmark(10_000, 20)
    var large_build = _benchmark(100_000, 10)
    if large_build > small_build * 8.0:
        raise Error("metadata bulk build scaling regressed")


def _write_string(mut writer: BinaryWriter, value: String):
    writer.write_u64(UInt64(value.byte_length()))
    for byte in value.as_bytes():
        writer.write_u8(byte)


def _sort_benchmark(
    family: String,
    count: Int,
    pattern: String,
    prefix_bytes: Int,
    audit_bytes: Bool,
) raises:
    """Time only finish_bulk, with input preparation and byte audit outside it.
    """
    if count < 1 or prefix_bytes < 0:
        raise Error("positive count and nonnegative prefix length required")
    var order = List[Int](capacity=count)
    for i in range(count):
        order.append(i)
    if pattern == "reverse":
        for i in range(count // 2):
            order.swap_elements(i, count - 1 - i)
    elif pattern == "random" or pattern == "ties":
        # Fixed LCG/Fisher-Yates; arithmetic is deliberately unsigned wrapping.
        var state = UInt64(12345)
        for i in range(count - 1, 0, -1):
            state = state * UInt64(6364136223846793005) + UInt64(1)
            order.swap_elements(i, Int(state % UInt64(i + 1)))
    elif pattern != "sorted" and pattern != "organ_pipe":
        raise Error("unknown metadata sort pattern")
    var name = "field-" + "x" * prefix_bytes
    var prefix = "v" * prefix_bytes
    var keyword = KeywordIndex(count)
    var numbers = SortedBlockIndex(count)
    keyword.begin_bulk()
    numbers.begin_bulk()
    for i in range(count):
        var ordinal = order[i]
        var value = ordinal
        if pattern == "ties":
            value = ordinal % 8
        elif pattern == "organ_pipe":
            value = min(i, count - 1 - i)
        if family == "keyword":
            keyword.add(
                name,
                PayloadValue.string(prefix + String(1_000_000_000 + value)),
                ordinal,
            )
        elif family == "int":
            numbers.add(name, PayloadValue.integer(Int64(value)), ordinal)
        elif family == "float":
            numbers.add(
                name, PayloadValue.floating(Float64(value) + 0.25), ordinal
            )
        else:
            raise Error("unknown metadata sort family")
    var start = perf_counter_ns()
    if family == "keyword":
        keyword.finish_bulk()
    else:
        numbers.finish_bulk()
    var sort_ns = perf_counter_ns() - start
    if not audit_bytes:
        # Stop before the byte audit so process peak RSS includes input and
        # sorting, without serialization's larger temporary buffer.
        print("sort-memory ns=" + String(sort_ns))
        return
    var writer = BinaryWriter()
    for i in range(count):
        if family == "keyword":
            _write_string(writer, keyword._entries[i].name)
            writer.write_u8(keyword._entries[i].kind)
            _write_string(writer, keyword._entries[i].string_value)
            writer.write_u8(UInt8(keyword._entries[i].bool_value))
            writer.write_i64(Int64(keyword._entries[i].ordinal))
        elif family == "int":
            _write_string(writer, numbers._integers[i].name)
            writer.write_i64(numbers._integers[i].value)
            writer.write_i64(Int64(numbers._integers[i].ordinal))
        else:
            _write_string(writer, numbers._floats[i].name)
            writer.write_f64(numbers._floats[i].value)
            writer.write_i64(Int64(numbers._floats[i].ordinal))
    var bytes = writer.take_bytes()
    print(
        "sort family="
        + family
        + " n="
        + String(count)
        + " pattern="
        + pattern
        + " prefix_bytes="
        + String(prefix_bytes)
        + " ns="
        + String(sort_ns)
        + " encoded_bytes="
        + String(len(bytes))
        + " crc32="
        + String(crc32(bytes))
    )
