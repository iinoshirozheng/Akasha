"""Fixed shared inputs and an independent Float64 oracle for #59.

The synthetic stream mirrors post_hnsw_quality.mojo: shuffled IDs, initial
vectors, 10% replacements, second-half deletes every 20 slots, then four query
streams with three warmups each. No engine supplies the comparison's oracle.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path

import numpy as np

MODES = ("all", "correlated", "independent", "selective")
ARRAYS = ("ids", "vectors", "update_ids", "updates", "deletes", "queries")
MASK = (1 << 64) - 1
STEP = 0x9E3779B97F4A7C15
REAL_REVISION = "e8931e5eeba5b31bb9481f98687cf0ced14c2442"
REAL_SHA256 = "793fa64beb2d89added80b2a4640719e6a26216f31122d222f7b37ee2dbc24cb"
REAL_DATASET = "Qdrant/dbpedia-entities-openai3-text-embedding-3-large-1536-100K"
REAL_URL = (f"https://huggingface.co/datasets/{REAL_DATASET}/resolve/"
            f"{REAL_REVISION}/data/train-00000-of-00003.parquet")


class SplitMix64:
    def __init__(self, seed: int):
        self.state = seed & MASK

    def next_u64(self) -> int:
        self.state = (self.state + STEP) & MASK
        value = self.state
        value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK
        return value ^ (value >> 31)

    def words(self, count: int) -> np.ndarray:
        with np.errstate(over="ignore"):
            values = np.arange(1, count + 1, dtype=np.uint64) * np.uint64(STEP)
            values += np.uint64(self.state)
            self.state = (self.state + count * STEP) & MASK
            values = (values ^ (values >> 30)) * np.uint64(0xBF58476D1CE4E5B9)
            values = (values ^ (values >> 27)) * np.uint64(0x94D049BB133111EB)
            return values ^ (values >> 31)

    def vectors(self, count: int, dimension: int) -> np.ndarray:
        values = (self.words(count * dimension) & 0xFFFFFF).astype(np.float32)
        return (values / np.float32(8388608) - np.float32(1)).reshape(count, dimension)


@dataclass
class Workload:
    ids: np.ndarray
    vectors: np.ndarray
    update_ids: np.ndarray
    updates: np.ndarray
    deletes: np.ndarray
    queries: np.ndarray
    metadata: dict

    def checksum(self) -> str:
        digest = hashlib.sha256()
        digest.update(json.dumps(self.metadata, sort_keys=True).encode())
        for name in ARRAYS:
            value = getattr(self, name)
            digest.update(name.encode() + b"\0")
            digest.update(value.dtype.str.encode() + repr(value.shape).encode())
            digest.update(value.tobytes(order="C"))
        return digest.hexdigest()

    def final_state(self) -> tuple[np.ndarray, np.ndarray]:
        vectors = self.vectors.copy()
        lookup = {int(id): row for row, id in enumerate(self.ids)}
        for id, values in zip(self.update_ids, self.updates, strict=True):
            vectors[lookup[int(id)]] = values
        live = ~np.isin(self.ids, self.deletes)
        return self.ids[live], vectors[live]


def _ids(points: int, rng: SplitMix64) -> np.ndarray:
    ids = np.arange(points, dtype=np.int64)
    for index in range(points - 1, 0, -1):
        other = rng.next_u64() % (index + 1)
        ids[index], ids[other] = ids[other], ids[index]
    return ids


def synthetic_workload(points: int, dimension: int, queries: int,
                       seed: int = 12345) -> Workload:
    if points < 128 or dimension < 1 or queries < 1:
        raise ValueError("require points >= 128, dimension/queries > 0")
    rng = SplitMix64(seed)
    ids = _ids(points, rng)
    updates = points // 10
    return Workload(
        ids, rng.vectors(points, dimension), ids[:updates].copy(),
        rng.vectors(updates, dimension), ids[points // 2::20].copy(),
        rng.vectors(4 * (queries + 3), dimension).reshape(4, queries + 3, dimension),
        {"kind": "uniform-synthetic", "seed": seed, "warmups": 3,
         "generator": "post_hnsw_quality SplitMix64, Float32 signed 24-bit uniform",
         "update_percent": 10},
    )


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def real_workload(path: Path, points: int, queries: int, seed: int = 12345) -> Workload:
    import pyarrow.parquet as pq

    if points < 128 or queries < 1:
        raise ValueError("require points >= 128 and queries > 0")
    if file_sha256(path) != REAL_SHA256:
        raise ValueError("DBpedia source checksum mismatch")
    count = points + points // 10 + 4 * (queries + 3)
    chunks = []
    seen = 0
    for batch in pq.ParquetFile(path).iter_batches(
        batch_size=1024, columns=["text-embedding-3-large-1536-embedding"],
    ):
        vectors = np.array(batch.column(0).to_pylist(), dtype=np.float32)
        chunks.append(vectors[:count - seen])
        seen += len(chunks[-1])
        if seen == count:
            break
    if seen != count:
        raise ValueError("not enough disjoint corpus/update/query rows in source shard")
    values = np.concatenate(chunks)
    if values.shape != (count, 1536) or not np.isfinite(values).all():
        raise ValueError("invalid real embedding shape/values")
    ids = _ids(points, SplitMix64(seed))
    update_end = points + points // 10
    return Workload(
        ids, values[:points], ids[:points // 10].copy(), values[points:update_end],
        ids[points // 2::20].copy(), values[update_end:].reshape(4, queries + 3, 1536),
        {"kind": "real-embeddings", "dataset": REAL_DATASET,
         "revision": REAL_REVISION, "source_sha256": REAL_SHA256,
         "source_url": REAL_URL, "seed": seed, "warmups": 3,
         "selection": "contiguous source rows: initial corpus, replacements, queries",
         "source_rows": count, "cast": "source Float64 -> shared Float32", "update_percent": 10},
    )


def payload(id: int, seed: int) -> dict:
    mixed = ((id + seed) * STEP) & MASK
    return {"correlated": (id % 8) // 2, "independent": (mixed >> 32) % 4,
            "rare": id % 32, "payload": "x" * 256}


def filter_spec(mode: str, ordinal: int) -> tuple[str, int] | None:
    if mode == "all":
        return None
    if mode == "selective":
        return "rare", ordinal % 32
    if mode not in MODES:
        raise ValueError("unknown filter mode")
    return mode, (ordinal % 8) // 2


def allowed_ids(workload: Workload, mode: str, ordinal: int) -> set[int]:
    live = set(map(int, workload.ids)) - set(map(int, workload.deletes))
    condition = filter_spec(mode, ordinal)
    if condition is None:
        return live
    field, value = condition
    return {id for id in live if payload(id, workload.metadata["seed"])[field] == value}


def exact_ids(workload: Workload, query, metric: str, k: int,
              mode: str, ordinal: int) -> list[int]:
    ids, vectors = workload.final_state()
    allowed = allowed_ids(workload, mode, ordinal)
    mask = np.array([int(id) in allowed for id in ids], dtype=bool)
    ids, vectors = ids[mask], vectors[mask].astype(np.float64)
    query = np.asarray(query, dtype=np.float64)
    if metric == "dot":
        scores = -np.sum(vectors * query, axis=1)
    elif metric == "l2":
        scores = np.sum((vectors - query) ** 2, axis=1)
    elif metric == "cosine":
        denominator = np.linalg.norm(vectors, axis=1) * np.linalg.norm(query)
        scores = -np.divide(np.sum(vectors * query, axis=1), denominator,
                            out=np.zeros(len(ids)), where=denominator != 0)
    else:
        raise ValueError("unknown metric")
    return ids[np.lexsort((ids, scores))[:k]].tolist()


def validate_result(workload: Workload, result: list[int], expected: list[int],
                    mode: str, ordinal: int) -> float:
    if len(set(result)) != len(result):
        raise ValueError("duplicate result IDs")
    live = set(map(int, workload.ids)) - set(map(int, workload.deletes))
    if not set(result) <= live:
        raise ValueError("result contains a non-live ID")
    if not set(result) <= allowed_ids(workload, mode, ordinal):
        raise ValueError("result violates filter")
    if len(result) > len(expected):
        raise ValueError("result exceeds expected count")
    return len(set(result) & set(expected)) / len(expected) if expected else 1.0


def save_workload(path: Path, workload: Workload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez(path, **{name: getattr(workload, name) for name in ARRAYS},
             metadata=json.dumps(workload.metadata, sort_keys=True),
             checksum=workload.checksum())


def load_workload(path: Path) -> Workload:
    with np.load(path, allow_pickle=False) as data:
        workload = Workload(**{name: data[name] for name in ARRAYS},
                            metadata=json.loads(str(data["metadata"])))
        if workload.checksum() != str(data["checksum"]):
            raise ValueError("workload checksum mismatch")
    return workload
