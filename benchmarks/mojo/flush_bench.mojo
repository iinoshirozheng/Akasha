"""Public incremental flush timing; prepare the collection in a separate run."""

from akasha import BatchMutation, DocumentField, PayloadValue, PersistentCollection
from std.sys.arg import argv
from std.time import perf_counter_ns


def _mutations(
    first: Int, count: Int, dimension: Int, payload_bytes: Int, updated: Bool
) raises -> List[BatchMutation]:
    var mutations = List[BatchMutation](capacity=count)
    for id in range(first, first + count):
        var vector = List[Float32](capacity=dimension)
        for column in range(dimension):
            vector.append(
                Float32((id * 17 + column * 13) % 101 - 50)
                + Float32(0.5 if updated else 0.25)
            )
        var fields = List[DocumentField]()
        fields.append(
            DocumentField(
                "payload",
                PayloadValue.string(("y" if updated else "x") * payload_bytes),
            )
        )
        mutations.append(BatchMutation.document_upsert(id, vector^, fields^))
    return mutations^


def _populate(
    mut collection: PersistentCollection,
    count: Int,
    dimension: Int,
    payload_bytes: Int,
) raises:
    for first in range(0, count, 1024):
        var mutations = _mutations(
            first, min(1024, count - first), dimension, payload_bytes, False
        )
        _ = collection.apply_batch(mutations)


def main() raises:
    var args = argv()
    if len(args) != 8:
        raise Error(
            "usage: flush-bench prepare|flush PATH POINTS DIMENSION DELTA PAYLOAD_BYTES TRACE"
        )
    var count = Int(args[3])
    var dimension = Int(args[4])
    var delta = Int(args[5])
    var payload_bytes = Int(args[6])
    if count <= 0 or dimension <= 0 or delta <= 0 or delta > count or payload_bytes < 0:
        raise Error("invalid flush benchmark dimensions")
    if args[1] != "prepare" and args[1] != "flush":
        raise Error("expected prepare or flush")
    # Two checkpoints do not reach the L0 compaction threshold. Disable the
    # optional worker explicitly to avoid background activity in measurements.
    var collection = PersistentCollection.open(
        args[2], dimension, maintenance_library_path="/akasha-bench-no-worker.so"
    )
    if args[1] == "prepare":
        _populate(collection, count, dimension, payload_bytes)
        collection.flush()
        collection.close()
        return
    if collection.last_sequence() != UInt64(count):
        raise Error("flush benchmark needs an untouched prepared fixture")
    var mutations = _mutations(0, delta, dimension, payload_bytes, True)
    _ = collection.apply_batch(mutations)
    if args[7] == "trace":
        print("flush_begin")
    var start = perf_counter_ns()
    collection.flush()
    var elapsed = perf_counter_ns() - start
    if args[7] == "trace":
        print("flush_end")
    if collection.last_sequence() != UInt64(count + delta):
        raise Error("flush benchmark sequence mismatch")
    var record = collection.get(0)
    if (
        record.value().vector[0] != Float32(-49.5)
        or record.value().get_field("payload").value().as_string()
        != "y" * payload_bytes
    ):
        raise Error("flush benchmark updated record mismatch")
    print(
        "flush points=" + String(count)
        + " dimension=" + String(dimension)
        + " delta=" + String(delta)
        + " payload_bytes=" + String(payload_bytes)
        + " flush_ns=" + String(elapsed)
    )
    collection.close()
