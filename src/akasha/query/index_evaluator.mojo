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
    """Evaluate a post-order flat filter arena into one candidate bitmap."""
    expression.validate()
    var results = List[Bitmap](capacity=expression.node_count())
    for node_index in range(expression.node_count()):
        var kind = expression.node_kind(node_index)
        var result: Bitmap
        if kind == FilterExpression.CONDITION:
            var condition = expression.node_condition(node_index)
            result = index.evaluate_condition(condition.value())
        elif kind == FilterExpression.ALL:
            result = index.live_universe()
            for child_index in range(expression.node_child_count(node_index)):
                var child = expression.node_child(node_index, child_index)
                result = result.intersection(results[child])
                if result.count() == 0:
                    break
        elif kind == FilterExpression.ANY:
            result = Bitmap(index.slot_count())
            for child_index in range(expression.node_child_count(node_index)):
                var child = expression.node_child(node_index, child_index)
                result = result.union_with(results[child])
        else:
            var child = expression.node_child(node_index, 0)
            var live = index.live_universe()
            result = live.difference(results[child])
        results.append(result^)
    return results[expression.root_index()].clone()
