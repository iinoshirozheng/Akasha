from akasha.index.hnsw_connectivity import HnswBuildRandom, subgraph_connectivity
from akasha.index.hnsw_entries import HnswEntry, HnswEntryPoints
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_storage import HnswStorage
from std.memory import bitcast
from std.python import Python
from std.sys.arg import argv


def main() raises:
    var args = argv()
    var pathlib = Python.import_module("pathlib")
    var json = Python.import_module("json")
    var fixtures = json.loads(pathlib.Path(args[1]).read_text())
    for case_id in range(len(fixtures)):
        var fixture = fixtures[case_id]
        var graph = HnswStorage(1, 4, 8)
        var rows = List[List[UInt32]]()
        for i in range(len(fixture["levels"])):
            _ = graph.append(i, [Float32(i)], Int(py=fixture["levels"][i]))
            for layer in range(len(fixture["links"][i])):
                var row = List[UInt32]()
                for edge in range(len(fixture["links"][i][layer])):
                    row.append(UInt32(Int(py=fixture["links"][i][layer][edge])))
                rows.append(row^)
        var entries = HnswEntryPoints()
        for i in range(len(fixture["primary"])):
            var slot = UInt32(Int(py=fixture["primary"][i]))
            entries.primary.append(HnswEntry(slot, 0))
        for i in range(len(fixture["extra"])):
            var slot = UInt32(Int(py=fixture["extra"][i]))
            entries.extra.offer(HnswHeapItem(slot, graph.id_at(slot), -Float32(graph.level(slot))), 80)
        var points = List[UInt32]()
        for i in range(len(fixture["points"])):
            points.append(UInt32(Int(py=fixture["points"][i])))
        var rng = HnswBuildRandom(UInt64(Int(py=fixture["seed"])))
        var result = subgraph_connectivity(graph, entries, rows, points, Float32(py=fixture["q"]), rng)
        print(String("case ", case_id, " bits ", bitcast[DType.uint32](result), " state ", rng.state))
