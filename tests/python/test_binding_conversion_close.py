"""Re-entry during native argument conversion must not invalidate a borrow."""

import hashlib
from pathlib import Path
import subprocess
import sys

import pytest

from akashadb import _kernel


CASES = [
    "upsert_vector", "upsert_id", "document_fields", "batch", "point_batch",
    "sparse_upsert", "delete", "get", "projection", "backup",
    "sparse_query", "sparse_where", "controlled_options", "controlled_snapshot",
    "field_options", "field_vector", "field_late", "fields_options",
    "fields_vector", "fields_late", "arrow_early", "arrow_payload",
    "point_arrow_early", "point_arrow_payload", "scanner_options",
    "scanner_columns", "scanner_cancel", "scanner_export",
]
CASES += [f"{route}_{metric}" for route in (
    "exact_vector", "exact_count", "batch_query", "batch_where", "hybrid", "hybrid_where"
) for metric in ("dot", "l2", "cosine")]


def _exercise_close(path, case):
    import pyarrow as pa
    from akashadb import Collection, PointMutation, VectorField
    from akashadb.arrow import _validated_descriptor, scan_record_batches
    from akashadb.arrow_points import point_descriptor

    named = case.startswith(("point_", "field"))
    fields = {"v": VectorField(2)} if named else None
    collection = Collection(path / "database", 2, vectors=fields)
    if named:
        collection.apply_point_batch([PointMutation.upsert(1, vector=[1., 2.], vectors={"v": [1., 2.]})])
    else:
        collection.upsert(1, [1., 2.])
    before_sequence = collection.last_sequence
    native = collection._kernel
    closed = False
    scanner = None

    def close():
        nonlocal closed
        closed = True
        if case in ("scanner_cancel", "scanner_export"):
            scanner.close()
        else:
            collection.close()

    class ClosingList(list):
        def __iter__(self):
            close()
            return super().__iter__()

    class ClosingDict(dict):
        def __init__(self, values, key):
            super().__init__(values)
            self.key = key

        def __getitem__(self, key):
            if key == self.key:
                close()
            return super().__getitem__(key)

    class ClosingScalar:
        def __int__(self):
            close()
            return 1

        __index__ = __int__

        def __bool__(self):
            close()
            return False

        def __str__(self):
            close()
            return str(path / "backup")

        def as_py(self):
            close()
            return 1

    expression = dict(kind="condition", name="x", operator="eq", type="int", value=1)
    sparse = [dict(term_id=1, weight=1.)]
    options = dict(k=1, fetch_k=1, rank_constant=60, filter=expression)
    field_options = dict(mode="exact", ivf=None, cancelled=False,
        deadline_ns=0, max_candidates=100, ef_search=-1, rerank_k=0, filter=None)
    fusion_options = dict(field_options, k=1, fetch_k=1, rank_constant=60, rerank=None)
    query = dict(name="v", vector=[1., 2.], mode="exact", ef_search=-1, rerank_k=0, ivf=None)
    controlled_options = dict(cancelled=False, max_candidates=100, deadline_ns=0)
    operation = None
    if case == "upsert_vector":
        operation = lambda: native.upsert(2, ClosingList([2., 3.]))
    elif case == "upsert_id":
        operation = lambda: native.upsert(ClosingScalar(), [2., 3.])
    elif case == "document_fields":
        operation = lambda: native.upsert_document(2, [2., 3.], ClosingList([]))
    elif case == "batch":
        operation = lambda: native.apply_batch(ClosingList([dict(operation="delete", id=1)]))
    elif case == "point_batch":
        operation = lambda: native.apply_point_batch(ClosingList([dict(operation="delete", id=1, updates=[], fields=None)]))
    elif case == "sparse_upsert":
        operation = lambda: native.upsert_sparse(1, ClosingList(sparse))
    elif case == "delete":
        operation = lambda: native.delete(ClosingScalar())
    elif case == "get":
        operation = lambda: native.get(ClosingScalar())
    elif case == "projection":
        operation = lambda: native.get_projected(1, dict(fields=ClosingList([]), include_vector=True, all_fields=True))
    elif case == "backup":
        operation = lambda: native.backup_to(ClosingScalar())
    elif case == "sparse_query":
        operation = lambda: native.search_sparse(ClosingList(sparse), 1)
    elif case == "sparse_where":
        operation = lambda: native.search_sparse_where(sparse, ClosingDict(options, "k"))
    elif case == "controlled_options":
        operation = lambda: native.search_controlled("dot", [1., 2.], 1, ClosingDict(controlled_options, "deadline_ns"))
    elif case == "controlled_snapshot":
        operation = lambda: native.search_controlled("dot", ClosingList([1., 2.]), 1, controlled_options)
    elif case.startswith("field_"):
        opts = ClosingDict(field_options, "mode" if case == "field_options" else "rerank_k") if case != "field_vector" else field_options
        vector = ClosingList([1., 2.]) if case == "field_vector" else [1., 2.]
        operation = lambda: native.search_field("v", vector, 1, opts)
    elif case.startswith("fields_"):
        opts = ClosingDict(fusion_options, "cancelled" if case == "fields_options" else "fetch_k") if case != "fields_vector" else fusion_options
        queries = ClosingList([query]) if case == "fields_vector" else [query]
        operation = lambda: native.search_fields(queries, opts)
    elif "arrow" in case:
        batch = pa.record_batch([pa.array([2], type=pa.int64()), pa.array([[2., 3.]], type=pa.list_(pa.float32(), 2))], names=["id", "vector"])
        descriptor = point_descriptor(collection, batch) if named else _validated_descriptor(collection, batch)
        if case.endswith("early"):
            descriptor = ClosingDict(descriptor, "ids")
        else:
            descriptor["payloads"] = [dict(name="x", type="int", values=[ClosingScalar()])]
        method = native.apply_point_arrow_batch if named else native.apply_arrow_batch
        operation = lambda: method(descriptor)
    elif case.startswith("scanner_"):
        if case in ("scanner_cancel", "scanner_export"):
            scanner = scan_record_batches(collection, columns=("id",))._native
            if case == "scanner_cancel":
                operation = lambda: scanner.next_batch(ClosingScalar())
            else:
                record_batch = pa.RecordBatch

                class ClosingImport:
                    @staticmethod
                    def _import_from_c(address, schema):
                        close()
                        return record_batch._import_from_c(address, schema)

                pa.RecordBatch = ClosingImport
                operation = lambda: scanner.next_batch(False)
        else:
            opts = dict(max_candidates=100, deadline_ns=0, max_batch_bytes=1024,
                batch_size=1, columns=[dict(name="id", kind=1, payload_name="")], filter=None)
            if case == "scanner_options":
                opts = ClosingDict(opts, "deadline_ns")
            else:
                opts["columns"] = ClosingList(opts["columns"])
            operation = lambda: native.scanner(opts)
    else:
        route, metric = case.rsplit("_", 1)
        if route == "exact_vector":
            operation = lambda: getattr(native, "search_" + metric)(ClosingList([1., 2.]), 1)
        elif route == "exact_count":
            operation = lambda: getattr(native, "search_" + metric)([1., 2.], ClosingScalar())
        elif route == "batch_query":
            operation = lambda: native.search_batch(metric, ClosingList([[1., 2.]]), 1, 1)
        elif route == "batch_where":
            operation = lambda: native.search_batch_where(metric, [[1., 2.]], [expression], 1, ClosingScalar())
        elif route == "hybrid":
            operation = lambda: native.search_hybrid(metric, ClosingList([1., 2.]), sparse, options)
        elif route == "hybrid_where":
            operation = lambda: native.search_hybrid_where(metric, [1., 2.], sparse, ClosingDict(options, "filter"))
    assert operation is not None, case
    try:
        result = operation()
    except Exception as error:
        assert case not in ("controlled_snapshot", "scanner_export"), str(error)
        expected = "scanner is closed" if case == "scanner_cancel" else "collection is closed"
        assert expected in str(error), str(error)
    else:
        # Controlled reads capture an independent snapshot before converting
        # the query; that snapshot must continue to work after collection close.
        assert case in ("controlled_snapshot", "scanner_export"), "closed operation unexpectedly succeeded"
        if case == "scanner_export":
            assert result["batch"].column(0).to_pylist() == [1]
            assert result["visited_slots"] == 1
        else:
            assert result[0]["id"] == 1
    finally:
        if scanner is not None:
            scanner.close()
        if case == "scanner_export":
            pa.RecordBatch = record_batch
        collection.close()
    assert closed, "conversion callback did not run"
    reopened = Collection(path / "database", 2, vectors=fields)
    assert reopened.last_sequence == before_sequence
    assert reopened._kernel.search_dot([1., 2.], 1)[0]["id"] == 1
    reopened.close()
    print("conversion-close boundary checked")


@pytest.mark.parametrize("case", CASES)
def test_binding_conversion_close(tmp_path, case):
    binary = Path(_kernel.__file__).resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    script = """
import hashlib, pathlib, runpy, sys
from akashadb import _kernel
assert pathlib.Path(_kernel.__file__).resolve() == pathlib.Path(sys.argv[2])
assert hashlib.sha256(pathlib.Path(_kernel.__file__).read_bytes()).hexdigest() == sys.argv[3]
runpy.run_path(sys.argv[1])['_exercise_close'](pathlib.Path(sys.argv[4]), sys.argv[5])
"""
    result = subprocess.run(
        ["rtk", "proxy", sys.executable, "-c", script, str(Path(__file__).resolve()),
         str(binary), digest, str(tmp_path), case],
        capture_output=True, text=True, timeout=15,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "conversion-close boundary checked" in result.stdout
