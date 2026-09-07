from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult
from std.math import isfinite


struct SparseElement(TrivialRegisterPassable, Writable):
    var term_id: Int
    var weight: Float32

    def __init__(out self, term_id: Int, weight: Float32):
        self.term_id = term_id
        self.weight = weight


struct SparseRecord(Movable):
    var id: Int
    var elements: List[SparseElement]

    def __init__(out self, id: Int, var elements: List[SparseElement]):
        self.id = id
        self.elements = elements^

    def clone(self) -> SparseRecord:
        var elements = self.elements.copy()
        return SparseRecord(self.id, elements^)


struct _Posting(TrivialRegisterPassable, Writable):
    var id: Int
    var weight: Float32

    def __init__(out self, id: Int, weight: Float32):
        self.id = id
        self.weight = weight


struct _PostingList(Movable):
    var term_id: Int
    var postings: List[_Posting]

    def __init__(out self, term_id: Int):
        self.term_id = term_id
        self.postings = List[_Posting]()


struct _SparseScore(TrivialRegisterPassable, Writable):
    var id: Int
    var score: Float32

    def __init__(out self, id: Int, score: Float32):
        self.id = id
        self.score = score


def validate_sparse(elements: List[SparseElement]) raises:
    if len(elements) == 0:
        raise Error("sparse vectors cannot be empty")
    var previous = -1
    for element in elements:
        if element.term_id < 0:
            raise Error("sparse term IDs must be non-negative")
        if element.term_id <= previous:
            raise Error("sparse term IDs must be unique and ascending")
        if not isfinite(element.weight) or element.weight == 0.0:
            raise Error("sparse weights must be finite and non-zero")
        previous = element.term_id


struct SparseIndex:
    """An owning sparse-vector index backed by term posting lists."""

    var _records: List[SparseRecord]
    var _terms: List[_PostingList]
    var _record_slots: Dict[Int, Int]
    var _term_slots: Dict[Int, Int]

    def __init__(out self):
        self._records = List[SparseRecord]()
        self._terms = List[_PostingList]()
        self._record_slots = Dict[Int, Int]()
        self._term_slots = Dict[Int, Int]()

    def point_count(self) -> Int:
        return len(self._records)

    def clone(self) raises -> SparseIndex:
        var result = SparseIndex()
        for record in self.records():
            result.upsert(record.id, record.elements)
        return result^

    def contains(self, id: Int) -> Bool:
        return id in self._record_slots

    def upsert(mut self, id: Int, elements: List[SparseElement]) raises:
        validate_sparse(elements)
        self.delete(id)
        var owned = elements.copy()
        self._record_slots[id] = len(self._records)
        self._records.append(SparseRecord(id, owned^))
        for element in elements:
            var term_index = self._term_slots.get(element.term_id, -1)
            if term_index < 0:
                self._terms.append(_PostingList(element.term_id))
                term_index = len(self._terms) - 1
                self._term_slots[element.term_id] = term_index
            self._terms[term_index].postings.append(
                _Posting(id, element.weight)
            )

    def delete(mut self, id: Int):
        var record_index = self._record_slots.pop(id, -1)
        if record_index < 0:
            return
        var removed = self._records[record_index].elements.copy()
        self._records.swap_elements(record_index, len(self._records) - 1)
        _ = self._records.pop()
        if record_index < len(self._records):
            self._record_slots[self._records[record_index].id] = record_index
        for element in removed:
            var term_index = self._term_slots.get(element.term_id, -1)
            if term_index < 0:
                continue
            for posting_index in range(len(self._terms[term_index].postings)):
                if self._terms[term_index].postings[posting_index].id == id:
                    self._terms[term_index].postings.swap_elements(
                        posting_index,
                        len(self._terms[term_index].postings) - 1,
                    )
                    _ = self._terms[term_index].postings.pop()
                    break
            if len(self._terms[term_index].postings) == 0:
                _ = self._term_slots.pop(element.term_id, -1)
                self._terms.swap_elements(term_index, len(self._terms) - 1)
                _ = self._terms.pop()
                if term_index < len(self._terms):
                    self._term_slots[self._terms[term_index].term_id] = term_index

    def records(self) -> List[SparseRecord]:
        var result = List[SparseRecord](capacity=len(self._records))
        for index in range(len(self._records)):
            result.append(self._records[index].clone())
        return result^

    def search_dot(
        self, query: List[SparseElement], k: Int
    ) raises -> List[SearchResult]:
        validate_sparse(query)
        if k <= 0:
            raise Error("k must be positive")
        var scores = List[_SparseScore]()
        # Keep first-encounter and Float32 accumulation order independent of
        # the dictionary's storage/iteration order.
        var score_slots = Dict[Int, Int]()
        for query_element in query:
            var term_index = self._term_slots.get(query_element.term_id, -1)
            if term_index < 0:
                continue
            for posting in self._terms[term_index].postings:
                var score_index = score_slots.get(posting.id, -1)
                var contribution = query_element.weight * posting.weight
                if score_index < 0:
                    score_slots[posting.id] = len(scores)
                    scores.append(_SparseScore(posting.id, contribution))
                else:
                    scores[score_index].score += contribution
        if len(scores) == 0:
            return List[SearchResult]()
        var capacity = k
        if capacity > len(scores):
            capacity = len(scores)
        var topk = BoundedTopK(capacity, smaller_is_better=False)
        for score in scores:
            topk.offer(score.id, score.score)
        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^
