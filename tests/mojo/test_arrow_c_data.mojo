from bindings.arrow_c_data import (
    ArrowArrayDescriptor,
    ArrowConsumerLease,
    validate_fixed_size_vectors,
    validate_sparse_offsets,
)
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def test_arrow_descriptors_validate_vectors_offsets_and_nulls() raises:
    var rows = ArrowArrayDescriptor(2, 1, 0, 3)
    var values = ArrowArrayDescriptor(6, 0, 0, 6)
    validate_fixed_size_vectors(rows, values, 3)
    validate_sparse_offsets([0, 2, 3], 3, 3)

    with assert_raises():
        _ = ArrowArrayDescriptor(2, 3, 0, 4)
    with assert_raises():
        validate_fixed_size_vectors(
            ArrowArrayDescriptor(2, 0, 1, 2), values, 3
        )
    with assert_raises():
        validate_sparse_offsets([0, 2, 2], 2, 2)


def test_arrow_consumer_release_callback_is_exactly_once() raises:
    var lease = ArrowConsumerLease()
    lease.ensure_active()
    assert_false(lease.released())
    lease.release()
    assert_true(lease.released())
    assert_equal(lease.release_callback_calls(), 1)
    with assert_raises():
        lease.ensure_active()
    with assert_raises():
        lease.release()
    assert_equal(lease.release_callback_calls(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
