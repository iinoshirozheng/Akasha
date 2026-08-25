from akasha import DatabaseConfig, FlatIndex


def main() raises:
    var config = DatabaseConfig("local", 1)
    var index = FlatIndex(2)
    index.add(10, [1.0, 0.0])
    index.add(20, [0.0, 1.0])
    var query: List[Float32] = [1.0, 0.0]
    var results = index.search_cosine(query, 1)

    print(
        "AkashaDB",
        config.name,
        "format",
        config.format_version,
        "nearest point",
        results[0].id,
    )
