from akasha.document import DocumentField, PayloadValue
from akasha.storage.memtable import MemTable
from std.time import perf_counter_ns


def _run(count: Int, scrambled: Bool) raises:
    var table = MemTable(64)
    var start = perf_counter_ns()
    for index in range(count):
        var id = (index * 7919) % count if scrambled else count - index - 1
        var vector = List[Float32](capacity=64)
        for column in range(64):
            vector.append(Float32(id + column))
        var fields = List[DocumentField]()
        fields.append(DocumentField("payload", PayloadValue.string("x" * 256)))
        table.apply_document_upsert(id, UInt64(index + 1), vector^, fields^)
    var ingest = perf_counter_ns() - start
    start = perf_counter_ns()
    var checksum = 0
    for id in range(count):
        var record = table.get(id)
        checksum += record.value().id
    var lookup = perf_counter_ns() - start
    start = perf_counter_ns()
    var entries = table.live_entries()
    var materialize = perf_counter_ns() - start
    print(
        "memtable",
        count,
        "scrambled",
        scrambled,
        "ingest_ns",
        ingest,
        "lookup_ns",
        lookup,
        "owned_sorted_ns",
        materialize,
        "count",
        len(entries),
        "checksum",
        checksum,
    )


def main() raises:
    var counts: List[Int] = [4_096, 16_384, 65_536]
    for count in counts:
        _run(count, False)
        _run(count, True)
