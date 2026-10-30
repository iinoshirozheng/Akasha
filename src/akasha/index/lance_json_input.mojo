"""Lance JSON-index extraction, inference and typed training input.

Ported from lance-index scalar/json.rs and jsonb 0.5.6 databend/de.rs
(The Lance Authors / Datafuse Labs, Apache-2.0). This is the input layer;
target index training, query planning and durable collection indexes are separate.
"""
from std.sys import size_of
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_number import JsonbNumber
from akasha.document.jsonb_formatting import format_jsonb_extension
from akasha.document.lance_json import LanceJson
from akasha.document.lance_json_result import LanceJsonResult
from akasha.query.control import QueryControl


comptime MAX_JSON_INDEX_BATCH_ROWS = 65_536
comptime MAX_JSON_INDEX_BATCH_BYTES = 64 * 1024 * 1024


@fieldwise_init
struct JsonIndexValue(Copyable, Movable):
    """The two nullable children of upstream json_result, with owned bytes."""
    var value: Optional[JsonbValue]
    var tag: Optional[UInt8]


def json_index_type_name(target: UInt8) raises -> String:
    var names: List[String] = ["Boolean", "Int64", "Float64", "Utf8", "LargeBinary"]
    if target < 1 or target > 5:
        raise Error("unsupported JSON index target type")
    return names[Int(target) - 1].copy()


def _check_batch(count: Int, control: Optional[QueryControl]) raises:
    if count < 0 or count > MAX_JSON_INDEX_BATCH_ROWS:
        raise Error("JSON index batch row limit exceeded")
    if control:
        control.value().validate_candidate_count(count)
        control.value().checkpoint(0)


def _budget(max_bytes: Int, used: Int, addition: Int = 0) raises -> Int:
    if max_bytes <= 0 or used < 0 or addition < 0 or used > max_bytes or addition > max_bytes - used:
        raise Error("JSON index batch byte limit exceeded")
    return used + addition


def extract_json_index_batch(
    values: List[Optional[JsonbValue]], path: String, *,
    max_bytes: Int = MAX_JSON_INDEX_BATCH_BYTES,
    control: Optional[QueryControl] = None,
) raises -> List[JsonIndexValue]:
    """Source typed extraction, retaining rows and storage-null/tag-zero slots."""
    _check_batch(len(values), control)
    if path.byte_length() > 65_536:
        raise Error("JSON index path exceeds byte limit")
    var used = _budget(max_bytes, len(values) * size_of[JsonIndexValue]())
    var result = List[JsonIndexValue](capacity=len(values))
    for i in range(len(values)):
        if control:
            control.value().checkpoint(i)
        var selected = Optional[JsonbValue]()
        var tag = UInt8(0)
        if values[i]:
            # Copying the source body is bounded independently of owned output.
            _ = _budget(max_bytes, len(values[i].value()._data))
            var local_control = control.copy()
            if local_control:
                local_control.value().max_candidates = 1_000_000
            var json = LanceJson(values[i].value().clone(), max_bytes=max_bytes,
                                 control=local_control^)
            var extracted = json.extract_with_type(path)
            if extracted:
                used = _budget(max_bytes, used, len(extracted.value()[0]._data))
                tag = extracted.value()[1]
                selected = Optional(extracted.value()[0].clone())
        result.append(JsonIndexValue(selected^, Optional(tag)))
    return result^


def infer_json_index_type(
    batch: List[JsonIndexValue], path: String, *,
    control: Optional[QueryControl] = None,
) raises -> Optional[UInt8]:
    """First non-null tag only; stream training supplies Utf8 if all batches null.

    As upstream, binary validity does not participate in inference. Later tags
    are deliberately not inspected after the first inferred type.
    """
    _check_batch(len(batch), control)
    for i in range(len(batch)):
        if control:
            control.value().checkpoint(i)
        if not batch[i].tag:
            continue
        var tag = batch[i].tag.value()
        if tag > 6:
            raise Error("JSON path '" + path + "' produced invalid type tag " + String(tag))
        if tag == 0:
            continue
        return Optional(UInt8(5) if tag == 6 else tag)
    return None


def _validate_json_types(batch: List[JsonIndexValue], target: UInt8,
                         path: String, control: Optional[QueryControl]) raises:
    var type_name = json_index_type_name(target)
    var names: List[String] = ["Null", "Boolean", "Int64", "Float64", "String", "Array", "Object"]
    for i in range(len(batch)):
        if control:
            control.value().checkpoint(i)
        if not batch[i].value:
            continue
        if not batch[i].tag:
            raise Error("JSON path '" + path + "' has a value at batch row " + String(i) + " without a type tag")
        var tag = batch[i].tag.value()
        if tag > 6:
            raise Error("JSON path '" + path + "' produced invalid type tag " + String(tag) + " at batch row " + String(i))
        if tag == 0:
            continue
        var compatible = tag == target or (target == 3 and tag == 2) or (target == 5 and tag == 6)
        if not compatible:
            raise Error("JSON path '" + path + "' expected " + type_name + ", but batch row " + String(i) + " has JSON type " + names[Int(tag)])


def _deserialize(value: JsonbValue, target: UInt8,
                 control: Optional[QueryControl]) raises -> LanceJsonResult:
    # jsonb Serde read_bool/read_integer/read_float/read_string, NOT RawJsonb
    # to_* casts: Decimal and Float64 cannot deserialize as Int64, even exact.
    var result = LanceJsonResult()
    var kind = value.kind()
    if target == 1 and kind == 4:
        result.boolean = Optional(value.as_bool())
    elif target == 2:
        if kind == 2:
            result.integer = Optional(value.as_int())
        elif kind == 8 and value.as_uint() <= UInt64(Int64.MAX):
            result.integer = Optional(Int64(value.as_uint()))
        else:
            raise Error("UnexpectedType")
    elif target == 3 and (kind == 2 or kind == 8 or kind == 3 or kind == 9):
        result.floating = Optional(JsonbNumber.from_value(value).as_f64())
    elif target == 4 and kind == 1:
        result.text = Optional(value.as_string())
    elif target == 4 and kind >= 10:
        result.text = Optional(format_jsonb_extension(Span(value._data)[8:], control))
    elif target == 5:
        # Upstream validates the tag, then copies raw bytes without decoding.
        result.binary = Optional(value.clone())
    else:
        raise Error("UnexpectedType")
    return result^


def convert_json_index_batch(
    batch: List[JsonIndexValue], target: UInt8, path: String, *,
    max_bytes: Int = MAX_JSON_INDEX_BATCH_BYTES,
    control: Optional[QueryControl] = None,
) raises -> List[LanceJsonResult]:
    """Validate every row before conversion; errors publish no partial result."""
    _check_batch(len(batch), control)
    var type_name = json_index_type_name(target)
    var used = _budget(max_bytes, len(batch) * size_of[LanceJsonResult]())
    _validate_json_types(batch, target, path, control)
    var result = List[LanceJsonResult](capacity=len(batch))
    for i in range(len(batch)):
        if control:
            control.value().checkpoint(i)
        if not batch[i].value or batch[i].tag.value() == 0:
            result.append(LanceJsonResult())
            continue
        ref value = batch[i].value.value()
        # Check directly sized copies/hex before allocating; formatted time and
        # interval strings have bounded fixed-size representations.
        if target == 5:
            _ = _budget(max_bytes, used, len(value._data))
        elif target == 4 and value.kind() == 1:
            _ = _budget(max_bytes, used, len(value._data) - 8)
        elif target == 4 and value.kind() == 10:
            _ = _budget(max_bytes, used, (len(value._data) - 9) * 2)
        var converted: LanceJsonResult
        try:
            converted = _deserialize(value, target, control)
        except error:
            raise Error("Failed to convert JSON path '" + path + "' at batch row " + String(i) + " to " + type_name + ": " + String(error))
        used = _budget(max_bytes, used, converted.owned_bytes())
        result.append(converted^)
    return result^
