# Field/array/null/MatchExcept and scoped Boolean checks port Qdrant
# condition_checker.rs and query_checker.rs (Apache-2.0),
# revision 74f3e85b9473c62560006c043e13737ce6b48412. See THIRD_PARTY_NOTICES.md.
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.json_path import JsonPath
from akasha.document.payload_path import _value_get, payload_value_get
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
    return matches_node(fields, expression, expression.root_index())


def _path_values(fields: List[DocumentField], path: JsonPath, scope: Optional[PayloadValue]) raises -> List[PayloadValue]:
    if scope:
        return payload_value_get(scope.value(), path)
    # Do not wrap top-level fields in another container: a valid field may
    # already use the full payload depth limit.
    var values = List[PayloadValue]()
    for i in range(len(fields)):
        if fields[i].name == path.first_key:
            _value_get(path.rest, 0, fields[i].value, values)
            break
    return values^


def matches_node(fields: List[DocumentField], expression: FilterExpression, node_index: Int,
                 scope: Optional[PayloadValue] = None) raises -> Bool:
    """Bounded source Boolean traversal; nested children use the same object."""
    ref node = expression._nodes[node_index]
    var kind = node.kind
    if kind == FilterExpression.CONDITION:
        if not scope:
            return _matches_condition(fields, node.condition.value())
        var value = scope.value().get_key(node.condition.value().name)
        return _matches_condition_value(value.value(), node.condition.value()) if value else False
    if kind == FilterExpression.FIELD:
        ref condition = node.payload.value()
        var values = _path_values(fields, condition.key, scope)
        if len(values) == 0:
            return condition.check_empty()
        for i in range(len(values)):
            if condition.check(values[i]):
                return True
        return False
    if kind == FilterExpression.NESTED:
        var values = _path_values(fields, node.path.value(), scope)
        for i in range(len(values)):
            if values[i].is_object():
                var object_scope = Optional(values[i].clone())
                if matches_node(fields, expression, node.children[0], object_scope):
                    return True
        return False
    if kind == FilterExpression.NEGATE:
        return not matches_node(fields, expression, node.children[0], scope)
    if kind == FilterExpression.AT_LEAST and node.min_count == 0:
        return True
    var count = UInt64(0)
    for child in node.children:
        var result = matches_node(fields, expression, child, scope)
        if kind == FilterExpression.ALL and not result:
            return False
        if kind == FilterExpression.ANY and result:
            return True
        if kind == FilterExpression.AT_LEAST and result:
            count += 1
            if count == node.min_count:
                return True
    return kind == FilterExpression.ALL


def _matches_condition(
    fields: List[DocumentField], condition: FilterCondition
) raises -> Bool:
    for field_index in range(len(fields)):
        if fields[field_index].name != condition.name:
            continue
        return _matches_condition_value(fields[field_index].value, condition)
    return False


def _matches_condition_value(value: PayloadValue, condition: FilterCondition) raises -> Bool:
    # Qdrant checks one array level, without recursively flattening arrays.
    if value.is_array():
        var children = value.children()
        for i in range(len(children)):
            if _matches_value(children[i], condition):
                return True
        return False
    return _matches_value(value, condition)


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
