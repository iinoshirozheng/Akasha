"""Nullable typed predicate evaluation for JSON index and residual execution.

The scalar ordering is the pinned Lance target ordering. SQL literal nulls
retain unknown rather than using the bitmap API's explicit null lookup rules.
"""
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_bitmap import LanceBitmapQuery


def negate_truth(value: Optional[Bool]) -> Optional[Bool]:
    if not value:
        return None
    return Optional(not value.value())


def and_truth(left: Optional[Bool], right: Optional[Bool]) -> Optional[Bool]:
    if Bool(left) and not left.value():
        return Optional(False)
    if Bool(right) and not right.value():
        return Optional(False)
    if not left or not right:
        return None
    return Optional(True)


def or_truth(left: Optional[Bool], right: Optional[Bool]) -> Optional[Bool]:
    if Bool(left) and left.value():
        return Optional(True)
    if Bool(right) and right.value():
        return Optional(True)
    if not left or not right:
        return None
    return Optional(False)


def scalar_predicate(value: LanceScalarKey, query: LanceBitmapQuery) raises -> Optional[Bool]:
    """Evaluate one already-bound leaf; callers control lazy tree traversal."""
    if query.kind == 3:
        return Optional(value.is_null)
    if query.kind == 0:
        if len(query.values) != 1:
            raise Error("JSON equality requires one literal")
        if value.is_null or query.values[0].is_null:
            return None
        return Optional(value.compare(query.values[0]) == 0)
    if query.kind == 2:
        # Empty IN is false, including a null input.
        if len(query.values) == 0:
            return Optional(False)
        if value.is_null:
            return None
        var unknown = False
        for literal in query.values:
            if literal.is_null:
                unknown = True
            elif value.compare(literal) == 0:
                return Optional(True)
        if unknown:
            return None
        return Optional(False)
    if query.kind == 1:
        if value.is_null:
            return None
        var low = Optional(True)
        var high = Optional(True)
        if query.lower.key:
            ref bound = query.lower.key.value()
            if bound.is_null:
                low = None
            else:
                var comparison = value.compare(bound)
                low = Optional(comparison >= 0 if query.lower.included else comparison > 0)
        if query.upper.key:
            ref bound = query.upper.key.value()
            if bound.is_null:
                high = None
            else:
                var comparison = value.compare(bound)
                high = Optional(comparison <= 0 if query.upper.included else comparison < 0)
        return and_truth(low, high)
    raise Error("unsupported JSON scalar predicate")
