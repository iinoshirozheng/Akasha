"""Fingerprint and public sparse-update costs; build unchanged before/after."""

from akasha import (
    DocumentField,
    PayloadValue,
    PersistentCollection,
    SparseElement,
)
from akasha.storage.index_cache import authoritative_index_checksum
from akasha.storage.memtable import MemTable
from std.sys.arg import argv
from std.time import perf_counter_ns


def _vector(dimension: Int) -> List[Float32]:
    var values = List[Float32](capacity=dimension)
    for column in range(dimension):
        values.append(Float32(column % 7) + 0.5)
    return values^


def _fields(width: Int) raises -> List[DocumentField]:
    var fields: List[DocumentField] = [
        DocumentField("body", PayloadValue.string("x" * width)),
    ]
    return fields^


def main() raises:
    var args = argv()
    if len(args) != 8:
        raise Error(
            "usage: readonly-copy-bench fingerprint|sparse PATH POINTS DIM"
            " PAYLOAD_BYTES REPETITIONS trace|quiet"
        )
    var count = Int(args[3])
    var dimension = Int(args[4])
    var width = Int(args[5])
    var repetitions = Int(args[6])
    var trace = args[7] == "trace"
    if count <= 0 or dimension <= 0 or width < 0 or repetitions <= 0:
        raise Error("invalid benchmark dimensions")
    var elapsed: Int
    var checksum: UInt32
    if args[1] == "fingerprint":
        var table = MemTable(dimension)
        for i in range(count):
            table.apply_document_upsert(
                i - count // 2,
                UInt64(i + 1),
                _vector(dimension),
                _fields(width),
            )
        checksum = authoritative_index_checksum(table)
        if trace:
            print("measure_begin")
        var started = perf_counter_ns()
        for _ in range(repetitions):
            if authoritative_index_checksum(table) != checksum:
                raise Error("fingerprint is not repeatable")
        elapsed = perf_counter_ns() - started
        if trace:
            print("measure_end")
        if table.live_count() != count or table.last_sequence != UInt64(count):
            raise Error("fingerprint mutated authority")
    elif args[1] == "sparse":
        if count != 1:
            raise Error("sparse workload requires one stable dense point")
        var collection = PersistentCollection.open(
            args[2],
            dimension,
            maintenance_library_path="/akasha-bench-no-worker",
        )
        collection.upsert_document(-7, _vector(dimension), _fields(width))
        var sequence = collection.last_sequence()
        var elements: List[SparseElement] = [SparseElement(9, 2.0)]
        if trace:
            print("measure_begin")
        var started = perf_counter_ns()
        for _ in range(repetitions):
            collection.upsert_sparse(-7, elements)
        elapsed = perf_counter_ns() - started
        if trace:
            print("measure_end")
        if collection.last_sequence() != sequence + UInt64(repetitions):
            raise Error("sparse update sequence mismatch")
        var record = collection.get(-7)
        if (
            record.value().vector[0] != 0.5
            or record.value().get_field("body").value().as_string()
            != "x" * width
        ):
            raise Error("sparse update changed dense document")
        var hits = collection.search_sparse_dot([SparseElement(9, 1.0)], 1)
        if len(hits) != 1 or hits[0].id != -7 or hits[0].score != 2.0:
            raise Error("sparse update result mismatch")
        checksum = UInt32(collection.last_sequence())
        collection.close()
    else:
        raise Error("unknown benchmark mode")
    print(
        "mode="
        + args[1]
        + " points="
        + String(count)
        + " dimension="
        + String(dimension)
        + " payload_bytes="
        + String(width)
        + " repetitions="
        + String(repetitions)
        + " elapsed_ns="
        + String(elapsed)
        + " checksum="
        + String(checksum)
    )
