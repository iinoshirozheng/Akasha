from akasha.storage.checksum import _crc32_update, crc32, crc32_range
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
