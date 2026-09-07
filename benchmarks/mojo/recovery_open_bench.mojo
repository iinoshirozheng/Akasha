from akasha import BatchMutation, PersistentCollection
from akasha.common.config import CollectionConfig
from std.sys.arg import argv
from std.time import perf_counter_ns


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("usage: recovery-bench prepare|open DIRECTORY")
    var config = CollectionConfig.defaults(64)
    config.delta_max_points = 8192
    if args[1] == "prepare":
        var collection = PersistentCollection.open_with_config(args[2], config)
        var updates = List[BatchMutation]()
        for id in range(4096):
            var values = List[Float32]()
            for column in range(64):
                values.append(Float32((id * 13 + column * 7) % 29 - 14) / 16.0)
            updates.append(BatchMutation.upsert(4096 - id, values^))
        _ = collection.apply_batch(updates)
        collection.rebuild_hnsw()
        collection.flush()
        updates = List[BatchMutation]()
        for id in range(1, 410):
            var values = List[Float32](length=64, fill=Float32(id) / 4096.0)
            updates.append(BatchMutation.upsert(id, values^))
        _ = collection.apply_batch(updates)
        collection.close()
        return
    for sample in range(7):
        var start = perf_counter_ns()
        var collection = PersistentCollection.open_with_config(args[2], config)
        var elapsed = perf_counter_ns() - start
        if collection.last_sequence() != UInt64(4505):
            raise Error("recovery benchmark lost WAL tail")
        print(
            "recovery sample="
            + String(sample)
            + " public_open_ns="
            + String(elapsed)
            + " sequence="
            + String(collection.last_sequence())
        )
        collection.close()
