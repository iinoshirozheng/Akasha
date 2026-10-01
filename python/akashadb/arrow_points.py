"""Schema validation and borrowed primitive views for atomic point ingress."""

from typing import Any

import numpy as np
import pyarrow as pa

from .database import Collection
from .vectors import VectorField


def _validity(array: Any) -> dict[str, Any]:
    buffer = array.buffers()[0]
    return {
        "validity": np.empty(0, dtype=np.uint8) if buffer is None else np.frombuffer(buffer, dtype=np.uint8),
        "validity_offset": array.offset,
    }


def _primitive(array: Any) -> dict[str, Any]:
    """Borrow physical data; the kernel checks validity on selected components.

    A null parent may have null primitive children. Those bytes are ignored,
    while a null component of a present vector is always rejected.
    """
    dtype = np.dtype({pa.int8(): "int8", pa.uint8(): "uint8", pa.uint16(): "uint16",
                      pa.int32(): "int32", pa.int64(): "int64", pa.float16(): "float16",
                      pa.float32(): "float32"}[array.type])
    buffer = array.buffers()[1]
    values = np.empty(0, dtype=dtype) if buffer is None else np.frombuffer(
        buffer, dtype=dtype, count=len(array), offset=array.offset * dtype.itemsize
    )
    return {"values": values, **_validity(array)}


def _vector_descriptor(array: Any, spec: VectorField, metadata: dict[bytes, bytes] | None) -> dict[str, Any]:
    descriptor = _validity(array)
    descriptor["row_count"] = len(array)
    if spec.kind == "binary":
        width = (spec.dimension + 7) // 8
        if array.type != pa.binary(width):
            raise ValueError("binary field requires fixed-size bytes matching its bit dimension")
        buffer = array.buffers()[1]
        descriptor["values"] = np.frombuffer(buffer, dtype=np.uint8, count=len(array) * width, offset=array.offset * width)
        return descriptor
    if spec.kind == "sparse":
        if not pa.types.is_list(array.type) or not pa.types.is_struct(array.type.value_type):
            raise ValueError("sparse field requires list<struct<term_id: int64, weight: float32>>")
        inner = array.values
        if inner.type.names != ["term_id", "weight"] or inner.type[0].type != pa.int64() or inner.type[1].type != pa.float32():
            raise ValueError("sparse element types must be int64 term_id and float32 weight")
        descriptor.update(offsets=_primitive(array.offsets)["values"], elements=_validity(inner),
                          terms=_primitive(inner.field(0)), weights=_primitive(inner.field(1)))
        return descriptor
    scalar = {"f32": pa.float32(), "f16": pa.float16(), "bf16": pa.uint16(), "i8": pa.int8(), "u8": pa.uint8()}[spec.dtype]
    if spec.dtype == "bf16" and (metadata or {}).get(b"akashadb.dtype") != b"bf16":
        raise ValueError("BF16 Arrow fields require akashadb.dtype=bf16 metadata for UInt16 bits")
    vector_type = pa.list_(scalar, spec.dimension)
    expected = pa.list_(vector_type) if spec.kind == "multivector" else vector_type
    if array.type != expected:
        raise ValueError(f"vector Arrow type must match {expected}")
    if spec.kind == "multivector":
        inner = array.values
        descriptor.update(offsets=_primitive(array.offsets)["values"], elements=_validity(inner))
    else:
        inner = array
    # List offsets address the logical fixed-list child; remove that child's
    # own offset once, including when the producer independently sliced it.
    descriptor["components"] = _primitive(inner.values.slice(inner.offset * spec.dimension, len(inner) * spec.dimension))
    return descriptor


def point_descriptor(collection: Collection, batch: Any) -> dict[str, Any]:
    if not isinstance(batch, pa.RecordBatch):
        raise TypeError("Arrow producer must yield one RecordBatch")
    batch.validate(full=True)
    if not 0 < batch.num_rows <= min(collection.limits.max_batch_rows, 65_536):
        raise ValueError("point Arrow batch row count exceeds resource limit")
    names = batch.schema.names
    if len(set(names)) != len(names) or "id" not in names:
        raise ValueError("point Arrow batch requires unique column names and id")
    ids = batch.column("id")
    if ids.type != pa.int64() or ids.null_count:
        raise ValueError("id must be non-null int64")
    schema = collection.vector_fields()
    updates = []
    payloads = []
    payload_types = {pa.string(): "string", pa.int64(): "int", pa.float64(): "float", pa.bool_(): "bool"}
    for name in names:
        if name == "id":
            continue
        array = batch.column(name)
        if name.startswith("payload."):
            key = name.removeprefix("payload.")
            if not key or "\0" in key or array.type not in payload_types:
                raise ValueError("invalid Arrow payload name or type")
            payloads.append({"name": key, "type": payload_types[array.type], "values": array})
            continue
        if name == "vector":
            spec = VectorField(collection.dimension)
            identity = {"id": 0}
        elif name == "sparse":
            spec = VectorField(0, kind="sparse", metric="dot")
            identity = {"id": 1}
        elif name.startswith("vectors.") and name.removeprefix("vectors.") in schema:
            key = name.removeprefix("vectors.")
            spec = schema[key]
            identity = {"name": key}
        else:
            raise ValueError(f"unknown point Arrow column: {name}")
        updates.append({**identity, **_vector_descriptor(array, spec, batch.schema.field(name).metadata)})
    return {"row_count": batch.num_rows, "ids": _primitive(ids)["values"], "updates": updates,
            "payloads": payloads, "owners": batch}
