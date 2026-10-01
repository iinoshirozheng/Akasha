"""Compare selected CRC, byte and portable block loops, and installed zlib."""

from akasha.storage.checksum import CRC32_INITIAL, _crc32_update, _crc32_update_blocks, crc32_update
from std.ffi import OwnedDLHandle, c_size_t, c_ulong
from std.sys.arg import argv
from std.testing import assert_equal
from std.time import perf_counter_ns


def byte_crc32_update(register: UInt32, data: Span[UInt8, _]) -> UInt32:
    var result = register
    for byte in data:
        result = _crc32_update(result, byte)
    return result


@always_inline
def portable_crc32_update(register: UInt32, data: Span[UInt8, _]) -> UInt32:
    if len(data) >= 32:
        return _crc32_update_blocks(register, data)
    return byte_crc32_update(register, data)


def main() raises:
    var args = argv()
    if len(args) != 2:
        raise Error("usage: crc32-bench PATH_TO_ZLIB")
    var library = OwnedDLHandle(args[1])
    var zlib_crc = library.get_function[c_ulong]("crc32_z")
    var data = List[UInt8](capacity=64 * 1024 * 1024 + 16)
    var state = UInt32(12345)
    for _ in range(64 * 1024 * 1024 + 16):
        state = state * 1664525 + 1013904223
        data.append(UInt8(state >> 24))
    for size in range(130):
        for offset in range(16):
            var view = Span(data)[offset : offset + size]
            var expected = UInt32(
                zlib_crc(c_ulong(0), view.unsafe_ptr(), c_size_t(size))
            )
            assert_equal(~crc32_update(CRC32_INITIAL, view), expected)
            for split in [0, size // 2, size]:
                var register = crc32_update(CRC32_INITIAL, view[:split])
                assert_equal(
                    ~crc32_update(register, view[split:]), expected
                )
    for size in [
        0,
        1,
        7,
        8,
        9,
        16,
        31,
        32,
        63,
        64,
        127,
        256,
        4096,
        65536,
        1024 * 1024,
        64 * 1024 * 1024,
    ]:
        var view = Span(data)[1 : 1 + size]
        var expected = UInt32(
            zlib_crc(c_ulong(0), view.unsafe_ptr(), c_size_t(size))
        )
        var repeats = max(1, min(100_000, 64 * 1024 * 1024 // max(size, 1)))
        for trial in range(5):
            var expected_observed = UInt32(0)
            for step in range(4):
                var variant = (step + trial) % 4
                var observed = UInt32(0)
                var start = perf_counter_ns()
                for repetition in range(repeats):
                    # Vary the register so a pure checksum call cannot be
                    # hoisted out of the repetition loop.
                    var initial = CRC32_INITIAL ^ UInt32(repetition)
                    if variant == 0:
                        observed ^= ~byte_crc32_update(initial, view)
                    elif variant == 1:
                        observed ^= ~crc32_update(initial, view)
                    elif variant == 3:
                        observed ^= ~portable_crc32_update(initial, view)
                    else:
                        observed ^= UInt32(
                            zlib_crc(
                                c_ulong(~initial),
                                view.unsafe_ptr(),
                                c_size_t(size),
                            )
                        )
                var elapsed = perf_counter_ns() - start
                if step == 0:
                    expected_observed = observed
                else:
                    assert_equal(observed, expected_observed)
                print(
                    "size="
                    + String(size)
                    + " trial="
                    + String(trial)
                    + " variant="
                    + String(variant)
                    + " repeats="
                    + String(repeats)
                    + " ns="
                    + String(elapsed)
                    + " crc="
                    + String(expected)
                )
