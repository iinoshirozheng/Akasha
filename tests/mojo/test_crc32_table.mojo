from akasha.storage.checksum import (
    _crc32_update,
    crc32,
    crc32_range,
    crc32_update,
)
from std.testing import assert_equal, TestSuite


def bitwise(checksum: UInt32, byte: UInt8) -> UInt32:
    var result = checksum ^ UInt32(byte)
    for _ in range(8):
        result = (result >> 1) ^ (
            UInt32(0xEDB88320) if result & 1 else UInt32(0)
        )
    return result


def test_crc_table_preserves_iso_hdlc_vectors_ranges_and_streaming() raises:
    var data = List[UInt8]()
    for byte in [49, 50, 51, 52, 53, 54, 55, 56, 57]:
        data.append(UInt8(byte))
    assert_equal(crc32(data), UInt32(0xCBF43926))
    assert_equal(crc32(List[UInt8]()), UInt32(0))
    for seed in [UInt32(0), UInt32.MAX, UInt32(0x12345678), UInt32(0xCBF43926)]:
        for byte in range(256):
            assert_equal(
                _crc32_update(seed, UInt8(byte)), bitwise(seed, UInt8(byte))
            )
    data = List[UInt8]()
    for index in range(4096):
        data.append(UInt8((index * 73 + 19) % 251))
    for start in range(17):
        var expected = UInt32.MAX
        for index in range(start, len(data) - start):
            expected = bitwise(expected, data[index])
        assert_equal(crc32_range(data, start, len(data) - start), ~expected)


def test_block_crc_matches_bitwise_oracle_at_every_alignment_and_stream_boundary() raises:
    var data = List[UInt8](capacity=4112)
    var state = UInt32(12345)
    for _ in range(4112):
        state = state * 1664525 + 1013904223
        data.append(UInt8(state >> 24))
    for length in [
        0,
        1,
        7,
        8,
        9,
        16,
        31,
        32,
        33,
        63,
        64,
        65,
        127,
        128,
        129,
        255,
        256,
        1023,
        1024,
        4096,
    ]:
        for offset in range(16):
            var view = Span(data)[offset : offset + length]
            for initial in [
                UInt32(0),
                UInt32.MAX,
                UInt32(0x12345678),
                UInt32(0xCBF43926),
            ]:
                var expected = initial
                for byte in view:
                    expected = bitwise(expected, byte)
                assert_equal(crc32_update(initial, view), expected)
                for split in [
                    0,
                    min(length, 7),
                    min(length, 31),
                    min(length, 32),
                    length // 2,
                    length,
                ]:
                    var first = crc32_update(initial, view[:split])
                    assert_equal(crc32_update(first, view[split:]), expected)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
