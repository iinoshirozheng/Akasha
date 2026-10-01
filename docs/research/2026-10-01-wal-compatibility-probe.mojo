"""Run the same malformed/valid WAL corpus against before/after sources."""

from akasha.document.codec import encode_payload
from akasha.storage.checksum import BinaryReader, BinaryWriter, crc32
from akasha.storage.filesystem import read_file_bytes
from akasha.storage.wal import decode_wal_bytes, preflight_wal, WalRecord
from std.sys.arg import argv


def _digest(records: List[WalRecord]) raises -> UInt32:
    var writer = BinaryWriter()
    for i in range(len(records)):
        ref record = records[i]
        writer.write_u64(record.sequence)
        writer.write_i64(Int64(record.id))
        writer.write_u8(UInt8(record.is_delete))
        writer.write_u32(UInt32(len(record.values)))
        for value in record.values:
            writer.write_f32(value)
        var payload = encode_payload(record.fields)
        writer.write_u32(UInt32(len(payload)))
        writer.write_bytes(payload)
    var bytes = writer.take_bytes()
    return crc32(bytes)


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("usage: wal-compatibility-probe CORPUS SCRATCH_FILE")
    var corpus = BinaryReader(read_file_bytes(args[1]))
    var count = Int(corpus.read_u32())
    for case_index in range(count):
        var size = Int(corpus.read_u32())
        var bytes = corpus.read_bytes(size)
        with open(args[2], "w") as output:
            output.write_all(Span(bytes))
        var decoded_count = -1
        var decoded_digest = UInt32(0)
        try:
            var records = decode_wal_bytes(bytes^, 1)
            decoded_digest = _digest(records)
            decoded_count = len(records)
        except:
            pass
        var streamed_count = -1
        var streamed_digest = UInt32(0)
        var accepted = -1
        try:
            var replay = preflight_wal(args[2], 1)
            streamed_digest = _digest(replay.records)
            streamed_count = len(replay.records)
            accepted = replay.valid_length
        except:
            pass
        print(
            case_index,
            decoded_count,
            decoded_digest,
            streamed_count,
            streamed_digest,
            accepted,
        )
    if corpus.remaining() != 0:
        raise Error("unexpected corpus suffix")
