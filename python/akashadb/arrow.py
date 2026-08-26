"""Copying Arrow-compatible column adapters.

These functions accept ordinary sequences, NumPy arrays, or PyArrow columns via
their Python sequence interface. They deliberately do not claim zero-copy.
"""

from collections.abc import Mapping, Sequence
from typing import Any

from .database import Collection
from .models import PayloadField, SearchResult


def upsert_columns(collection: Collection, columns: Mapping[str, Any]) -> int:
    """Validate and copy an ID/vector/payload column batch into the Mojo kernel."""
    if "id" not in columns or "vector" not in columns:
        raise ValueError("column batch requires id and vector columns")
    ids = _to_list(columns["id"])
    vectors = _to_list(columns["vector"])
    payloads = _to_list(columns.get("fields", [None] * len(ids)))
    if len(ids) != len(vectors) or len(ids) != len(payloads):
        raise ValueError("Arrow-compatible columns must have equal lengths")
    for id_value, vector_value, payload_value in zip(ids, vectors, payloads):
        fields = None
        if payload_value is not None:
            fields = [PayloadField(**dict(item)) for item in payload_value]
        collection.upsert(
            int(id_value), [float(value) for value in vector_value], fields
        )
    return len(ids)


def results_to_columns(results: Sequence[SearchResult]) -> dict[str, list[Any]]:
    """Return fresh Arrow-compatible primitive columns."""
    return {
        "id": [int(result.id) for result in results],
        "score": [float(result.score) for result in results],
    }


def _to_list(value: Any) -> list[Any]:
    if hasattr(value, "to_pylist"):
        return list(value.to_pylist())
    if hasattr(value, "tolist"):
        return list(value.tolist())
    return list(value)
