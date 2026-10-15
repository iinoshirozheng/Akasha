from akasha.index.quantization import Sq8Index
from akasha.index.flat import SearchResult
from std.python import Python
from std.sys.arg import argv


def main() raises:
    var args = argv()
    var pathlib = Python.import_module("pathlib")
    var json = Python.import_module("json")
    var fixtures = json.loads(pathlib.Path(args[1]).read_text())
    for fixture_id in range(len(fixtures)):
        var fixture = fixtures[fixture_id]
        var vectors = List[List[Float32]]()
        var ids = List[Int]()
        for row in range(len(fixture["vectors"])):
            var values = List[Float32]()
            for col in range(len(fixture["vectors"][row])):
                values.append(Float32(py=fixture["vectors"][row][col]))
            vectors.append(values^)
            ids.append(row)
        var metric = Int(py=fixture["metric"])
        var index = Sq8Index.build(ids, vectors, cosine=metric == 2)
        for query_id in range(len(fixture["queries"])):
            var query = List[Float32]()
            for col in range(len(fixture["queries"][query_id])):
                query.append(Float32(py=fixture["queries"][query_id][col]))
            var hits: List[SearchResult]
            if metric == 0:
                hits = index.search_dot(query, len(ids))
            elif metric == 1:
                hits = index.search_l2(query, len(ids))
            else:
                hits = index.search_cosine(query, len(ids))
            for hit in hits:
                print(fixture_id, query_id, hit.id, hit.score)
