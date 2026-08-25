from akasha import PersistentCollection


def main() raises:
    var path = String("/tmp/akasha-persistent-example")
    var collection = PersistentCollection.open(path, 3)
    collection.upsert(101, [1.0, 0.0, 0.0])
    collection.upsert(202, [0.8, 0.2, 0.0])
    collection.upsert(303, [0.0, 1.0, 0.0])
    collection.flush()

    var reopened = PersistentCollection.open(path, 3)
    var query: List[Float32] = [1.0, 0.0, 0.0]
    var results = reopened.search_cosine(query, 2)

    print(
        "reopened sequence",
        reopened.last_sequence(),
        "nearest IDs",
        results[0].id,
        results[1].id,
    )
