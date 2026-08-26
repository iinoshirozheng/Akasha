from akasha.index.hnsw_level import (
    _id_bits,
    _uniform_open01_from_hash,
    sample_level,
    splitmix64,
)
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def test_splitmix64_matches_golden_vectors() raises:
    # Values calculated independently from the SplitMix64 reference mixer.
    assert_equal(splitmix64(UInt64(0)), UInt64(0xE220A8397B1DCDAF))
    assert_equal(splitmix64(UInt64(1)), UInt64(0x910A2DEC89025CC1))
    assert_equal(splitmix64(UInt64(2)), UInt64(0x975835DE1C9756CE))
    assert_equal(
        splitmix64(UInt64(0xFFFFFFFFFFFFFFFF)),
        UInt64(0xE4D971771B652C20),
    )
    assert_equal(
        splitmix64(UInt64(0x123456789ABCDEF0)),
        UInt64(0x161922C645CE50E8),
    )


def test_uniform_mapping_is_strictly_inside_open_interval() raises:
    var from_zero = _uniform_open01_from_hash(UInt64(0))
    var from_maximum = _uniform_open01_from_hash(
        UInt64(0xFFFFFFFFFFFFFFFF)
    )
    assert_true(from_zero > 0.0)
    assert_true(from_zero < 1.0)
    assert_true(from_maximum > 0.0)
    assert_true(from_maximum < 1.0)


def test_sample_level_is_deterministic_and_seed_sensitive() raises:
    var seed = UInt64(0xA5A5A5A5A5A5A5A5)
    for id in range(-50, 51):
        assert_equal(
            sample_level(id, seed, 16, 8),
            sample_level(id, seed, 16, 8),
        )

    var changed = 0
    for id in range(256):
        if sample_level(id, UInt64(7), 16, 8) != sample_level(
            id, UInt64(11), 16, 8
        ):
            changed += 1
    assert_true(changed > 0)


def test_signed_ids_preserve_their_twos_complement_bits() raises:
    assert_equal(_id_bits(1), UInt64(1))
    assert_equal(_id_bits(-1), UInt64(0xFFFFFFFFFFFFFFFF))
    assert_equal(_id_bits(Int.MIN), UInt64(0x8000000000000000))
    assert_true(_id_bits(1) != _id_bits(-1))
    assert_true(
        sample_level(2, UInt64(23), 16, 8)
        != sample_level(-2, UInt64(23), 16, 8)
    )

    var negative_level = sample_level(-1, UInt64(23), 16, 8)
    var minimum_level = sample_level(Int.MIN, UInt64(23), 16, 8)
    assert_true(negative_level >= 0 and negative_level <= 8)
    assert_true(minimum_level >= 0 and minimum_level <= 8)


def test_sample_level_respects_maximum_including_zero() raises:
    for id in range(-100, 101):
        assert_equal(sample_level(id, UInt64(19), 16, 0), 0)
        assert_true(sample_level(id, UInt64(19), 2, 3) <= 3)


def test_sample_level_is_independent_of_iteration_order() raises:
    var seed = UInt64(0x0123456789ABCDEF)
    var forward = List[Int](length=512, fill=0)
    for id in range(512):
        forward[id] = sample_level(id, seed, 16, 8)

    for offset in range(512):
        var id = 511 - offset
        assert_equal(sample_level(id, seed, 16, 8), forward[id])


def test_sample_level_rejects_invalid_configuration() raises:
    with assert_raises():
        _ = sample_level(1, UInt64(0), 1, 8)
    with assert_raises():
        _ = sample_level(1, UInt64(0), 16, -1)


def test_default_distribution_is_geometric_and_bounded() raises:
    var level_zero = 0
    var level_one = 0
    var level_two = 0
    var seed = UInt64(0xA5A5A5A5A5A5A5A5)

    for id in range(100_000):
        var level = sample_level(id, seed, 16, 8)
        assert_true(level >= 0 and level <= 8)
        if level == 0:
            level_zero += 1
        elif level == 1:
            level_one += 1
        elif level == 2:
            level_two += 1

    assert_true(level_zero > 50_000)
    assert_true(level_zero > level_one)
    assert_true(level_one > level_two)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
