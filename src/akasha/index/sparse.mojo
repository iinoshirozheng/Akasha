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

    def __init__(out self):
        self._records = List[SparseRecord]()
        self._terms = List[_PostingList]()

    def point_count(self) -> Int:
        return len(self._records)

    def contains(self, id: Int) -> Bool:
        return self._find_record(id) >= 0

    def upsert(
        mut self, id: Int, elements: List[SparseElement]
    ) raises:
        validate_sparse(elements)
        self.delete(id)
        var owned = elements.copy()
        self._records.append(SparseRecord(id, owned^))
        for element in elements:
            var term_index = self._find_term(element.term_id)
            if term_index < 0:
                self._terms.append(_PostingList(element.term_id))
                term_index = len(self._terms) - 1
            self._terms[term_index].postings.append(
                _Posting(id, element.weight)
            )

    def delete(mut self, id: Int):
        var record_index = self._find_record(id)
        if record_index < 0:
            return
        var removed = self._records[record_index].elements.copy()
        self._records.swap_elements(record_index, len(self._records) - 1)
        _ = self._records.pop()
        for element in removed:
            var term_index = self._find_term(element.term_id)
            if term_index < 0:
                continue
            for posting_index in range(
                len(self._terms[term_index].postings)
            ):
                if self._terms[term_index].postings[posting_index].id == id:
                    self._terms[term_index].postings.swap_elements(
                        posting_index,
                        len(self._terms[term_index].postings) - 1,
                    )
                    _ = self._terms[term_index].postings.pop()
                    break

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
        for query_element in query:
            var term_index = self._find_term(query_element.term_id)
            if term_index < 0:
                continue
            for posting in self._terms[term_index].postings:
                var score_index = -1
                for index in range(len(scores)):
                    if scores[index].id == posting.id:
                        score_index = index
                        break
                var contribution = query_element.weight * posting.weight
                if score_index < 0:
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

    def _find_record(self, id: Int) -> Int:
        for index in range(len(self._records)):
            if self._records[index].id == id:
                return index
        return -1

    def _find_term(self, term_id: Int) -> Int:
        for index in range(len(self._terms)):
            if self._terms[index].term_id == term_id:
                return index
        return -1
