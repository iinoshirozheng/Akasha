from akasha import CollectionConfig, PersistentCollection, RecommendationExample, ReadSnapshot, FilterExpression
from akasha.document.vector_value import VectorValue
from akasha.query.query_plan import QueryNode, plan_query
from akasha.query.mmr import MmrOptions
from akasha.query.universal import query_generation
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite


def test_query_rescores_union_and_applies_root_offset() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-query-"))
    var db = PersistentCollection.open(path, 2, maintenance_library_path="")
    db.upsert(1, [1, 0])
    db.upsert(2, [0, 1])
    db.upsert(3, [3, 3])
    var root = db.snapshot()._acquire()
    var nodes: List[QueryNode] = [
        QueryNode("nearest", target=Optional(RecommendationExample.raw(VectorValue.dense[DType.float32]([1, 0]))), limit=1),
        QueryNode("nearest", target=Optional(RecommendationExample.raw(VectorValue.dense[DType.float32]([0, 1]))), limit=1),
        QueryNode("nearest", target=Optional(RecommendationExample.raw(VectorValue.dense[DType.float32]([0, 1]))), children=[0, 1], limit=1, offset=1),
    ]
    var hits = query_generation(root[], [], nodes)
    assert_equal(len(hits.results), 1)
    assert_equal(hits.results[0].id, 1)
    db.close()
    Python.import_module("shutil").rmtree(path)


def test_query_rejects_shared_and_unreachable_nodes() raises:
    var orphan: List[QueryNode] = [QueryNode("scroll"), QueryNode("scroll")]
    with assert_raises():
        _ = plan_query(orphan)
    var shared: List[QueryNode] = [QueryNode("scroll"), QueryNode("rrf", children=[0, 0])]
    with assert_raises():
        _ = plan_query(shared)


def test_planning_matches_unedited_qdrant_planner() raises:
    var samples = Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-query-plan/plans.json").read())["cases"]
    for sample_index in range(len(samples)):
        var sample = samples[sample_index]
        var raw = sample["nodes"]
        var nodes = List[QueryNode]()
        for i in range(len(raw)):
            var value = raw[i]
            var kind = Int(py=value["kind"])
            var names: List[String] = ["nearest", "rrf", "dbsf", "nearest", "scroll"]
            var target = Optional[RecommendationExample]()
            var mmr = Optional[MmrOptions]()
            if kind == 0 or kind == 3:
                target = Optional(RecommendationExample.raw(VectorValue.dense[DType.float32]([1, 0])))
            if kind == 3:
                mmr = Optional(MmrOptions(0.5, Int(py=value["candidates"])))
            var children = List[Int]()
            for j in range(len(value["children"])):
                children.append(Int(py=value["children"][j]))
            var expression = Optional[FilterExpression]()
            if Bool(py=value["filter"]):
                expression = Optional(FilterExpression.all([]))
            nodes.append(QueryNode(names[kind], target=target^, mmr=mmr, children=children^,
                filter=expression^, limit=Int(py=value["limit"]), offset=Int(py=value["offset"])))
        if Bool(py=sample.__contains__("error")):
            with assert_raises():
                _ = plan_query(nodes)
            continue
        var steps = plan_query(nodes)
        var expected = sample["expected"]
        for j in range(len(expected)):
            var row = expected[j]
            var index = Int(py=row["id"])
            ref node = nodes[index]
            ref step = steps[index]
            var retrieval = 0
            if len(node.children) == 0 or node.kind == "nearest":
                if not step.apply_mmr or index == len(nodes) - 1:
                    retrieval = step.fetch_limit if node.mmr else step.limit
            assert_equal(retrieval, Int(py=row["retrieval"]))
            assert_equal(step.apply_mmr, Bool(py=row["mmr"]))
            assert_equal(step.nearest_rescore, Bool(py=row["nearest"]))
            if len(node.children) == 0:
                var filters = List[Int]()
                var parent = index
                while parent >= 0:
                    if nodes[parent].filter:
                        filters.append(parent)
                    parent = steps[parent].parent
                assert_equal(len(filters), len(row["filters"]))
                for k in range(len(filters)):
                    assert_equal(filters[len(filters) - 1 - k], Int(py=row["filters"][k]))


def test_query_retains_snapshot_and_external_lookup_after_close() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-query-roots-"))
    var db = PersistentCollection.open(path + "/target", 2, maintenance_library_path="")
    var source = PersistentCollection.open(path + "/source", 2, maintenance_library_path="")
    db.upsert(1, [1, 0])
    db.upsert(2, [0, 1])
    source.upsert(1, [1, 0])
    var view = db.snapshot()
    var lookups: List[ReadSnapshot] = [source.snapshot()]
    db.upsert(1, [10, 10])
    source.upsert(1, [0, 1])
    db.close()
    source.close()
    var nodes: List[QueryNode] = [QueryNode("nearest", target=Optional(RecommendationExample.point(1)), lookup_index=0, limit=1)]
    var hits = view.query(nodes, lookups)
    assert_equal(hits[0].id, 1)
    assert_equal(hits[0].score, Float64(0))
    lookups[0].close()
    with assert_raises():
        _ = view.query(nodes, lookups)
    view.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
