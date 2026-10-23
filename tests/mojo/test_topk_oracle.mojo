from akasha.compute.topk import BoundedTopK, TopKEntry
from std.memory import bitcast
from std.testing import assert_equal, TestSuite


def _same_bits[T: DType](left: Scalar[T], right: Scalar[T]) raises:
    comptime if T == DType.float32:
        assert_equal(bitcast[DType.uint32](left), bitcast[DType.uint32](right))
    else:
        assert_equal(bitcast[DType.uint64](left), bitcast[DType.uint64](right))


def _oracle[T: DType](smaller: Bool) raises:
    for capacity in [1, 2, 10, 31, 257, 300]:
        var heap = BoundedTopK[T](capacity, smaller_is_better=smaller)
        for phase in range(3):
            var ordered = List[TopKEntry[T]]()
            for i in range(257):
                var id = (i * 37 + phase * 13) % 257 - 128
                var value = Scalar[T]((i * 97 + phase * 17) % 43 - 21)
                if i % 17 == 0:
                    value = Scalar[T](-0.0)
                elif i % 19 == 0:
                    value = Scalar[T](0.0)
                elif i % 23 == 0:
                    comptime if T == DType.float32:
                        value = rebind[Scalar[T]](bitcast[DType.float32](UInt32(0x7f800000)))
                    else:
                        value = rebind[Scalar[T]](bitcast[DType.float64](UInt64(0x7ff0000000000000)))
                elif i % 29 == 0:
                    comptime if T == DType.float32:
                        value = rebind[Scalar[T]](bitcast[DType.float32](UInt32(0xff800000)))
                    else:
                        value = rebind[Scalar[T]](bitcast[DType.float64](UInt64(0xfff0000000000000)))
                elif i % 31 == 0:
                    comptime if T == DType.float32:
                        value = rebind[Scalar[T]](bitcast[DType.float32](UInt32(0x7f7fffff)))
                    else:
                        value = rebind[Scalar[T]](bitcast[DType.float64](UInt64(0x7fefffffffffffff)))
                heap.offer(id, value)
                # Independent insertion-sorted full list; no heap/helper reuse.
                ordered.append(TopKEntry[T](id, value))
                var at = len(ordered) - 1
                while at > 0:
                    var previous = ordered[at - 1]
                    var precedes = id < previous.id if value == previous.score else (
                        value < previous.score if smaller else value > previous.score
                    )
                    if not precedes:
                        break
                    ordered[at] = previous
                    at -= 1
                ordered[at] = TopKEntry[T](id, value)
            var actual = heap.sorted_entries()
            assert_equal(len(actual), min(capacity, len(ordered)))
            for i in range(len(actual)):
                assert_equal(actual[i].id, ordered[i].id)
                _same_bits[T](actual[i].score, ordered[i].score)
            assert_equal(len(heap.sorted_entries()), 0)


def test_f32_sorted_oracle_directions_and_reuse() raises:
    _oracle[DType.float32](False)
    _oracle[DType.float32](True)


def test_f64_sorted_oracle_directions_and_reuse() raises:
    _oracle[DType.float64](False)
    _oracle[DType.float64](True)


def _ties_and_nan[T: DType]() raises:
    for smaller in [False, True]:
        var heap = BoundedTopK[T](1, smaller_is_better=smaller)
        heap.offer(-7, Scalar[T](-0.0))
        heap.offer(-7, Scalar[T](0.0))
        var result = heap.sorted_entries()
        assert_equal(result[0].id, -7)
        _same_bits[T](result[0].score, Scalar[T](-0.0))
        var nan: Scalar[T]
        comptime if T == DType.float32:
            nan = rebind[Scalar[T]](bitcast[DType.float32](UInt32(0x7fc01234)))
        else:
            nan = rebind[Scalar[T]](bitcast[DType.float64](UInt64(0x7ff8000000001234)))
        heap.offer(9, nan)
        heap.offer(-100, Scalar[T](2.0))
        result = heap.sorted_entries()
        assert_equal(result[0].id, 9)
        _same_bits[T](result[0].score, nan)
        heap.offer(10, Scalar[T](2.0))
        heap.offer(-100, nan)
        result = heap.sorted_entries()
        assert_equal(result[0].id, 10)
        _same_bits[T](result[0].score, Scalar[T](2.0))


def test_equal_id_signed_zero_and_nan_keep_existing_entry() raises:
    _ties_and_nan[DType.float32]()
    _ties_and_nan[DType.float64]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
