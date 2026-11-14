"""Three-valued leaf predicates for the native paged scalar index.

Lance flat.rs shortcuts and scalar.rs::SargableQuery::to_expr (Apache-2.0).
Numeric comparisons use Arrow total ordering through LanceScalarKey.
Return -1 for UNKNOWN, 0 for FALSE and 1 for TRUE.
"""
from std.sys import size_of
from akasha.query.control import QueryControl
from akasha.index.nullable_rows import NullableRowSet
from akasha.index.roaring_rows import RoaringRowSet
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_bitmap import LanceBitmapQuery, LanceBitmapBound, LanceBitmapRow


def validate_btree_query(query: LanceBitmapQuery, target: UInt8, control: Optional[QueryControl] = None) raises:
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(len(query.values))
    if query.kind > 3:
        raise Error("unsupported B-tree predicate")
    if query.kind == 0 and len(query.values) != 1:
        raise Error("B-tree equality requires one value")
    if len(query.values) > 65536:
        raise Error("B-tree query literal limit exceeded")
    var bytes = len(query.values) * size_of[LanceScalarKey]()
    for i in range(len(query.values)):
        if control:
            control.value().checkpoint(i)
        query.values[i].validate(target)
        bytes += len(query.values[i]._bytes)
        if bytes > 64 * 1024 * 1024:
            raise Error("B-tree query byte limit exceeded")
    if query.lower.key:
        query.lower.key.value().validate(target)
        bytes += len(query.lower.key.value()._bytes)
    if query.upper.key:
        query.upper.key.value().validate(target)
        bytes += len(query.upper.key.value()._bytes)
    if bytes > 64 * 1024 * 1024:
        raise Error("B-tree query byte limit exceeded")


def _bound_truth(value: LanceScalarKey, bound: LanceBitmapBound, lower: Bool) raises -> Int:
    if not bound.key:
        return 1
    ref key = bound.key.value()
    if value.is_null or key.is_null:
        return -1
    var comparison = value.compare(key)
    if lower:
        return Int(comparison > 0 or (comparison == 0 and bound.included))
    return Int(comparison < 0 or (comparison == 0 and bound.included))


def btree_leaf_truth(value: LanceScalarKey, query: LanceBitmapQuery) raises -> Int:
    # Caller validates the query once, before scanning its pages.
    if query.kind == 3:
        return Int(value.is_null)
    if query.kind == 0:
        if value.is_null or query.values[0].is_null:
            return -1
        return Int(value.compare(query.values[0]) == 0)
    if query.kind == 1:
        var lower = _bound_truth(value, query.lower, True)
        var upper = _bound_truth(value, query.upper, False)
        # SQL conjunction: FALSE dominates UNKNOWN.
        if lower == 0 or upper == 0:
            return 0
        return -1 if lower == -1 or upper == -1 else 1
    if query.kind == 2:
        if len(query.values) == 0:
            return 0
        if value.is_null:
            return -1
        var has_null = False
        for key in query.values:
            if key.is_null:
                has_null = True
            elif value.compare(key) == 0:
                return 1
        return -1 if has_null else 0
    raise Error("unsupported B-tree predicate")


def search_btree_leaf(rows: List[LanceBitmapRow], target: UInt8,
                      query: LanceBitmapQuery, *, track_nulls: Bool = True,
                      all_rows: Bool = False,
                      control: Optional[QueryControl] = None) raises -> NullableRowSet:
    """Scan a decoded leaf; all_rows is a validated directory match shortcut."""
    validate_btree_query(query, target, control)
    if control:
        control.value().checkpoint(0)
    var selected = RoaringRowSet()
    var nulls = RoaringRowSet()
    for i in range(len(rows)):
        if control:
            control.value().checkpoint(i)
        ref row = rows[i]
        row.key.validate(target)
        if all_rows:
            # Mirrors search_page All: IS NULL ignores null validity, other
            # predicates preserve nulls or exclude them when not tracking.
            if query.kind == 3 or not row.key.is_null or track_nulls:
                _ = selected.insert(row.id)
            if query.kind != 3 and row.key.is_null and track_nulls:
                _ = nulls.insert(row.id)
        else:
            var truth = btree_leaf_truth(row.key, query)
            if truth == 1:
                _ = selected.insert(row.id)
            elif truth == -1 and track_nulls:
                _ = nulls.insert(row.id)
    return NullableRowSet(selected^, nulls^)
