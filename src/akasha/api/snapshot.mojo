from akasha.compute.simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
from akasha.compute.topk import BoundedTopK
from akasha.document.record import clone_fields, DocumentRecord
from akasha.index.bitmap import Bitmap
from akasha.index.flat import SearchResult
from akasha.index.metadata import MetadataIndex
from akasha.query.executor import candidate_entries
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.index_evaluator import evaluate_all, evaluate_expression
from akasha.storage.memtable import MemTable
from std.math import isfinite


comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct ReadSnapshot(Movable):
    """An immutable, owned collection view at one accepted sequence."""

    var _dimension: Int
    var _generation: UInt64
    var _sequence: UInt64
    var _memtable: MemTable
    var _metadata: MetadataIndex

    def __init__(
        out self,
        dimension: Int,
        generation: UInt64,
        sequence: UInt64,
        var memtable: MemTable,
        var metadata: MetadataIndex,
    ):
        self._dimension = dimension
        self._generation = generation
        self._sequence = sequence
        self._memtable = memtable^
        self._metadata = metadata^

    @staticmethod
    def capture(
        dimension: Int,
        generation: UInt64,
        sequence: UInt64,
        memtable: MemTable,
    ) raises -> ReadSnapshot:
        if dimension <= 0 or memtable.dimension != dimension:
            raise Error("snapshot dimension mismatch")
        if sequence != memtable.last_sequence:
            raise Error("snapshot sequence does not match memtable")
        var owned = memtable.clone()
        var metadata = _build_metadata(owned)
        return ReadSnapshot(
            dimension,
            generation,
            sequence,
            owned^,
            metadata^,
        )

    def generation(self) -> UInt64:
        return self._generation

    def last_sequence(self) -> UInt64:
        return self._sequence

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        return self._memtable.get(id)

    def search_dot(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        var conditions = List[FilterCondition]()
        return self._search_filtered(query, k, _DOT_METRIC, conditions)

    def search_l2(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        var conditions = List[FilterCondition]()
        return self._search_filtered(query, k, _L2_METRIC, conditions)

    def search_cosine(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        var conditions = List[FilterCondition]()
        return self._search_filtered(query, k, _COSINE_METRIC, conditions)

    def search_dot_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        return self._search_filtered(query, k, _DOT_METRIC, conditions)

    def search_l2_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        return self._search_filtered(query, k, _L2_METRIC, conditions)

    def search_cosine_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        return self._search_filtered(query, k, _COSINE_METRIC, conditions)

    def search_dot_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_where(query, k, _DOT_METRIC, expression)

    def search_l2_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_where(query, k, _L2_METRIC, expression)

    def search_cosine_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_where(query, k, _COSINE_METRIC, expression)

    def _search_filtered(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        for index in range(len(conditions)):
            conditions[index].validate()
        var candidates = evaluate_all(self._metadata, conditions)
        return self._search_candidates(query, k, metric, candidates)

    def _search_where(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        expression.validate()
        var candidates = evaluate_expression(self._metadata, expression)
        return self._search_candidates(query, k, metric, candidates)

    def _search_candidates(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        candidates: Bitmap,
    ) raises -> List[SearchResult]:
        if candidates.count() == 0:
            return List[SearchResult]()
        var result_count = min(k, candidates.count())
        var topk = BoundedTopK(
            result_count, smaller_is_better=metric == _L2_METRIC
        )
        var entries = candidate_entries(self._memtable, candidates)
        for index in range(len(entries)):
            var score: Float32
            if metric == _DOT_METRIC:
                score = simd_dot_product(query, entries[index].values)
            elif metric == _L2_METRIC:
                score = simd_l2_squared_distance(query, entries[index].values)
            else:
                score = simd_cosine_similarity(query, entries[index].values)
            topk.offer(entries[index].id, score)

        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def _validate_query(self, query: List[Float32], k: Int) raises:
        if len(query) != self._dimension:
            raise Error("query dimension does not match snapshot")
        if k <= 0:
            raise Error("k must be positive")
        for value in query:
            if not isfinite(value):
                raise Error("query vector must contain only finite values")


def _build_metadata(memtable: MemTable) raises -> MetadataIndex:
    var index = MetadataIndex()
    index.begin_bulk()
    for ordinal in range(memtable.slot_count()):
        var entry = memtable.entry_at(ordinal)
        if entry.tombstone:
            index.delete(entry.id)
        else:
            var fields = clone_fields(entry.fields)
            index.upsert(entry.id, fields^)
    index.finish_bulk()
    if index.slot_count() != memtable.slot_count():
        raise Error("snapshot metadata slot alignment failed")
    return index^
