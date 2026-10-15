"""Run fixed traversal fixtures; timings are deliberately not measured."""

from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswSearchAdmission
from akasha.index.hnsw_entries import HnswEntry
from akasha.index.hnsw_stats import HnswSearchStats
from qdrant_search_reference import search
from std.python import Python
from std.sys.arg import argv


def main() raises:
    var args = argv()
    if len(args) != 2:
        raise Error("usage: qdrant_search_differential.mojo fixtures.json")
    var pathlib = Python.import_module("pathlib")
    var json = Python.import_module("json")
    var fixtures = json.loads(pathlib.Path(args[1]).read_text())
    for case_id in range(len(fixtures)):
        var fixture = fixtures[case_id]
        var config = CollectionConfig.defaults(1)
        config.ann_metric = MetricKind.l2()
        config.m = Int(py=fixture["m"])
        config.m0 = Int(py=fixture["m0"])
        var index = HnswIndex(config)
        var flags = List[Bool]()
        for i in range(len(fixture["values"])):
            var vector: List[Float32] = [Float32(py=fixture["values"][i])]
            _ = index.graph.append(i, vector^, Int(py=fixture["levels"][i]))
            flags.append(Bool(py=fixture["allowed"][i]))
        for i in range(len(fixture["values"])):
            for level in range(Int(py=fixture["levels"][i]) + 1):
                var links = List[UInt32]()
                for j in range(len(fixture["links"][i][level])):
                    links.append(UInt32(Int(py=fixture["links"][i][level][j])))
                index.graph.set_neighbors(UInt32(i), level, links)
        var primary = List[HnswEntry]()
        for i in range(len(fixture["primary"])):
            primary.append(HnswEntry(UInt32(Int(py=fixture["primary"][i][0])), Int(py=fixture["primary"][i][1])))
        var extra = List[HnswEntry]()
        for i in range(len(fixture["extra"])):
            extra.append(HnswEntry(UInt32(Int(py=fixture["extra"][i][0])), Int(py=fixture["extra"][i][1])))
        var allowed = HnswSearchAdmission(flags^)
        var query: List[Float32] = [0.0]
        var stats = HnswSearchStats()
        var result = search(
            index.graph,
            index.metric,
            query,
            primary,
            extra,
            Int(py=fixture["k"]),
            Int(py=fixture["ef"]),
            allowed,
            index.scratch,
            stats,
        )
        var line = String(
            "case ", case_id, " distances ", stats.distance_evaluations, " ids"
        )
        for item in result:
            line += String(" ", item.slot)
        print(line)
