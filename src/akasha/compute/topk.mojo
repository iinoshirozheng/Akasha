struct TopKEntry[score_type: DType = DType.float32](
    TrivialRegisterPassable, Writable
):
    """A point ID and metric score retained by a bounded Top-K heap."""

    var id: Int
    var score: Scalar[Self.score_type]

    def __init__(out self, id: Int, score: Scalar[Self.score_type]):
        self.id = id
        self.score = score


def _is_better[
    score_type: DType
](
    lhs: TopKEntry[score_type],
    rhs: TopKEntry[score_type],
    smaller_is_better: Bool,
) -> Bool:
    if lhs.score == rhs.score:
        return lhs.id < rhs.id
    if smaller_is_better:
        return lhs.score < rhs.score
    return lhs.score > rhs.score


def _is_worse[
    score_type: DType
](
    lhs: TopKEntry[score_type],
    rhs: TopKEntry[score_type],
    smaller_is_better: Bool,
) -> Bool:
    return _is_better[score_type](rhs, lhs, smaller_is_better)


struct BoundedTopK[score_type: DType = DType.float32]:
    """A fixed-capacity heap whose root is the worst retained entry."""

    var capacity: Int
    var smaller_is_better: Bool
    var _heap: List[TopKEntry[Self.score_type]]

    def __init__(out self, capacity: Int, *, smaller_is_better: Bool) raises:
        if capacity <= 0:
            raise Error("top-k capacity must be positive")
        self.capacity = capacity
        self.smaller_is_better = smaller_is_better
        self._heap = List[TopKEntry[Self.score_type]](capacity=capacity)

    def offer(mut self, id: Int, score: Scalar[Self.score_type]):
        """Retain the candidate only when it belongs in the current Top-K."""
        var candidate = TopKEntry[Self.score_type](id, score)
        if len(self._heap) < self.capacity:
            self._heap.append(candidate)
            self._sift_up(len(self._heap) - 1)
            return

        if _is_better[Self.score_type](
            candidate, self._heap[0], self.smaller_is_better
        ):
            self._heap[0] = candidate
            self._sift_down(0)

    def sorted_entries(mut self) -> List[TopKEntry[Self.score_type]]:
        """Drain retained entries into best-first deterministic order."""
        var result_count = len(self._heap)
        var results = List[TopKEntry[Self.score_type]](
            length=result_count, fill=TopKEntry[Self.score_type](0, 0.0)
        )
        var output_index = result_count - 1

        while len(self._heap) > 0:
            var last_index = len(self._heap) - 1
            self._heap.swap_elements(0, last_index)
            results[output_index] = self._heap.pop()
            output_index -= 1
            if len(self._heap) > 0:
                self._sift_down(0)

        return results^

    def _sift_up(mut self, start_index: Int):
        var index = start_index
        while index > 0:
            var parent = (index - 1) // 2
            if not _is_worse[Self.score_type](
                self._heap[index], self._heap[parent], self.smaller_is_better
            ):
                break
            self._heap.swap_elements(index, parent)
            index = parent

    def _sift_down(mut self, start_index: Int):
        var index = start_index
        while True:
            var left = 2 * index + 1
            if left >= len(self._heap):
                break

            var worst_child = left
            var right = left + 1
            if right < len(self._heap) and _is_worse[Self.score_type](
                self._heap[right],
                self._heap[left],
                self.smaller_is_better,
            ):
                worst_child = right

            if not _is_worse[Self.score_type](
                self._heap[worst_child],
                self._heap[index],
                self.smaller_is_better,
            ):
                break
            self._heap.swap_elements(index, worst_child)
            index = worst_child
