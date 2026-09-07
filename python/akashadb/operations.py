"""Typed operational tooling over Mojo-owned storage semantics."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import math
import os
from pathlib import Path
import re
from typing import Any

from .database import Collection, _kernel_module
from .models import BatchMutation, PayloadField, SparseElement


@dataclass(frozen=True, slots=True)
class StorageReport:
    dimension: int
    format_version: int
    generation: int
    last_sequence: int
    segment_count: int
    live_points: int
    valid: bool
    config_fingerprint: int
    segment_names: tuple[str, ...]
    sparse_names: tuple[str, ...]

    @classmethod
    def from_kernel(cls, value: dict[str, Any]) -> "StorageReport":
        return cls(
            dimension=int(value["dimension"]),
            format_version=int(value["format_version"]),
            generation=int(value["generation"]),
            last_sequence=int(value["last_sequence"]),
            segment_count=int(value["segment_count"]),
            live_points=int(value["live_points"]),
            valid=bool(value["valid"]),
            config_fingerprint=int(value["config_fingerprint"]),
            segment_names=tuple(str(name) for name in value["segment_names"]),
            sparse_names=tuple(str(name) for name in value["sparse_names"]),
        )


def inspect_storage(path: str | Path, dimension: int) -> StorageReport:
    return StorageReport.from_kernel(
        _kernel_module().inspect_storage(str(path), dimension)
    )


def backup_collection(
    collection: Collection, target: str | Path
) -> StorageReport:
    return StorageReport.from_kernel(collection.backup(target))


def restore_storage(
    backup: str | Path, target: str | Path, dimension: int
) -> StorageReport:
    return StorageReport.from_kernel(
        _kernel_module().restore_storage(str(backup), str(target), dimension)
    )


def export_ndjson(collection: Collection, target: str | Path) -> int:
    """Atomically publish an owned logical point export."""
    destination = Path(target)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    rows = collection._export_records()
    with temporary.open("w", encoding="utf-8") as output:
        for row in rows:
            output.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
            output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, destination)
    return len(rows)


def import_ndjson(collection: Collection, source: str | Path) -> int:
    """Validate the complete export before committing any mutation."""
    rows: list[dict[str, Any]] = []
    with Path(source).open("r", encoding="utf-8") as input_file:
        for line_number, line in enumerate(input_file, start=1):
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"invalid NDJSON at line {line_number}") from error
            if not isinstance(value, dict):
                raise ValueError(f"NDJSON line {line_number} must be an object")
            rows.append(value)
    if not rows:
        raise ValueError("logical import cannot be empty")
    if len(rows) > collection.limits.max_batch_rows:
        raise ValueError("logical import resource limit exceeded")

    mutations: list[BatchMutation] = []
    sparse_rows: list[tuple[int, list[SparseElement]]] = []
    for row in rows:
        point_id = int(row["id"])
        vector = [float(value) for value in row["vector"]]
        fields = [
            PayloadField(str(item["name"]), str(item["type"]), item["value"])
            for item in row.get("fields", [])
        ]
        elements = [
            SparseElement(int(item["term_id"]), float(item["weight"]))
            for item in row.get("sparse", [])
        ]
        _validate_sparse(elements)
        mutations.append(BatchMutation.upsert(point_id, vector, fields))
        sparse_rows.append((point_id, elements))

    collection.apply_batch(mutations)
    for point_id, elements in sparse_rows:
        if elements:
            collection.upsert_sparse(point_id, elements)
    return len(rows)


_ORPHAN_PATTERN = re.compile(
    r"^(?:segment|sparse)-(?:base-|delta-)?\d+\.bin(?:\.tmp)?$|^manifest\.bin\.tmp$"
)


def quarantine_orphans(
    path: str | Path, dimension: int, quarantine: str | Path
) -> tuple[Path, ...]:
    """Move only allow-listed, unreferenced Akasha artifacts."""
    directory = Path(path)
    report = inspect_storage(directory, dimension)
    referenced = {"manifest.bin", *report.segment_names, *report.sparse_names}
    target = Path(quarantine)
    target.mkdir(parents=True, exist_ok=True)
    moved: list[Path] = []
    for candidate in sorted(directory.iterdir()):
        if candidate.name in referenced or not _ORPHAN_PATTERN.fullmatch(candidate.name):
            continue
        destination = target / candidate.name
        if destination.exists():
            raise FileExistsError(f"quarantine target exists: {destination}")
        os.replace(candidate, destination)
        moved.append(destination)
    return tuple(moved)


def _validate_sparse(elements: list[SparseElement]) -> None:
    previous = -1
    for element in elements:
        if element.term_id < 0 or element.term_id <= previous:
            raise ValueError("sparse term IDs must be non-negative and ascending")
        if not math.isfinite(element.weight) or element.weight == 0.0:
            raise ValueError("sparse weights must be finite and non-zero")
        previous = element.term_id


def report_json(report: StorageReport) -> str:
    return json.dumps(asdict(report), sort_keys=True)
