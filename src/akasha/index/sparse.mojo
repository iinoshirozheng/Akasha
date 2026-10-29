"""Mutable sparse records with the shared Qdrant postings search execution."""

from akasha.index.sparse_values import SparseElement, SparseRecord, validate_sparse, validate_legacy_sparse
from akasha.index.field_artifacts import FieldRow
from akasha.index.field_sparse import FieldSparseIndex
from akasha.index.sparse_search import search_sparse_postings
from akasha.index.flat import SearchResult
from std.memory import ArcPointer


struct SparseIndex:
    """Owning mutable records; searches capture an immutable postings view."""

    var _records: List[SparseRecord]
    var _record_slots: Dict[Int, Int]

    def __init__(out self):
        self._records = List[SparseRecord]()
        self._record_slots = Dict[Int, Int]()

    def point_count(self) -> Int:
        return len(self._records)

    def clone(self) raises -> SparseIndex:
        var result = SparseIndex()
        for record in self.records():
            result.upsert(record.id, record.elements)
        return result^

    def content_bytes(self) -> Int:
        var total = 0
        for row in range(len(self._records)):
            total += 8 + len(self._records[row].elements) * 12
        return total

    def contains(self, id: Int) -> Bool:
        return id in self._record_slots

    def upsert(mut self, id: Int, elements: List[SparseElement]) raises:
        validate_sparse(elements)
        self.delete(id)
        self._record_slots[id] = len(self._records)
        self._records.append(SparseRecord(id, elements.copy()))

    def delete(mut self, id: Int):
        var slot = self._record_slots.pop(id, -1)
        if slot < 0:
            return
        self._records.swap_elements(slot, len(self._records) - 1)
        _ = self._records.pop()
        if slot < len(self._records):
            self._record_slots[self._records[slot].id] = slot

    def records(self) -> List[SparseRecord]:
        var result = List[SparseRecord](capacity=len(self._records))
        for row in range(len(self._records)):
            result.append(self._records[row].clone())
        return result^

    def search_dot(self, query: List[SparseElement], k: Int) raises -> List[SearchResult]:
        validate_sparse(query)
        if k <= 0:
            raise Error("k must be positive")
        var index = FieldSparseIndex()
        for row in range(len(self._records)):
            ref record = self._records[row]
            index.add(FieldRow(record.id, 0, row), record.elements)
        var outcome = search_sparse_postings(
            ArcPointer(index^), query,
            List[Bool](length=len(self._records), fill=True), k, False,
        )
        var results = List[SearchResult](capacity=len(outcome.results))
        for hit in outcome.results:
            results.append(SearchResult(hit.id, hit.score))
        return results^
