"""siphasher 1.0.3 zero-key SipHash-2-4 for Qdrant's stable ID slices.

Translated from src/sip.rs Hasher::hash/finish_with_state, reset, Sip24Rounds
and src/common.rs compress!; MIT OR Apache-2.0, see THIRD_PARTY_NOTICES.md.
Owned byte lists replace Rust slices; scalar UInt64 addition wraps modulo 2^64.
"""


def _rotate(value: UInt64, count: Int) -> UInt64:
    return (value << UInt64(count)) | (value >> UInt64(64 - count))


struct _State:
    var v0: UInt64
    var v1: UInt64
    var v2: UInt64
    var v3: UInt64

    def __init__(out self):
        self.v0 = 0x736f6d6570736575
        self.v1 = 0x646f72616e646f6d
        self.v2 = 0x6c7967656e657261
        self.v3 = 0x7465646279746573

    def compress(mut self):
        self.v0 += self.v1
        self.v1 = _rotate(self.v1, 13)
        self.v1 ^= self.v0
        self.v0 = _rotate(self.v0, 32)
        self.v2 += self.v3
        self.v3 = _rotate(self.v3, 16)
        self.v3 ^= self.v2
        self.v0 += self.v3
        self.v3 = _rotate(self.v3, 21)
        self.v3 ^= self.v0
        self.v2 += self.v1
        self.v1 = _rotate(self.v1, 17)
        self.v1 ^= self.v2
        self.v2 = _rotate(self.v2, 32)

    def write_word(mut self, word: UInt64):
        self.v3 ^= word
        self.compress()
        self.compress()
        self.v0 ^= word

    def finish(mut self, length: Int, tail: UInt64) -> UInt64:
        self.write_word(((UInt64(length) & 0xff) << 56) | tail)
        self.v2 ^= 0xff
        for _ in range(4):
            self.compress()
        return self.v0 ^ self.v1 ^ self.v2 ^ self.v3


def siphash24_zero(data: List[UInt8]) -> UInt64:
    var state = _State()
    var offset = 0
    while offset + 8 <= len(data):
        var word = UInt64(0)
        for i in range(8):
            word |= UInt64(data[offset + i]) << UInt64(8 * i)
        state.write_word(word)
        offset += 8
    var tail = UInt64(0)
    for i in range(len(data) - offset):
        tail |= UInt64(data[offset + i]) << UInt64(8 * i)
    return state.finish(len(data), tail)


def slice_numeric_id_hash(id: UInt64) -> UInt64:
    # Qdrant slice_point_id_hash writes the numeric ID's eight LE bytes.
    var bytes = List[UInt8]()
    for i in range(8):
        bytes.append(UInt8(id >> UInt64(8 * i)))
    return siphash24_zero(bytes)
