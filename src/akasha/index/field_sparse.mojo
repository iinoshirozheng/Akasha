"""Immutable per-field postings with native F32 weights and F64 accumulation.

Unlike the mutable legacy SparseIndex, this root-owned index needs no duplicate
owned records or delete bookkeeping. Rows include present empty vectors, whose
zero scores must compete with negative matches in native field search.
"""

from akasha.index.field_artifacts import FieldRow
from akasha.index.sparse import SparseElement
from akasha.query.control import QueryControl


@fieldwise_init
struct _FieldPosting(TrivialRegisterPassable):
    var row: Int
    var weight: Float32


struct FieldSparseIndex(Movable):
    var rows: List[FieldRow]
    var postings: Dict[Int, List[_FieldPosting]]

    def __init__(out self):
        self.rows = List[FieldRow]()
        self.postings = Dict[Int, List[_FieldPosting]]()

    def add(mut self, location: FieldRow, values: List[SparseElement]) raises:
        var row = len(self.rows)
        self.rows.append(location)
        for value in values:
            if value.term_id not in self.postings:
                self.postings[value.term_id] = List[_FieldPosting]()
            self.postings[value.term_id].append(
                _FieldPosting(row, value.weight)
            )

    def scores(
        self, query: List[SparseElement], control: Optional[QueryControl]
    ) raises -> Dict[Int, Float64]:
        var result = Dict[Int, Float64]()
        var visited = 0
        # Query terms are schema-validated and ascending, preserving each row's
        # exact scalar oracle order independently of dictionary iteration order.
        for term in query:
            if term.term_id not in self.postings:
                continue
            for posting in self.postings[term.term_id]:
                if control:
                    control.value().checkpoint(visited)
                visited += 1
                var contribution = Float64(term.weight) * Float64(
                    posting.weight
                )
                result[posting.row] = (
                    result.get(posting.row, Float64(0)) + contribution
                )
        return result^
