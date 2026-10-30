"""Source-backed Lance JSON functions for a JsonbValue or a nullable Arrow array.

All selection, conversion and row/null/broadcast decisions execute in Mojo.
Arrow inputs use LargeBinary JSONB and Utf8 arguments. The Python boundary
materializes primitive transport buffers; this is not a zero-copy API.
"""
from __future__ import annotations

from time import perf_counter_ns
from typing import Any

from .payload import JsonbValue
from .exceptions import ValidationError, map_kernel_error

__all__ = [
    "json_path", "json_extract", "json_extract_with_type", "json_exists",
    "json_get", "json_get_string", "json_get_int", "json_get_float", "json_get_bool",
    "json_array_contains", "json_array_length",
]


def _arrow_values(value: Any, max_bytes: int) -> list[Any]:
    if len(value) > 65_536:
        raise ValidationError("Lance JSON row resource limit exceeded")
    try:
        value.validate(full=True)
        if value.nbytes > max_bytes:
            raise ValidationError("Lance JSON input resource limit exceeded")
        return value.to_pylist()
    except Exception as error:
        raise map_kernel_error(error) from error


def _apply(
    operation: int, values: Any, argument: Any, needle: Any = None, *,
    max_work: int = 1_000_000, max_results: int = 65_536,
    max_bytes: int = 64 * 1024 * 1024,
    cancellation: Any = None, timeout_ns: int | None = None,
) -> Any:
    from .database import CancellationToken, _kernel_module

    for name, value in (("max_work", max_work), ("max_results", max_results), ("max_bytes", max_bytes)):
        if type(value) is not int or not 0 < value <= 2**63 - 1:
            raise ValidationError(f"Lance JSON {name} must be a positive Int64")
    if cancellation is not None and type(cancellation) is not CancellationToken:
        raise ValidationError("cancellation must be a CancellationToken")
    if timeout_ns is not None and (type(timeout_ns) is not int or not 0 < timeout_ns <= 2**63 - 1):
        raise ValidationError("timeout_ns must be a positive Int64")
    deadline = 0 if timeout_ns is None else perf_counter_ns() + timeout_ns
    if deadline > 2**63 - 1:
        raise ValidationError("Lance JSON deadline exceeds Int64")
    scalar = values is None or type(values) is JsonbValue
    pa = None
    if scalar:
        bodies = [None if values is None else values.data]
    else:
        import pyarrow as pa
        if not isinstance(values, pa.Array) or values.type != pa.large_binary():
            raise ValidationError("First argument must be a JsonbValue, null, or Arrow LargeBinary array")
        if len(values) > min(max_results, 65_536):
            raise ValidationError("Lance JSON input resource limit exceeded")
        bodies = _arrow_values(values, max_bytes)

    def transport(value: Any) -> list[str | None]:
        if value is None or type(value) is str:
            return [value]
        if pa is not None and isinstance(value, pa.Array) and value.type == pa.string():
            return _arrow_values(value, max_bytes)
        raise ValidationError("Lance JSON argument must be a string, null, or Arrow Utf8 array")

    args = transport(argument)
    needles = transport(needle) if operation == 9 else []
    try:
        results = _kernel_module().lance_json(bodies, args, needles, operation, {
            "max_work": max_work, "max_results": max_results, "max_bytes": max_bytes,
            "deadline_ns": deadline,
            "cancelled": cancellation.cancelled if cancellation is not None else False,
        })
        if scalar:
            result = results[0]
            if operation == 4:
                return None if result is None else JsonbValue(result)
            if operation == 2:
                return {"value": None if result["value"] is None else JsonbValue(result["value"]),
                        "type_tag": result["type_tag"]}
            return result
        types = [pa.string(), pa.string(),
                 pa.struct([pa.field("value", pa.large_binary(), nullable=True),
                            pa.field("type_tag", pa.uint8(), nullable=False)]),
                 pa.bool_(), pa.large_binary(), pa.string(), pa.int64(), pa.float64(),
                 pa.bool_(), pa.bool_(), pa.int64()]
        return pa.array(results, type=types[operation])
    except Exception as error:
        raise map_kernel_error(error) from error


def json_path(values: Any, path: Any, **options: Any) -> Any:
    """Arrow JsonArray path semantics: render only the first selected value."""
    return _apply(0, values, path, **options)


def json_extract(values: Any, path: Any, **options: Any) -> Any:
    """Render one match or an array of multiple matches; missing returns null."""
    return _apply(1, values, path, **options)


def json_extract_with_type(values: Any, path: Any, **options: Any) -> Any:
    """Return {value: JSONB, type_tag: UInt8}; absent values have null/tag zero."""
    return _apply(2, values, path, **options)


def json_exists(values: Any, path: Any, **options: Any) -> Any:
    """Whether the source selector produces a value (including false/null)."""
    return _apply(3, values, path, **options)


def json_get(values: Any, key: Any, **options: Any) -> Any:
    """Get an exact object key or unsigned decimal array index as owned JSONB."""
    return _apply(4, values, key, **options)


def json_get_string(values: Any, key: Any, **options: Any) -> Any:
    """Get a nullable scalar string using source casts, without JSON quoting."""
    return _apply(5, values, key, **options)


def json_get_int(values: Any, key: Any, **options: Any) -> Any:
    """Get a nullable Int64; source fractional casts round ties away from zero."""
    return _apply(6, values, key, **options)


def json_get_float(values: Any, key: Any, **options: Any) -> Any:
    """Get a nullable Float64 using source numeric/string/boolean casts."""
    return _apply(7, values, key, **options)


def json_get_bool(values: Any, key: Any, **options: Any) -> Any:
    """Get a nullable bool; true/false/yes/no strings are case-insensitive."""
    return _apply(8, values, key, **options)


def json_array_contains(values: Any, path: Any, needle: Any, **options: Any) -> Any:
    """Compare selected arrays' rendered elements using Lance's string rules."""
    return _apply(9, values, path, needle, **options)


def json_array_length(values: Any, path: Any, **options: Any) -> Any:
    """Length of the first match; valid nonarrays give zero, missing gives null."""
    return _apply(10, values, path, **options)
