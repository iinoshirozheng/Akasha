# Array/null/MatchExcept checks port Qdrant condition_checker.rs (Apache-2.0),
# revision 74f3e85b9473c62560006c043e13737ce6b48412. See THIRD_PARTY_NOTICES.md.
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.query.filter_ast import FilterCondition, FilterExpression


def matches_all(
    fields: List[DocumentField], conditions: List[FilterCondition]
) raises -> Bool:
    """Return true when every condition matches one same-named field."""
    for condition_index in range(len(conditions)):
        if not _matches_condition(fields, conditions[condition_index]):
            return False
    return True


def matches_expression(
    fields: List[DocumentField], expression: FilterExpression
) raises -> Bool:
    """Evaluate a bounded expression with deterministic short-circuiting."""
    expression.validate()
    var node_stack = List[Int]()
    var child_positions = List[Int]()
    node_stack.append(expression.root_index())
    child_positions.append(0)
    var has_result = False
    var result = False

    while len(node_stack) > 0:
        var stack_index = len(node_stack) - 1
        var node_index = node_stack[stack_index]
        var kind = expression.node_kind(node_index)

        if has_result:
            if kind == FilterExpression.NEGATE:
                _ = node_stack.pop()
                _ = child_positions.pop()
                result = not result
                continue
            if kind == FilterExpression.ALL and not result:
                _ = node_stack.pop()
                _ = child_positions.pop()
                continue
            if kind == FilterExpression.ANY and result:
                _ = node_stack.pop()
                _ = child_positions.pop()
                continue
            child_positions[stack_index] += 1
            has_result = False
            continue

        if kind == FilterExpression.CONDITION:
            var condition = expression.node_condition(node_index)
            result = _matches_condition(fields, condition.value())
            _ = node_stack.pop()
            _ = child_positions.pop()
            has_result = True
            continue

        var child_position = child_positions[stack_index]
        if child_position >= expression.node_child_count(node_index):
            result = kind == FilterExpression.ALL
            _ = node_stack.pop()
            _ = child_positions.pop()
            has_result = True
            continue

        node_stack.append(expression.node_child(node_index, child_position))
        child_positions.append(0)

    return result


def _matches_condition(
    fields: List[DocumentField], condition: FilterCondition
) raises -> Bool:
    for field_index in range(len(fields)):
        if fields[field_index].name != condition.name:
            continue
        ref value = fields[field_index].value
        # Qdrant ValueChecker::_check examines one array level. Nested arrays
        # are passed to check_match unchanged, never recursively flattened.
        if value.is_array():
            var children = value.children()
            for i in range(len(children)):
                if _matches_value(children[i], condition):
                    return True
            return False
        return _matches_value(value, condition)
    return False


def _matches_value(
    stored: PayloadValue, condition: FilterCondition
) raises -> Bool:
    var operator_kind = condition.operator_kind()
    if stored.is_null():
        return False
    if stored.is_unsigned() and condition.value.is_integer() and (
        operator_kind == FilterCondition.EQUAL or operator_kind == FilterCondition.NOT_EQUAL
    ):
        var equal = condition.value.as_int() >= 0 and stored.as_uint() == UInt64(condition.value.as_int())
        return equal if operator_kind == FilterCondition.EQUAL else not equal
    # Qdrant MatchExcept excludes only matching values of the literal type;
    # other present scalar types still match. Missing fields are handled above.
    if operator_kind == FilterCondition.NOT_EQUAL:
        if condition.value.is_string():
            return not stored.is_string() or stored.as_string() != condition.value.as_string()
        if condition.value.is_integer():
            return not stored.is_integer() or stored.as_int() != condition.value.as_int()
    # Qdrant Range converts every JSON number to F64. Floating equality and
    # inequality are range predicates; integer equality remains an exact match.
    if condition.value.is_floating() or (
        condition.value.is_integer() and operator_kind != FilterCondition.EQUAL
    ):
        if not (stored.is_integer() or stored.is_floating() or stored.is_unsigned()):
            return False
        var left = (Float64(stored.as_int()) if stored.is_integer() else
                    Float64(stored.as_uint()) if stored.is_unsigned() else stored.as_float())
        var right = Float64(condition.value.as_int()) if condition.value.is_integer() else condition.value.as_float()
        return _compare_floats(left, right, operator_kind)
    if stored.kind() != condition.value.kind():
        return False

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
