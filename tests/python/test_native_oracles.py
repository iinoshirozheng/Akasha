"""Independent Float64 numerical oracles across native public field APIs."""

import math

import numpy as np
import pytest

from akashadb import Collection, PayloadField, PointMutation, VectorField


def score(metric, left, right):
    if metric == "l2":
        return math.fsum((float(a) - float(b)) ** 2 for a, b in zip(left, right))
    dot = math.fsum(float(a) * float(b) for a, b in zip(left, right))
    if metric == "dot":
        return dot
    return dot / math.sqrt(math.fsum(float(x) ** 2 for x in left)) / math.sqrt(math.fsum(float(x) ** 2 for x in right))


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
@pytest.mark.parametrize("kind", ["dense", "multivector"])
def test_native_filtered_topk_matches_independent_oracle_before_after_reopen(tmp_path, dtype, metric, kind):
    rng = np.random.default_rng(42)
    matrices = rng.integers(1 if dtype == "u8" else -20, 21, size=(17, 4, 7))
    query = rng.integers(1 if dtype == "u8" else -20, 21, size=(3, 7))
    # Quarter-integers are exact in all three floating representations; the
    # oracle is independent of both native conversion and scoring code.
    if dtype in {"f32", "f16", "bf16"}:
        matrices = matrices.astype(np.float64) / 4
        query = query.astype(np.float64) / 4
    candidates = [matrix[0].tolist() if kind == "dense" else matrix[:i % 5].tolist()
                  for i, matrix in enumerate(matrices)]
    request = query[0].tolist() if kind == "dense" else query.tolist()
    collection = Collection(tmp_path, 1, vectors={"v": VectorField(7, dtype=dtype, kind=kind, metric=metric)})
    collection.apply_point_batch([
        PointMutation.upsert(i, vectors={"v": vector}, fields=[PayloadField("eligible", "int", i % 2)])
        for i, vector in enumerate(candidates)
    ] + [PointMutation.upsert(99, fields=[PayloadField("eligible", "int", 1)])])
    oracle = []
    for i, vector in enumerate(candidates):
        if i % 2 == 0 or not vector:
            continue
        if kind == "dense":
            value = score(metric, request, vector)
        else:
            select = min if metric == "l2" else max
            value = math.fsum(select(score(metric, row, candidate) for candidate in vector) for row in request)
        oracle.append((i, value))
    oracle.sort(key=lambda item: (item[1] if metric == "l2" else -item[1], item[0]))
    expression = {"kind": "condition", "operator": "eq", "name": "eligible", "type": "int", "value": 1}
    for reopened in (False, True):
        if reopened:
            collection.flush()
            collection.close()
            collection = Collection(tmp_path, 1)
        hits = collection.search_field("v", request, 5, filter=expression)
        assert [hit.id for hit in hits] == [item[0] for item in oracle[:5]]
        assert [hit.score for hit in hits] == pytest.approx([item[1] for item in oracle[:5]], rel=1e-12, abs=1e-12)
    collection.close()


@pytest.mark.parametrize("metric", ["hamming", "jaccard"])
def test_binary_partial_byte_matches_integer_set_oracle(tmp_path, metric):
    collection = Collection(tmp_path, 1, vectors={"b": VectorField(13, dtype="binary", kind="binary", metric=metric)})
    values = [0, 1, 7, 31, 0x1000, 0x1007, 0x1FFF]
    collection.apply_point_batch([PointMutation.upsert(i, vectors={"b": value.to_bytes(2, "little")}) for i, value in enumerate(values)])
    collection.flush()
    collection.close()
    collection = Collection(tmp_path, 1)
    for query in (0, 0x1005, 0x1FFF):
        oracle = [(i, (query ^ value).bit_count() if metric == "hamming" else
                   0 if (query | value) == 0 else 1 - (query & value).bit_count() / (query | value).bit_count())
                  for i, value in enumerate(values)]
        oracle.sort(key=lambda item: (item[1], item[0]))
        hits = collection.search_field("b", query.to_bytes(2, "little"), len(values))
        assert [hit.id for hit in hits] == [item[0] for item in oracle]
        assert [hit.score for hit in hits] == pytest.approx([item[1] for item in oracle])
    collection.close()
