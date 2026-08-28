from .hnsw_heap import CandidateMinHeap, ResultMaxHeap


struct HnswSearchScratch(Movable):
    """Reusable HNSW traversal state with generation-stamped visits.

    A normal query reset advances ``epoch`` in O(1). The visited words are
    scanned only when the UInt32 epoch wraps, so repeated searches do not pay
    an O(slot_count) clear or allocate fresh heaps. This mutable scratch is
    single-owner state and must not be shared by concurrent searches.
    """

    var visited_epochs: List[UInt32]
    var epoch: UInt32
    var candidates: CandidateMinHeap
    var results: ResultMaxHeap
    var filtered_results: ResultMaxHeap
    var _prepared_slot_count: Int

    def __init__(out self):
        self.visited_epochs = List[UInt32]()
        self.epoch = UInt32(0)
        self.candidates = CandidateMinHeap()
        self.results = ResultMaxHeap()
        self.filtered_results = ResultMaxHeap()
        self._prepared_slot_count = 0

    def begin(mut self, slot_count: Int, ef: Int) raises:
        """Prepare scratch for one query without clearing visited storage."""
        if slot_count < 0:
            raise Error("HNSW scratch slot count cannot be negative")
        if ef <= 0:
            raise Error("HNSW scratch ef must be positive")

        self._ensure_slot_count(slot_count)
        # A begin may intentionally expose fewer slots than retained capacity.
        self._prepared_slot_count = slot_count
        if self.epoch == UInt32.MAX:
            self._reset_wrapped_epochs()
        else:
            self.epoch += UInt32(1)

        self.candidates.clear()
        self.results.clear()
        self.filtered_results.clear()
        self.candidates.reserve(ef)
        self.results.reserve(ef)
        self.filtered_results.reserve(ef)

    def filtered_result_reserved_capacity(self) -> Int:
        """Actual filtered-result heap allocation retained across rounds."""
        return self.filtered_results.capacity()

    def _ensure_slot_count(mut self, new_count: Int) raises:
        """Grow visit storage without changing the current query epoch."""
        if new_count < 0:
            raise Error("HNSW scratch slot count cannot be negative")
        if new_count <= self._prepared_slot_count:
            return

        while len(self.visited_epochs) < new_count:
            self.visited_epochs.append(UInt32(0))
        self._prepared_slot_count = new_count

    def visit(mut self, slot: UInt32) raises -> Bool:
        """Mark ``slot`` visited and report whether this is its first visit."""
        if self.epoch == UInt32(0):
            raise Error("HNSW scratch begin must be called before visit")
        if UInt64(slot) >= UInt64(self._prepared_slot_count):
            raise Error("HNSW scratch slot is outside the prepared range")
        var ordinal = Int(slot)
        if self.visited_epochs[ordinal] == self.epoch:
            return False
        self.visited_epochs[ordinal] = self.epoch
        return True

    def _force_epoch_for_test(mut self, epoch: UInt32):
        """Unexported test-only seam for exercising the rare wrap path."""
        self.epoch = epoch

    def _reset_wrapped_epochs(mut self):
        # This is the only O(capacity) reset; normal begin() never scans words.
        for index in range(len(self.visited_epochs)):
            self.visited_epochs[index] = UInt32(0)
        self.epoch = UInt32(1)
