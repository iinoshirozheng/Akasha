"""Scalar protocols at the Python/native boundary, including rejected batches."""

from decimal import Decimal
from enum import IntEnum
from fractions import Fraction

import numpy as np
import pytest

from akashadb import Collection, PointMutation, SparseElement, ValidationError, VectorField


class SmallInteger(IntEnum):
    TWO = 2


class FloatConvertible:
    def __float__(self):
        return 2.0


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
@pytest.mark.parametrize("kind", ["dense", "multivector"])
def test_numeric_component_protocols_and_atomic_rejection(tmp_path, dtype, kind):
    integer = dtype in {"i8", "u8"}
    values = [SmallInteger.TWO, np.int64(3)] if integer else [Fraction(1, 2), np.float64(3)]
    expected = [2, 3] if integer else [0.5, 3.0]
    wrap = lambda row: row if kind == "dense" else [row]
    collection = Collection(tmp_path, 2, vectors={
        "v": VectorField(2, dtype=dtype, kind=kind, metric="dot"),
    })
    collection.apply_point_batch([PointMutation.upsert(1, vectors={"v": wrap(values)})])
    assert collection.get_point(1).vectors["v"] == wrap(expected)
    assert collection.search_field("v", wrap(values), 1)[0].score == sum(v * v for v in expected)
    rejected = [True, np.bool_(True), "2", 2 + 0j, Decimal("2"), FloatConvertible(), None]
    if integer:
        rejected += [2.0, Fraction(2, 1)]
    before = (tmp_path / "wal.bin").read_bytes()
    for value in rejected:
        with pytest.raises(ValidationError):
            collection.search_field("v", wrap([1, value]), 1)
        with pytest.raises(ValidationError):
            collection.apply_point_batch([
                PointMutation.upsert(2, vectors={"v": wrap(values)}),
                PointMutation.update(1, vectors={"v": wrap([1, value])}),
            ])
        assert collection.last_sequence == 1
        assert collection.get_point(2) is None
        assert collection.get_point(1).vectors["v"] == wrap(expected)
        assert (tmp_path / "wal.bin").read_bytes() == before
    collection.close()


def test_sparse_real_and_integer_protocols(tmp_path):
    collection = Collection(tmp_path, 2, vectors={"v": VectorField(0, kind="sparse", metric="dot")})
    values = [SparseElement(np.int64(2), Fraction(1, 2)), SparseElement(SmallInteger.TWO + 1, np.float64(3))]
    collection.apply_point_batch([PointMutation.upsert(1, vectors={"v": values})])
    assert collection.search_field("v", values, 1)[0].score == 9.25
    for values in ([SparseElement(True, 1)], [SparseElement(2.0, 1)],
                   [SparseElement(2, True)], [SparseElement(2, FloatConvertible())]):
        with pytest.raises(ValidationError):
            collection.search_field("v", values, 1)
    collection.close()


def test_binary_integer_protocols_and_bounds(tmp_path):
    collection = Collection(tmp_path, 2, vectors={"v": VectorField(16, kind="binary", dtype="binary", metric="hamming")})
    values = [np.uint8(255), SmallInteger.TWO]
    collection.apply_point_batch([PointMutation.upsert(1, vectors={"v": values})])
    assert collection.get_point(1).vectors["v"] == b"\xff\x02"
    assert collection.search_field("v", values, 1)[0].score == 0
    for value in [True, np.bool_(True), 2.0, -1, 256, "2"]:
        with pytest.raises(ValidationError):
            collection.search_field("v", [1, value], 1)
    collection.close()
