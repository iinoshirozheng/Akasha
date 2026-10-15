from akasha.index.quantization import PqCodebook
from std.memory import bitcast
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
        for row in range(len(fixture["vectors"])):
            var values = List[Float32]()
            for col in range(len(fixture["vectors"][row])):
                values.append(Float32(py=fixture["vectors"][row][col]))
            vectors.append(values^)
        var codebook = PqCodebook.train(
            vectors, Int(py=fixture["subquantizers"]),
            Int(py=fixture["centroids"]), iterations=Int(py=fixture["iterations"]),
        )
        for sub in range(codebook.subquantizer_count()):
            for centroid in range(codebook.centroid_count()):
                for offset in range(codebook.subdimension()):
                    print(fixture_id, sub, centroid, offset,
                          bitcast[DType.uint32](codebook.value(sub, centroid, offset)))
