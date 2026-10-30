from akasha.index.bitmap import Bitmap
from akasha.index.metadata import MetadataIndex
from akasha.query.filter_ast import FilterCondition, FilterExpression


def evaluate_all(
    index: MetadataIndex, conditions: List[FilterCondition]
) raises -> Bitmap:
    """Evaluate the legacy implicit-AND filter API with metadata indexes."""
    var result = index.live_universe()
    for condition_index in range(len(conditions)):
        conditions[condition_index].validate()
        var candidates = index.evaluate_condition(conditions[condition_index])
        result = result.intersection(candidates)
        if result.count() == 0:
            break
    return result^


def evaluate_expression(
    index: MetadataIndex, expression: FilterExpression
) raises -> Bitmap:
    """Compose indexed predicates, evaluating nested scopes as one predicate."""
    expression.validate()
    for i in range(expression.node_count()):
        if expression.node_kind(i) == FilterExpression.JSONB:
            # JSONB casts and selectors can fail for a particular value. Set
            # operations over independently evaluated leaves would execute
            # branches skipped by per-row all/any short circuiting. Evaluate
            # this whole expression over the authoritative metadata payloads.
            return index.evaluate_payload_node(expression, expression.root_index())
    return _evaluate_node(index, expression, expression.root_index())


def _evaluate_node(index: MetadataIndex, expression: FilterExpression, node_index: Int) raises -> Bitmap:
    var kind = expression.node_kind(node_index)
    if kind == FilterExpression.CONDITION:
        return index.evaluate_condition(expression._nodes[node_index].condition.value())
    if kind == FilterExpression.FIELD or kind == FilterExpression.NESTED or kind == FilterExpression.AT_LEAST or kind >= FilterExpression.POINT:
        return index.evaluate_payload_node(expression, node_index)
    if kind == FilterExpression.NEGATE:
        var live = index.live_universe()
        var child = _evaluate_node(index, expression, expression.node_child(node_index, 0))
        return live.difference(child)
    var result = index.live_universe() if kind == FilterExpression.ALL else Bitmap(index.slot_count())
    for i in range(expression.node_child_count(node_index)):
        var child = _evaluate_node(index, expression, expression.node_child(node_index, i))
        if kind == FilterExpression.ALL:
            result = result.intersection(child)
            if result.count() == 0:
                break
        else:
            result = result.union_with(child)
    return result^
