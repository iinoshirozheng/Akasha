struct HnswHeapItem(Copyable, Movable, Writable):
    """Candidate ordered by canonical distance, public ID, then graph slot."""

    var slot: UInt32
    var id: Int
    var distance: Float32

    def __init__(out self, slot: UInt32, id: Int, distance: Float32):
        self.slot = slot
        self.id = id
        self.distance = distance


def _is_better(lhs: HnswHeapItem, rhs: HnswHeapItem) -> Bool:
    """Return whether lhs precedes rhs in deterministic best-first order."""
    if lhs.distance != rhs.distance:
        return lhs.distance < rhs.distance
    if lhs.id != rhs.id:
        return lhs.id < rhs.id
    return lhs.slot < rhs.slot


def _is_worse(lhs: HnswHeapItem, rhs: HnswHeapItem) -> Bool:
    """Return whether lhs precedes rhs in deterministic worst-first order."""
    return _is_better(rhs, lhs)


struct CandidateMinHeap(Sized):
    """Reusable binary min-heap for the HNSW traversal frontier."""

    var _heap: List[HnswHeapItem]

    def __init__(out self):
        self._heap = List[HnswHeapItem]()

    def __len__(self) -> Int:
        return len(self._heap)

    def is_empty(self) -> Bool:
        return len(self._heap) == 0

    def clear(mut self):
        self._heap.clear()

    def reserve(mut self, capacity: Int) raises:
        if capacity < 0:
            raise Error("candidate heap reserve capacity cannot be negative")
        self._heap.reserve(capacity)

    def peek(self) raises -> HnswHeapItem:
        if len(self._heap) == 0:
            raise Error("cannot peek an empty candidate heap")
        return self._heap[0].copy()

    def push(mut self, item: HnswHeapItem):
        self._heap.append(item.copy())
        self._sift_up(len(self._heap) - 1)

    def pop(mut self) raises -> HnswHeapItem:
        if len(self._heap) == 0:
            raise Error("cannot pop an empty candidate heap")

        var last_index = len(self._heap) - 1
        self._heap.swap_elements(0, last_index)
        var best = self._heap.pop()
        if len(self._heap) > 0:
            self._sift_down(0)
        return best^

    def _sift_up(mut self, start_index: Int):
        var index = start_index
        while index > 0:
            var parent = (index - 1) // 2
            if not _is_better(self._heap[index], self._heap[parent]):
                break
            self._heap.swap_elements(index, parent)
            index = parent

    def _sift_down(mut self, start_index: Int):
        var index = start_index
        while True:
            var left = 2 * index + 1
            if left >= len(self._heap):
                break

            var best_child = left
            var right = left + 1
            if right < len(self._heap) and _is_better(
                self._heap[right], self._heap[left]
            ):
                best_child = right

            if not _is_better(self._heap[best_child], self._heap[index]):
                break
            self._heap.swap_elements(index, best_child)
            index = best_child


struct ResultMaxHeap(Sized):
    """Reusable result heap whose root is the worst retained candidate.

    ``take_sorted_best`` drains the heap and returns deterministic best-first
    output, leaving its reserved storage available for the next query.
    """

    var _heap: List[HnswHeapItem]

    def __init__(out self):
        self._heap = List[HnswHeapItem]()

    def __len__(self) -> Int:
        return len(self._heap)

    def is_empty(self) -> Bool:
        return len(self._heap) == 0

    def capacity(self) -> Int:
        return self._heap.capacity()

    def clear(mut self):
        self._heap.clear()

    def reserve(mut self, capacity: Int) raises:
        if capacity < 0:
            raise Error("result heap reserve capacity cannot be negative")
        self._heap.reserve(capacity)

    def peek_worst(self) raises -> HnswHeapItem:
        if len(self._heap) == 0:
            raise Error("cannot peek an empty result heap")
        return self._heap[0].copy()

    def offer(mut self, item: HnswHeapItem, capacity: Int) raises:
        """Retain item only when it belongs to the best ``capacity`` items."""
        if capacity <= 0:
            raise Error("result heap capacity must be positive")

        while len(self._heap) > capacity:
            _ = self.pop_worst()

        if len(self._heap) < capacity:
            self._heap.append(item.copy())
            self._sift_up(len(self._heap) - 1)
            return

        if _is_better(item, self._heap[0]):
            self._heap[0] = item.copy()
            self._sift_down(0)

    def pop_worst(mut self) raises -> HnswHeapItem:
        if len(self._heap) == 0:
            raise Error("cannot pop an empty result heap")

        var last_index = len(self._heap) - 1
        self._heap.swap_elements(0, last_index)
        var worst = self._heap.pop()
        if len(self._heap) > 0:
            self._sift_down(0)
        return worst^

    def take_sorted_best(mut self) raises -> List[HnswHeapItem]:
        """Drain into ``(distance ASC, id ASC, slot ASC)`` order."""
        var result_count = len(self._heap)
        var results = List[HnswHeapItem](
            length=result_count,
            fill=HnswHeapItem(UInt32(0), 0, 0.0),
        )
        var output_index = result_count - 1
        while len(self._heap) > 0:
            results[output_index] = self.pop_worst()
            output_index -= 1
        return results^

    def _sift_up(mut self, start_index: Int):
        var index = start_index
        while index > 0:
            var parent = (index - 1) // 2
            if not _is_worse(self._heap[index], self._heap[parent]):
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
            if right < len(self._heap) and _is_worse(
                self._heap[right], self._heap[left]
            ):
                worst_child = right

            if not _is_worse(self._heap[worst_child], self._heap[index]):
                break
            self._heap.swap_elements(index, worst_child)
            index = worst_child
