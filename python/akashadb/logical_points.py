"""Versioned NDJSON representation of complete native point states."""

from dataclasses import asdict
import json
from pathlib import Path
import re
from typing import Any

from .models import CollectionConfig, PayloadField
from .vectors import PointMutation, VectorField


FORMAT = "akashadb.points"
VERSION = 1
_CONFIG_KEYS = {"dimension", "ann_metric", "scalar_kind", "m", "m0", "ef_construction",
                "default_ef_search", "max_ef_search", "max_level", "rebuild_inactive_percent",
                "delta_max_points", "level_seed"}
_FIELD_KEYS = {"dimension", "dtype", "kind", "metric", "hnsw"}
_HEADER_KEYS = {"format", "version", "config", "vectors", "count", "source_sequence"}
_POINT_KEYS = {"id", "sequence", "document_sequence", "vector", "sparse", "vectors", "fields"}


def _config_json(config: CollectionConfig) -> dict[str, Any]:
    return {key: getattr(config, key) for key in sorted(_CONFIG_KEYS)}


def encode_export(captured: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    schema = {item["name"]: VectorField.from_kernel(item)
              for item in captured["schema"] if item["id"] >= 2}
    encoded_schema = {}
    for name, spec in schema.items():
        value = asdict(spec)
        value["hnsw"] = None if spec.hnsw is None else _config_json(spec.hnsw)
        encoded_schema[name] = value
    rows = captured["points"]
    for row in rows:
        row["vectors"] = {
            name: {"encoding": "hex", "data": value.hex()}
            if schema[name].kind == "binary" else value
            for name, value in row["vectors"].items()
        }
    header = {"format": FORMAT, "version": VERSION,
              "config": _config_json(CollectionConfig.from_kernel(captured["config"])),
              "vectors": encoded_schema, "count": len(rows),
              "source_sequence": captured["source_sequence"]}
    return header, rows


def _object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError(f"invalid {label} fields")
    return value


def _integer(value: Any, low: int, high: int, label: str) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"invalid {label}")
    return value


def decode_header(header: dict[str, Any]) -> tuple[CollectionConfig, dict[str, VectorField]]:
    _object(header, _HEADER_KEYS, "point export header")
    if header["format"] != FORMAT or type(header["version"]) is not int or header["version"] != VERSION:
        raise ValueError("unsupported logical point export version")
    _integer(header["count"], 0, (1 << 63) - 1, "point count")
    _integer(header["source_sequence"], 0, (1 << 64) - 1, "source sequence")
    config = CollectionConfig(**_object(header["config"], _CONFIG_KEYS, "collection config"))
    if not isinstance(header["vectors"], dict):
        raise ValueError("point export vectors must be a schema object")
    schema = {}
    for name, raw in header["vectors"].items():
        if type(name) is not str or not name or "\x00" in name:
            raise ValueError("invalid named vector field name")
        value = dict(_object(raw, _FIELD_KEYS, "vector schema"))
        if value["hnsw"] is not None:
            value["hnsw"] = CollectionConfig(**_object(value["hnsw"], _CONFIG_KEYS, "field HNSW config"))
        schema[name] = VectorField(**value)
    return config, schema


def is_point_header(value: dict[str, Any]) -> bool:
    # A malformed or future header must not be interpreted as a legacy row.
    return "format" in value or "version" in value


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError(f"duplicate JSON field: {name}")
        result[name] = value
    return result


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def decode_line(line: str, line_number: int) -> dict[str, Any]:
    try:
        value = json.loads(line, object_pairs_hook=_unique_object, parse_constant=_reject_constant)
    except (ValueError, TypeError) as error:
        raise ValueError(f"invalid NDJSON at line {line_number}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"NDJSON line {line_number} must be an object")
    return value


def import_schema(source: str | Path) -> tuple[CollectionConfig, dict[str, VectorField]] | None:
    """Read an optional schema so the CLI can create the correct target catalog."""
    with Path(source).open("r", encoding="utf-8") as stream:
        line = stream.readline()
    if not line:
        return None
    header = decode_line(line, 1)
    return decode_header(header) if is_point_header(header) else None


def _sparse(value: Any) -> Any:
    if value is None:
        return None
    if not isinstance(value, list):
        raise ValueError("sparse values must be a list")
    for item in value:
        _object(item, {"term_id", "weight"}, "sparse element")
    return value


def _vector(value: Any, spec: VectorField) -> Any:
    if value is None:
        raise ValueError("absent named vectors must be omitted")
    if spec.kind == "binary":
        _object(value, {"encoding", "data"}, "binary vector")
        data = value["data"]
        if (value["encoding"] != "hex" or type(data) is not str
                or len(data) != 2 * ((spec.dimension + 7) // 8)
                or re.fullmatch(r"[0-9a-fA-F]*", data) is None):
            raise ValueError("invalid binary hexadecimal data")
        return bytes.fromhex(data)
    if spec.kind == "sparse":
        return _sparse(value)
    if not isinstance(value, list):
        raise ValueError("numeric vectors must be lists")
    # Native conversion validates dimension, dtype range, finite values and
    # padding for the complete batch before appending its WAL envelope.
    return value


def decode_points(header: dict[str, Any], rows: list[dict[str, Any]],
                  schema: dict[str, VectorField]) -> list[PointMutation]:
    if len(rows) != header["count"]:
        raise ValueError("point export row count mismatch")
    result = []
    seen = set()
    for row in rows:
        _object(row, _POINT_KEYS, "point record")
        point_id = _integer(row["id"], -(1 << 63), (1 << 63) - 1, "point ID")
        if point_id in seen:
            raise ValueError("duplicate point ID in logical import")
        seen.add(point_id)
        sequence = _integer(row["sequence"], 1, header["source_sequence"], "point sequence")
        _integer(row["document_sequence"], 0, sequence, "document sequence")
        vectors = row["vectors"]
        if not isinstance(vectors, dict) or not set(vectors) <= set(schema):
            raise ValueError("unknown or invalid named vectors")
        updates = {name: _vector(vectors[name], spec) if name in vectors else None
                   for name, spec in schema.items()}
        if row["vector"] is not None and not isinstance(row["vector"], list):
            raise ValueError("default vector must be a list or null")
        if not isinstance(row["fields"], list):
            raise ValueError("payload fields must be a list")
        payload = [PayloadField(**_object(item, {"name", "type", "value"}, "payload"))
                   for item in row["fields"]]
        result.append(PointMutation.upsert(point_id, vector=row["vector"],
                                          sparse=_sparse(row["sparse"]),
                                          vectors=updates, fields=payload))
    return result
