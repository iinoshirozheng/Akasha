from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.query.filter_ast import FilterCondition


def matches_all(
    fields: List[DocumentField], conditions: List[FilterCondition]
) raises -> Bool:
    """Return true when every condition matches one same-named field."""
    for condition_index in range(len(conditions)):
        var found = False
        for field_index in range(len(fields)):
            if fields[field_index].name != conditions[condition_index].name:
                continue
            found = True
            if not _matches_value(
                fields[field_index].value, conditions[condition_index]
            ):
                return False
            break
        if not found:
            return False
    return True


def _matches_value(
    stored: PayloadValue, condition: FilterCondition
) raises -> Bool:
    if stored.kind() != condition.value.kind():
        return False

    var operator_kind = condition.operator_kind()
    if stored.is_string():
        var left = stored.as_string()
        var right = condition.value.as_string()
        if operator_kind == FilterCondition.EQUAL:
            return left == right
        return left != right

    if stored.is_boolean():
        var left = stored.as_bool()
        var right = condition.value.as_bool()
        if operator_kind == FilterCondition.EQUAL:
            return left == right
        return left != right

    if stored.is_integer():
        return _compare_ints(
            stored.as_int(), condition.value.as_int(), operator_kind
        )

    if stored.is_floating():
        return _compare_floats(
            stored.as_float(), condition.value.as_float(), operator_kind
        )

    raise Error("unknown document payload value kind")


def _compare_ints(left: Int64, right: Int64, operator_kind: UInt8) -> Bool:
    if operator_kind == FilterCondition.EQUAL:
        return left == right
    if operator_kind == FilterCondition.NOT_EQUAL:
        return left != right
    if operator_kind == FilterCondition.LESS_THAN:
        return left < right
    if operator_kind == FilterCondition.LESS_OR_EQUAL:
        return left <= right
    if operator_kind == FilterCondition.GREATER_THAN:
        return left > right
    return left >= right


def _compare_floats(
    left: Float64, right: Float64, operator_kind: UInt8
) -> Bool:
    if operator_kind == FilterCondition.EQUAL:
        return left == right
    if operator_kind == FilterCondition.NOT_EQUAL:
        return left != right
    if operator_kind == FilterCondition.LESS_THAN:
        return left < right
    if operator_kind == FilterCondition.LESS_OR_EQUAL:
        return left <= right
    if operator_kind == FilterCondition.GREATER_THAN:
        return left > right
    return left >= right
