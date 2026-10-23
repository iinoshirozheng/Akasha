"""Named scalar validation preserves Python callable, truth and reentry behavior."""
import hashlib
from pathlib import Path
import subprocess
import sys
import pytest
from akashadb import _kernel


def _exercise(path, kind, shape, behavior, operation):
    import builtins
    import gc
    import numbers
    import weakref
    from akashadb import Collection, PointMutation, VectorField

    field = {"real": VectorField(1, metric="dot"),
             "integer": VectorField(1, dtype="i8", metric="dot"),
             "multi": VectorField(1, kind="multivector", metric="dot"),
             "sparse": VectorField(0, kind="sparse", metric="dot"),
             "binary": VectorField(8, kind="binary", dtype="binary", metric="hamming")}[kind]
    integer = kind in ("integer", "binary")
    expected_type = numbers.Integral if integer else numbers.Real
    db = Collection(path / "db", 2, vectors={"v": field})
    def wrap(value):
        if kind == "multi": return [[value]]
        if kind == "sparse": return [dict(term_id=3, weight=value)]
        return [value]
    opts = dict(mode="exact", ivf=None, cancelled=False, deadline_ns=0,
                max_candidates=100, ef_search=-1, rerank_k=0, filter=None)
    def mutation(id, value):
        return dict(operation="upsert", id=id, updates=[dict(name="v", value=wrap(value))], fields=None)
    native = db._kernel
    native.apply_point_batch([mutation(1, 2)])
    sequence = db.last_sequence
    wal = (path / "db/wal.bin").read_bytes()
    original = builtins.isinstance
    bool_type = builtins.bool
    events = []
    refs = []
    closed = False
    class Value:
        def __float__(self):
            events.append("float")
            return 2.0
        def __int__(self):
            events.append("int")
            return 2
        __index__ = __int__
    value = Value()
    class Truth:
        def __init__(self, result): self.result = result
        def __bool__(self):
            events.append("truth")
            if behavior == "truth_error": raise ValueError("vector truth sentinel")
            return self.result
    def custom(raw, cls):
        nonlocal closed
        if type(raw) is not Value:
            return original(raw, cls)
        events.append("bool" if cls is bool_type else "numeric")
        assert cls is expected_type or cls is bool_type
        if behavior == "call_error": raise ValueError("vector callable sentinel")
        if behavior == "close" and not closed:
            closed = True
            db.close()
        result = Truth(cls is expected_type)
        refs.append(weakref.ref(result))
        return result
    class Callable:
        def __call__(self, raw, cls): return custom(raw, cls)
    callable_value = custom if shape == "function" else Callable()
    callable_ref = weakref.ref(callable_value)
    result = error = None
    builtins.isinstance = callable_value
    try:
        if operation == "search":
            for _ in range(16 if behavior == "accept" else 1):
                result = native.search_field("v", wrap(value), 1, opts)
        else:
            result = native.apply_point_batch([mutation(2, 2), mutation(1, value)])
    except Exception as caught:
        error = str(caught)
    finally:
        builtins.isinstance = original
    if behavior == "accept":
        assert error is None, error
        if operation == "search":
            assert result[0]["id"] == 1
            assert result[0]["score"] == (0 if kind == "binary" else 4)
        unit = ["numeric", "truth", "bool", "truth", "int" if integer else "float"]
        assert events == unit * (16 if operation == "search" else 1), events
    else:
        expected = {"call_error": "vector callable sentinel", "truth_error": "vector truth sentinel", "close": "collection is closed"}[behavior]
        assert error and expected in error, error
        if not closed:
            assert db.last_sequence == sequence
            assert (path / "db/wal.bin").read_bytes() == wal
            assert db.get_point(2) is None
        else:
            assert (path / "db/wal.bin").read_bytes() == wal
    db.close()
    del callable_value, custom
    gc.collect()
    assert callable_ref() is None, "conversion retained its callable"
    assert all(ref() is None for ref in refs), "conversion leaked a truth result"
    reopened = Collection(path / "db", 2, vectors={"v": field})
    assert reopened.last_sequence == (sequence + 2 if behavior == "accept" and operation == "update" else sequence)
    assert reopened._kernel.search_field("v", wrap(2), 1, opts)[0]["id"] == 1
    reopened.close()
    print("callable protocol and reference ownership checked")


def _child(tmp_path, kind, shape, behavior, operation):
    binary = Path(_kernel.__file__).resolve()
    script = """
import hashlib, pathlib, runpy, sys
from akashadb import _kernel
assert pathlib.Path(_kernel.__file__).resolve() == pathlib.Path(sys.argv[2])
assert hashlib.sha256(pathlib.Path(_kernel.__file__).read_bytes()).hexdigest() == sys.argv[3]
runpy.run_path(sys.argv[1])["_exercise"](pathlib.Path(sys.argv[4]), *sys.argv[5:])
"""
    result = subprocess.run(["rtk", "proxy", sys.executable, "-c", script,
        str(Path(__file__).resolve()), str(binary), hashlib.sha256(binary.read_bytes()).hexdigest(),
        str(tmp_path), kind, shape, behavior, operation], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "callable protocol and reference ownership checked" in result.stdout


@pytest.mark.parametrize("kind", ["real", "integer", "multi", "sparse", "binary"])
@pytest.mark.parametrize("shape", ["function", "object"])
@pytest.mark.parametrize("behavior", ["accept", "call_error", "truth_error"])
def test_scalar_callable_protocol(tmp_path, kind, shape, behavior):
    _child(tmp_path, kind, shape, behavior, "search" if behavior == "accept" else "update")


@pytest.mark.parametrize("shape", ["function", "object"])
@pytest.mark.parametrize("operation", ["search", "update"])
def test_scalar_callable_can_close_collection(tmp_path, shape, operation):
    _child(tmp_path, "real", shape, "close", operation)


def _exercise_class(path, behavior):
    import gc
    import weakref
    from akashadb import Collection, PointMutation, VectorField
    db = Collection(path / "db", 2, vectors={"v": VectorField(1, metric="dot")})
    db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [2.0]})])
    native = db._kernel
    wal = (path / "db/wal.bin").read_bytes()
    events = []
    class Value:
        @property
        def __class__(self):
            events.append("class")
            if behavior == "error": raise ValueError("class callback sentinel")
            if behavior == "close": db.close()
            return float
        def __float__(self):
            events.append("float")
            return 2.0
    value = Value()
    ref = weakref.ref(value)
    opts = dict(mode="exact", ivf=None, cancelled=False, deadline_ns=0,
                max_candidates=100, ef_search=-1, rerank_k=0, filter=None)
    error = None
    query = [value]
    try:
        hits = native.search_field("v", query, 1, opts)
    except Exception as caught:
        error = str(caught)
    if behavior == "accept":
        assert error is None, error
        assert hits[0]["id"] == 1 and hits[0]["score"] == 4
        assert events[-1] == "float"
    else:
        assert error and ("class callback sentinel" if behavior == "error" else "collection is closed") in error
    assert "class" in events
    db.close()
    # Detach the caller-owned container to check callback/exception references.
    query.clear()
    del value
    gc.collect()
    assert ref() is None, "exception retained scalar"
    assert (path / "db/wal.bin").read_bytes() == wal
    db = Collection(path / "db", 2, vectors={"v": VectorField(1, metric="dot")})
    assert db.search_field("v", [2.0], 1)[0].id == 1
    db.close()
    print("class protocol checked")


@pytest.mark.parametrize("behavior", ["accept", "error", "close"])
def test_builtin_isinstance_class_protocol(tmp_path, behavior):
    binary = Path(_kernel.__file__).resolve()
    script = """
import hashlib, pathlib, runpy, sys
from akashadb import _kernel
assert pathlib.Path(_kernel.__file__).resolve() == pathlib.Path(sys.argv[2])
assert hashlib.sha256(pathlib.Path(_kernel.__file__).read_bytes()).hexdigest() == sys.argv[3]
runpy.run_path(sys.argv[1])["_exercise_class"](pathlib.Path(sys.argv[4]), sys.argv[5])
"""
    result = subprocess.run(["rtk", "proxy", sys.executable, "-c", script,
        str(Path(__file__).resolve()), str(binary), hashlib.sha256(binary.read_bytes()).hexdigest(),
        str(tmp_path), behavior], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "class protocol checked" in result.stdout
