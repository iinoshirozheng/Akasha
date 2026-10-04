"""Returned Python containers and scalar elements have no hidden native owners."""
import gc
import sys
import weakref
import pytest
from akashadb import CollectionConfig, Collection, PointMutation, PayloadField, SparseElement, VectorField


class Marker:
    pass


@pytest.fixture
def db(tmp_path):
    collection = Collection(tmp_path, 2, vectors={
        "v": VectorField(2, metric="dot", hnsw=CollectionConfig.defaults(2, ann_metric="dot")),
        "multi": VectorField(2, kind="multivector", metric="dot"),
    })
    collection.apply_point_batch([PointMutation.upsert(1001, vector=[2.5, 3.5],
        vectors={"v": [2.5, 3.5], "multi": [[2.5, 3.5], [4.5, 5.5]]},
        sparse=[SparseElement(4001, 2.5)], fields=[PayloadField("tag", "string", "value")])])
    yield collection
    collection.close()


def output(db, route):
    native = db._kernel
    options = dict(mode="exact", ivf=None, cancelled=False, deadline_ns=0,
                   max_candidates=100, ef_search=-1, rerank_k=0, filter=None)
    if route == "dense": return native.search_dot([1., 0.], 1)
    if route == "dense-approx": return native.search_approx("dot", [1., 0.], 1, 16)
    if route == "named": return native.search_field("v", [1., 0.], 1, options)
    if route == "named-approx": return native.search_field("v", [1., 0.], 1, dict(options, mode="approx", ef_search=16))
    if route == "batch": return native.search_batch("dot", [[1., 0.]], 1, 1)
    if route == "schema": return native.vector_fields()
    if route == "document": return native.get(1001)
    if route == "projected": return native.get_projected(1001, dict(fields=[], include_vector=True, all_fields=True))
    if route == "point": return native.get_point(1001)
    if route == "export-points": return native.export_points()
    if route == "export-records": return native.export_records()
    raise AssertionError(route)


@pytest.mark.parametrize("route,path", [
    ("dense", [0]), ("dense-approx", [0]), ("named", [0]), ("named-approx", [0]),
    ("batch", [0]), ("batch", [0, 0]), ("schema", [0]),
    ("document", ["fields", 0]), ("projected", ["fields", 0]),
    ("point", ["fields", 0]), ("point", ["sparse", 0]),
    ("point", ["vectors", "multi", 0]),
    ("export-points", ["schema", 0]), ("export-points", ["points", 0]),
    ("export-records", [0]), ("export-records", [0, "sparse", 0]),
])
def test_returned_containers_have_no_hidden_owner(db, route, path):
    refs = []
    for _ in range(4):
        result = output(db, route)
        node = result
        for key in path: node = node[key]
        marker = Marker()
        refs.append(weakref.ref(marker))
        if isinstance(node, dict): node["marker"] = marker
        else: node.append(marker)
        del marker, node, result
    gc.collect()
    assert all(ref() is None for ref in refs), "native output kept an unreachable container"
    # Mutating a returned container must not mutate retained database state.
    assert db.get_point(1001).vectors["multi"] == [[2.5, 3.5], [4.5, 5.5]]


@pytest.mark.parametrize("route,path", [
    ("document", ["vector"]), ("projected", ["vector"]),
    ("point", ["vector"]), ("point", ["vectors", "v"]),
    ("point", ["vectors", "multi", 0]),
])
def test_float_outputs_have_only_their_container_owner(db, route, path):
    # CPython is the supported Mojo interpreter. Floats are freshly boxed,
    # unlike cached small ints/booleans; no extra native reference may remain.
    result = output(db, route)
    for key in path: result = result[key]
    assert result == [2.5, 3.5]
    # Evaluate outside assert so pytest's expression rewriting cannot hold
    # the indexed float in a temporary while getrefcount is running.
    first_count = sys.getrefcount(result[0])
    second_count = sys.getrefcount(result[1])
    assert first_count == second_count == 2


def test_empty_queries_keep_shapes(db):
    db.delete(1001)
    assert output(db, "dense") == []
    assert output(db, "named") == []
    assert output(db, "batch") == [[]]
    assert output(db, "export-points")["points"] == []


@pytest.mark.parametrize("fail", [False, True])
def test_binary_constructor_does_not_keep_its_temporary_list(tmp_path, fail):
    import builtins
    db = Collection(tmp_path, 2, vectors={"bits": VectorField(8, kind="binary", dtype="binary", metric="hamming")})
    db.apply_point_batch([PointMutation.upsert(1, vectors={"bits": b"\x12"})])
    refs = []
    original = builtins.bytes
    def constructor(values):
        result = original(values)
        marker = Marker()
        refs.append(weakref.ref(marker))
        values.append(marker)
        if fail: raise ValueError("binary constructor sentinel")
        return result
    failure = None
    builtins.bytes = constructor
    try:
        result = db._kernel.get_point(1)
    except Exception as error:
        failure = str(error)
    finally:
        builtins.bytes = original
    if fail:
        assert failure and "binary constructor sentinel" in failure
    else:
        assert failure is None, failure
        assert result["vectors"]["bits"] == b"\x12"
    gc.collect()
    assert refs and all(ref() is None for ref in refs)
    assert db.get_point(1).vectors["bits"] == b"\x12"
    db.close()
