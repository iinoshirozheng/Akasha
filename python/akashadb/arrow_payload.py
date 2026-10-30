"""Arrow type and borrowed-buffer adapters; payload traversal lives in Mojo.

Struct.field applies the parent slice. List offsets address the logical child;
fixed-list values additionally need the parent's fixed-width slice. Keep these
operations separate so an independently sliced child is never offset twice.
"""

from typing import Any

import numpy as np
import pyarrow as pa


def type_descriptor(dtype: pa.DataType, *, name: str = "", nullable: bool = True,
                    _depth: int = 0) -> dict[str, Any]:
    if "\0" in name:
        raise ValueError("Arrow C Data field names cannot contain NUL")
    if _depth > 64:
        raise ValueError("Arrow payload schema depth exceeds limit")
    children: list[dict[str, Any]] = []
    bits = size = 0
    if pa.types.is_null(dtype):
        kind = 0
    elif pa.types.is_boolean(dtype):
        kind = 1
    elif pa.types.is_signed_integer(dtype):
        kind, bits = 2, dtype.bit_width
    elif pa.types.is_unsigned_integer(dtype):
        kind, bits = 3, dtype.bit_width
    elif pa.types.is_floating(dtype):
        kind, bits = 4, dtype.bit_width
    elif pa.types.is_string(dtype):
        kind = 5
    elif pa.types.is_large_string(dtype):
        kind = 6
    elif pa.types.is_struct(dtype):
        kind = 7
        children = [_field_descriptor(f, _depth + 1) for f in dtype]
    elif pa.types.is_list(dtype) or pa.types.is_large_list(dtype) or pa.types.is_fixed_size_list(dtype):
        kind = 8 if pa.types.is_list(dtype) else 9 if pa.types.is_large_list(dtype) else 10
        size = dtype.list_size if kind == 10 else 0
        f = dtype.value_field
        children = [_field_descriptor(f, _depth + 1)]
    else:
        raise ValueError(f"unsupported payload Arrow type: {dtype}")
    return dict(kind=kind, bits=bits, size=size, name=name, nullable=nullable, children=children, metadata=None)


def _field_descriptor(field: pa.Field, depth: int = 0) -> dict[str, Any]:
    # Unknown extensions can arrive as their storage type plus field metadata.
    # Do not silently interpret an extension as plain JSON-compatible storage.
    if b"ARROW:extension:name" in (field.metadata or {}):
        raise ValueError("Arrow payload extension types are not yet supported")
    result = type_descriptor(field.type, name=field.name, nullable=field.nullable, _depth=depth)
    result["metadata"] = field.metadata
    return result


def projection_descriptor(name: str, requested: Any) -> dict[str, Any]:
    aliases = {"string": pa.string(), "int": pa.int64(), "float": pa.float64(), "bool": pa.bool_()}
    if isinstance(requested, str):
        if requested not in aliases:
            raise ValueError(f"unsupported scanner payload type: {requested!r}")
        requested = aliases[requested]
    if isinstance(requested, pa.Field):
        if requested.name != name:
            raise ValueError("payload projection field name must match its mapping key")
        field = requested
    elif isinstance(requested, pa.DataType):
        field = pa.field(name, requested)
    else:
        raise ValueError(f"unsupported scanner payload type: {requested!r}")
    return _field_descriptor(field)


def validate_c_field_names(schema: pa.Schema) -> None:
    """Reject names that C Data's NUL-terminated schema would silently truncate."""
    def visit(field: pa.Field, depth: int) -> None:
        if "\0" in field.name:
            raise ValueError("Arrow C Data field names cannot contain NUL")
        if depth > 64:
            raise ValueError("Arrow schema depth exceeds limit")
        for index in range(field.type.num_fields):
            visit(field.type.field(index), depth + 1)

    for field in schema:
        visit(field, 0)


def _bytes(buffer: Any) -> np.ndarray:
    return np.empty(0, dtype=np.uint8) if buffer is None else np.frombuffer(buffer, dtype=np.uint8)


def _borrow(array: Any, schema: dict[str, Any]) -> dict[str, Any]:
    kind, bits = schema["kind"], schema["bits"]
    result = {**schema, "row_count": len(array), "validity": _bytes(array.buffers()[0]),
              "validity_offset": array.offset}
    if kind in (2, 3, 4):
        prefix = {2: "int", 3: "uint", 4: "float"}[kind]
        dtype = np.dtype(f"{prefix}{bits}")
        buffer = array.buffers()[1]
        result["values"] = np.empty(0, dtype=dtype) if buffer is None else np.frombuffer(
            buffer, dtype=dtype, count=len(array), offset=array.offset * dtype.itemsize)
    elif kind == 1:
        result["values"] = _bytes(array.buffers()[1])
    elif kind in (5, 6, 8, 9):
        dtype = np.dtype("int64" if kind in (6, 9) else "int32")
        buffer = array.buffers()[1]
        result["offsets"] = np.empty(0, dtype=dtype) if buffer is None else np.frombuffer(
            buffer, dtype=dtype, count=len(array) + 1, offset=array.offset * dtype.itemsize)
        if kind in (5, 6):
            result["values"] = _bytes(array.buffers()[2])
        else:
            result["children"] = [_borrow(array.values, schema["children"][0])]
    elif kind == 7:
        result["children"] = [_borrow(array.field(i), child) for i, child in enumerate(schema["children"])]
    elif kind == 10:
        size = schema["size"]
        child = array.values.slice(array.offset * size, len(array) * size)
        result["children"] = [_borrow(child, schema["children"][0])]
    return result


def payload_descriptor(array: Any, field: pa.Field) -> dict[str, Any]:
    return _borrow(array, _field_descriptor(field))
