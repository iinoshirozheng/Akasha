from std.math import floor, log
from std.memory import bitcast


comptime _SPLITMIX_INCREMENT = UInt64(0x9E3779B97F4A7C15)
comptime _SPLITMIX_MULTIPLIER_1 = UInt64(0xBF58476D1CE4E5B9)
comptime _SPLITMIX_MULTIPLIER_2 = UInt64(0x94D049BB133111EB)
comptime _TOP_53_MAXIMUM = UInt64(0x001FFFFFFFFFFFFF)
comptime _TWO_TO_53 = Float64(9007199254740992.0)
comptime _LARGEST_BELOW_ONE = Float64(0.9999999999999999)


def splitmix64(value: UInt64) -> UInt64:
    """Mix one 64-bit value using the SplitMix64 output permutation."""
    var mixed = value + _SPLITMIX_INCREMENT
    mixed = (mixed ^ (mixed >> UInt64(30))) * _SPLITMIX_MULTIPLIER_1
    mixed = (mixed ^ (mixed >> UInt64(27))) * _SPLITMIX_MULTIPLIER_2
    return mixed ^ (mixed >> UInt64(31))


def _id_bits(id: Int) -> UInt64:
    """Preserve the signed ID's two's-complement bit pattern."""
    return bitcast[DType.uint64](Int64(id))


def _uniform_open01_from_hash(hash: UInt64) -> Float64:
    """Map the hash's high 53 bits into the strict open interval (0, 1).

    Adding 0.5 centers each 53-bit bucket. At the largest bucket Float64's
    53-bit precision would round that sum to 2^53, so clamp that single case
    to the largest representable Float64 below one.
    """
    var top_53 = hash >> UInt64(11)
    if top_53 == _TOP_53_MAXIMUM:
        return _LARGEST_BELOW_ONE
    return (Float64(top_53) + 0.5) / _TWO_TO_53


def sample_level(id: Int, seed: UInt64, m: Int, maximum: Int) raises -> Int:
    """Sample a deterministic geometric HNSW level for an ID and seed."""
    if m < 2:
        raise Error("HNSW level multiplier must be at least two")
    if maximum < 0:
        raise Error("HNSW maximum level cannot be negative")
    if maximum == 0:
        return 0

    var hash = splitmix64(_id_bits(id) ^ seed)
    var uniform = _uniform_open01_from_hash(hash)
    var level = Int(floor(-log(uniform) / log(Float64(m))))
    if level > maximum:
        return maximum
    return level
