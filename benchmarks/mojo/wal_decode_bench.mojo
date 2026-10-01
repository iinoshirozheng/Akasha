"""Measure owned replay and collection recovery in fresh processes.

Prepare fixtures separately; each record replaces one of a fixed set of IDs.
History grows without increasing the final authority size. No benchmark API
depends on the streaming implementation, so the same source builds before/after.
"""

from akasha import DocumentField, PayloadValue, PersistentCollection
from akasha.storage.filesystem import ensure_directory, sync_file
from akasha.storage.wal import (
    encode_delete,
    encode_document_upsert,
    preflight_wal,
)
from std.sys.arg import argv
from std.time import perf_counter_ns


def _vector(sequence: Int, dimension: Int) -> List[Float32]:
    var values = List[Float32](capacity=dimension)
    for column in range(dimension):
        values.append(Float32(sequence) + Float32(column) * 0.25)
    return values^


def _payload(sequence: Int, width: Int) -> String:
    return "x" * width + String(sequence)


def _prepare(
    path: String, count: Int, live: Int, dimension: Int, width: Int
) raises:
    ensure_directory(path)
    with open(path + "/wal.bin", "w") as file:
        for sequence in range(1, count + 1):
            var id = (sequence - 1) % live
            var bytes: List[UInt8]
            if sequence % 17 == 0:
                bytes = encode_delete(UInt64(sequence), id, dimension)
            else:
                var fields: List[DocumentField] = [
                    DocumentField(
                        "payload",
                        PayloadValue.string(_payload(sequence, width)),
                    ),
                ]
                var values = _vector(sequence, dimension)
                bytes = encode_document_upsert(
                    UInt64(sequence), id, dimension, values, fields
                )
            file.write_all(Span(bytes))
        sync_file(file)


def main() raises:
    var args = argv()
    if len(args) != 7:
        raise Error(
            "usage: wal-decode-bench prepare|replay|open PATH RECORDS LIVE"
            " DIMENSION PAYLOAD_BYTES"
        )
    var count = Int(args[3])
    var live = Int(args[4])
    var dimension = Int(args[5])
    var width = Int(args[6])
    if count < live or live <= 0 or dimension <= 0 or width < 0:
        raise Error("invalid WAL benchmark sizes")
    if args[1] == "prepare":
        _prepare(args[2], count, live, dimension, width)
        return
    var started = perf_counter_ns()
    var elapsed: Int
    var digest = UInt64(0)
    if args[1] == "replay":
        var replay = preflight_wal(args[2] + "/wal.bin", dimension)
        elapsed = perf_counter_ns() - started
        if len(replay.records) != count or replay.needs_repair():
            raise Error("replay lost a record")
        for i in range(count):
            ref record = replay.records[i]
            var sequence = i + 1
            if (
                record.sequence != UInt64(sequence)
                or record.id != i % live
                or record.is_delete != (sequence % 17 == 0)
            ):
                raise Error("replay record identity mismatch")
            if not record.is_delete:
                if (
                    len(record.values) != dimension
                    or record.values[0] != Float32(sequence)
                    or record.values[dimension - 1]
                    != Float32(sequence) + Float32(dimension - 1) * 0.25
                    or record.fields[0].value.as_string()
                    != _payload(sequence, width)
                ):
                    raise Error("replay record content mismatch")
            digest += record.sequence
    elif args[1] == "open":
        var collection = PersistentCollection.open(
            args[2],
            dimension,
            maintenance_library_path="/akasha-bench-no-worker",
        )
        elapsed = perf_counter_ns() - started
        if collection.last_sequence() != UInt64(count):
            raise Error("recovery sequence mismatch")
        for id in range(live):
            var sequence = count - (count - 1 - id) % live
            var record = collection.get(id)
            if sequence % 17 == 0:
                if record:
                    raise Error("recovery resurrected deleted point")
                continue
            if not record:
                raise Error("recovery lost live point")
            ref point = record.value()
            if (
                len(point.vector) != dimension
                or point.vector[0] != Float32(sequence)
                or point.vector[dimension - 1]
                != Float32(sequence) + Float32(dimension - 1) * 0.25
                or point.get_field("payload").value().as_string()
                != _payload(sequence, width)
            ):
                raise Error("recovery latest-state mismatch")
            digest += UInt64(sequence)
        collection.close()
    else:
        raise Error("invalid WAL benchmark mode")
    print(
        "mode="
        + args[1]
        + " records="
        + String(count)
        + " live="
        + String(live)
        + " dimension="
        + String(dimension)
        + " payload_bytes="
        + String(width)
        + " elapsed_ns="
        + String(elapsed)
        + " digest="
        + String(digest)
    )
