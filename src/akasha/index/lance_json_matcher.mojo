"""Lance JSON reference/leaf matching with an indexed-value equivalence guard.

Source: lance-index scalar/json.rs::JsonQueryParser::is_valid_reference and
scalar/expression.rs::SargableQueryParser (Lance Authors, Apache-2.0).
The source's path-only reference rule can select a non-equivalent value; see
the committed original-source matcher audit. Never elide an unhandled predicate.
"""
from akasha.document.jsonb_path import JsonbPath
from akasha.document.jsonb_cast import _parse_integer
from akasha.index.lance_bitmap import LanceBitmapQuery


def source_json_reference_type(index_path: String, function: String,
                               argument: Optional[String]) -> Optional[UInt8]:
    """Original rule for a two-argument function(Column, Utf8 literal).

    This is source recognition only, NOT permission to execute an index query.
    The caller already selected the column/index. Dynamic/null literals decline.
    """
    if not argument or argument.value() != index_path:
        return None
    if function == "json_get_int":
        return Optional(UInt8(2))
    if function == "json_get_float":
        return Optional(UInt8(3))
    if function == "json_get_bool":
        return Optional(UInt8(1))
    if function == "json_get_string" or function == "json_extract":
        return Optional(UInt8(4))
    # Original json_get is listed among recognized names but returns None.
    return None


def json_bitmap_reference_supported(index_path: String, target: UInt8,
                                    function: String, argument: Optional[String]) raises -> Bool:
    var reference = source_json_reference_type(index_path, function, argument)
    if not reference or reference.value() != target or function == "json_extract":
        return False
    # Getters use a literal key; training uses JSONPath. Only a single bare field
    # whose decoded text is byte-identical to the argument is equivalent here.
    # Numeric keys also select array elements in get_*; a JSONPath field does
    # not. Reuse the exact Rust usize parser used by the source-ported getter.
    # No path normalization or speculative rewrite is applied.
    if _parse_integer(index_path, False):
        return False
    var parsed: JsonbPath
    try:
        parsed = JsonbPath.parse(index_path)
    except:
        return False
    if len(parsed.roots) != 1:
        return False
    ref node = parsed.nodes[parsed.roots[0]]
    return node.kind == 5 and node.text == index_path


def json_bitmap_query_supported(target: UInt8, query: LanceBitmapQuery) -> Bool:
    """Source sargable leaf rules after typed literal binding.

    SQL =NULL, IN containing NULL and NULL range endpoints must remain residual;
    the raw bitmap API has different explicit null-query semantics. Literal
    coercion and full expression planning remain the caller's separate work.
    """
    if query.kind == 0 or query.kind == 2:
        if query.kind == 0 and len(query.values) != 1:
            return False
        for value in query.values:
            if value.is_null or value.target != target:
                return False
        return True
    if query.kind == 1:
        if query.lower.key:
            if query.lower.key.value().is_null or query.lower.key.value().target != target:
                return False
        if query.upper.key:
            if query.upper.key.value().is_null or query.upper.key.value().target != target:
                return False
        return True
    if query.kind == 3:
        return True
    # The source bitmap parser disables prefix queries and has no text query.
    return False
