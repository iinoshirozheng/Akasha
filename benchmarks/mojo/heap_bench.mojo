"""Evaluate the pinned official heap against Akasha's bounded Top-K.

The candidate below is benchmark-only until its semantic and latency gates pass.
Private backing-list access is used only to inspect reservation/reuse, never to
implement an operation missing from BinaryHeap's public API.
"""

from akasha.compute.topk import BoundedTopK, TopKEntry
from std.collections.binary_heap import BinaryHeap
from std.math import inf
from std.memory import bitcast
from std.sys import size_of
from std.sys.arg import argv
from std.testing import assert_equal, assert_true, assert_raises
from std.time import perf_counter_ns


struct _OfficialEntry(Comparable, TrivialRegisterPassable):
    var id: Int
    var key: Float32

    def __init__(out self, id: Int, key: Float32):
        self.id = id
        self.key = key

    def __lt__(self, other: Self) -> Bool:
        if self.key == other.key:
            return self.id < other.id
        return self.key < other.key

    def __gt__(self, other: Self) -> Bool:
        return other < self

    def __eq__(self, other: Self) -> Bool:
        return self.id == other.id and self.key == other.key

    def __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    def __le__(self, other: Self) -> Bool:
        return self < other or self == other

    def __ge__(self, other: Self) -> Bool:
        return self > other or self == other


struct _OfficialTopK:
    var capacity: Int
    var smaller_is_better: Bool
    var _heap: BinaryHeap[_OfficialEntry]

    def __init__(out self, capacity: Int, *, smaller_is_better: Bool) raises:
        if capacity <= 0:
            raise Error("top-k capacity must be positive")
        self.capacity = capacity
        self.smaller_is_better = smaller_is_better
        self._heap = BinaryHeap[_OfficialEntry](capacity=capacity)

    def offer(mut self, id: Int, score: Float32):
        # Negation is exactly reversible for finite values, signed zeros and
        # infinities. It preserves the original 16-byte entry footprint.
        var candidate = _OfficialEntry(
            id, score if self.smaller_is_better else -score
        )
        if len(self._heap) < self.capacity:
            self._heap.push(candidate)
        elif candidate < self._heap.peek():
            # The pinned public API has no replace-root/push-pop operation.
            _ = self._heap.pop()
            self._heap.push(candidate)

    def sorted_entries(mut self) -> List[TopKEntry]:
        var results = List[TopKEntry](
            length=len(self._heap), fill=TopKEntry(0, 0.0)
        )
        for output in range(len(results) - 1, -1, -1):
            var entry = self._heap.pop()
            results[output] = TopKEntry(
                entry.id, entry.key if self.smaller_is_better else -entry.key
            )
        return results^


def _before(left: TopKEntry, right: TopKEntry, smaller: Bool) -> Bool:
    if left.score == right.score:
        return left.id < right.id
    return left.score < right.score if smaller else left.score > right.score


def _validate() raises:
    assert_equal(size_of[TopKEntry](), size_of[_OfficialEntry]())
    with assert_raises():
        _ = _OfficialTopK(0, smaller_is_better=False)
    with assert_raises():
        _ = _OfficialTopK(-1, smaller_is_better=True)
    var cases = 0
    for smaller in [False, True]:
        for k in [1, 2, 10, 32, 1024]:
            var existing = BoundedTopK(k, smaller_is_better=smaller)
            var official = _OfficialTopK(k, smaller_is_better=smaller)
            var existing_address = Int(existing._heap.unsafe_ptr())
            var official_address = Int(official._heap._data.unsafe_ptr())
            var existing_capacity = existing._heap.capacity()
            var official_capacity = official._heap._data.capacity()
            assert_equal(existing_capacity, official_capacity)
            for count in [0, 1, k - 1, k, k + 1, 1025]:
                var model = List[TopKEntry]()
                for i in range(count):
                    var id = (i * 197) % 1031 - 500
                    var score = Float32((i * 37) % 73 - 36)
                    if i % 11 == 0:
                        score = -inf[DType.float32]()
                    elif i % 11 == 1:
                        score = inf[DType.float32]()
                    elif i % 11 == 2:
                        score = -3.0e38
                    elif i % 11 == 3:
                        score = 3.0e38
                    elif i % 11 == 4:
                        score = -0.0
                    elif i % 11 == 5:
                        score = 0.0
                    existing.offer(id, score)
                    official.offer(id, score)
                    # Independent insertion-sorted oracle, not either heap.
                    model.append(TopKEntry(id, score))
                    var cursor = len(model) - 1
                    while cursor > 0 and _before(
                        model[cursor], model[cursor - 1], smaller
                    ):
                        model.swap_elements(cursor, cursor - 1)
                        cursor -= 1
                var actual = official.sorted_entries()
                var baseline = existing.sorted_entries()
                assert_equal(len(actual), min(k, count))
                assert_equal(len(baseline), len(actual))
                for i in range(len(actual)):
                    assert_equal(actual[i].id, model[i].id)
                    assert_equal(baseline[i].id, model[i].id)
                    assert_equal(
                        bitcast[DType.uint32](actual[i].score),
                        bitcast[DType.uint32](model[i].score),
                    )
                    assert_equal(
                        bitcast[DType.uint32](baseline[i].score),
                        bitcast[DType.uint32](model[i].score),
                    )
                assert_equal(Int(existing._heap.unsafe_ptr()), existing_address)
                assert_equal(
                    Int(official._heap._data.unsafe_ptr()), official_address
                )
                assert_equal(existing._heap.capacity(), existing_capacity)
                assert_equal(official._heap._data.capacity(), official_capacity)
                assert_equal(len(official._heap), 0)
                cases += 1
    var heap = BinaryHeap[_OfficialEntry](capacity=32)
    var address = Int(heap._data.unsafe_ptr())
    for _ in range(8):
        heap.push(_OfficialEntry(-1, -0.0))
        heap.clear()
        assert_equal(len(heap), 0)
        assert_equal(Int(heap._data.unsafe_ptr()), address)
        assert_equal(heap._data.capacity(), 32)
    print(
        "PASS topk cases="
        + String(cases)
        + " entry_bytes="
        + String(size_of[_OfficialEntry]())
        + " backing_growths=0 clear_reuse=8"
    )


def _inputs(count: Int, pattern: String) raises -> List[TopKEntry]:
    var inputs = List[TopKEntry](capacity=count)
    var state = UInt64(12345)
    for i in range(count):
        state = state * UInt64(6364136223846793005) + UInt64(1)
        var score = Float32(Int(state >> 32) % 1_000_003) * 0.25
        if pattern == "ascending":
            score = Float32(i)
        elif pattern == "descending":
            score = Float32(count - i)
        elif pattern == "equal":
            score = 1.0
        elif pattern != "random":
            raise Error("unknown heap benchmark pattern")
        inputs.append(TopKEntry(count - i - count // 2, score))
    return inputs^


def _checksum(entries: List[TopKEntry]) -> UInt64:
    var result = UInt64(14695981039346656037)
    for entry in entries:
        result = (result ^ UInt64(entry.id)) * UInt64(1099511628211)
        result = (result ^ UInt64(bitcast[DType.uint32](entry.score))) * UInt64(
            1099511628211
        )
    return result


def _benchmark_existing(
    inputs: List[TopKEntry], k: Int, smaller: Bool, iterations: Int
) raises:
    var heap = BoundedTopK(k, smaller_is_better=smaller)
    var offer_ns = Int(0)
    var drain_ns = Int(0)
    var checksum = UInt64(0)
    for iteration in range(iterations + 1):
        var started = perf_counter_ns()
        for input in inputs:
            heap.offer(input.id, input.score)
        var offered = perf_counter_ns()
        var results = heap.sorted_entries()
        var drained = perf_counter_ns()
        if iteration > 0:
            offer_ns += offered - started
            drain_ns += drained - offered
        var current_checksum = _checksum(results)
        if iteration == 0:
            checksum = current_checksum
        elif current_checksum != checksum:
            raise Error("heap reuse changed results")
    print(
        "official="
        + String(False)
        + " k="
        + String(k)
        + " smaller="
        + String(smaller)
        + " count="
        + String(len(inputs))
        + " iterations="
        + String(iterations)
        + " offer_ns="
        + String(offer_ns)
        + " drain_ns="
        + String(drain_ns)
        + " checksum="
        + String(checksum)
    )


def _benchmark_official(
    inputs: List[TopKEntry], k: Int, smaller: Bool, iterations: Int
) raises:
    var heap = _OfficialTopK(k, smaller_is_better=smaller)
    var offer_ns = Int(0)
    var drain_ns = Int(0)
    var checksum = UInt64(0)
    for iteration in range(iterations + 1):
        var started = perf_counter_ns()
        for input in inputs:
            heap.offer(input.id, input.score)
        var offered = perf_counter_ns()
        var results = heap.sorted_entries()
        var drained = perf_counter_ns()
        if iteration > 0:
            offer_ns += offered - started
            drain_ns += drained - offered
        var current_checksum = _checksum(results)
        if iteration == 0:
            checksum = current_checksum
        elif current_checksum != checksum:
            raise Error("heap reuse changed results")
    print(
        "official="
        + String(True)
        + " k="
        + String(k)
        + " smaller="
        + String(smaller)
        + " count="
        + String(len(inputs))
        + " iterations="
        + String(iterations)
        + " offer_ns="
        + String(offer_ns)
        + " drain_ns="
        + String(drain_ns)
        + " checksum="
        + String(checksum)
    )


def main() raises:
    var args = argv()
    if len(args) == 1:
        _validate()
        return
    if len(args) != 7:
        raise Error(
            "usage: heap-bench [existing|official K min|max COUNT PATTERN"
            " ITERATIONS]"
        )
    var k = Int(args[2])
    var smaller = args[3] == "min"
    var count = Int(args[4])
    var iterations = Int(args[6])
    if (
        k <= 0
        or count <= 0
        or iterations <= 0
        or (args[3] != "min" and args[3] != "max")
    ):
        raise Error("invalid heap benchmark parameters")
    var inputs = _inputs(count, args[5])
    if args[1] == "existing":
        _benchmark_existing(inputs, k, smaller, iterations)
    elif args[1] == "official":
        _benchmark_official(inputs, k, smaller, iterations)
    else:
        raise Error("unknown heap benchmark implementation")
