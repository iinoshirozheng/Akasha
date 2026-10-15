from akasha.common.config import CollectionConfig
from akasha.index.hnsw import HnswIndex
from std.python import Python
from std.sys.arg import argv


def main() raises:
    var args = argv()
    var pathlib = Python.import_module("pathlib")
    var json = Python.import_module("json")
    var fixtures = json.loads(pathlib.Path(args[1]).read_text())
    for case_id in range(len(fixtures)):
        var fixture = fixtures[case_id]
        var config = CollectionConfig.defaults(len(fixture["vectors"][0]))
        config.m = Int(py=fixture["m"])
        config.m0 = Int(py=fixture["m0"])
        config.ef_construction = Int(py=fixture["ef"])
        var index = HnswIndex(config)
        for id in range(len(fixture["vectors"])):
            var values = List[Float32]()
            for component in range(config.dimension):
                values.append(Float32(py=fixture["vectors"][id][component]))
            index._insert_prepared[-1](id, values^, Int(py=fixture["levels"][id]), False, id > 0)
        for ordinal in range(index.point_count()):
            var slot = UInt32(ordinal)
            for level in range(index.graph.level(slot) + 1):
                var line = String("case ", case_id, " slot ", ordinal, " level ", level, " links")
                for edge in range(index.graph.neighbor_count(slot, level)):
                    line += String(" ", index.graph.neighbor_at(slot, level, edge))
                print(line)
