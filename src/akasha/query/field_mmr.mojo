"""Captured-root MMR adapter for Qdrant's F32 volatile vector scoring.

Source: shard/src/query/mmr/{mod,lazy_matrix}.rs at
74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
Cells are directional, including MaxSim. A dictionary holds the same requested
cells as upstream's n*n Option matrix without reserving all uncomputed cells.
"""

from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.hnsw_stats import copy_search_stats
from akasha.query.control import QueryControl
from akasha.query.field_search import FieldSearchExecution, FieldSearchResult
from akasha.query.mmr import MmrSimilarity, maximal_marginal_relevance
from akasha.query.recommendation_metrics import prepare_recommendation_vector, recommendation_similarity
from akasha.storage.read_generation import ReadGeneration


struct MmrMatrix(MmrSimilarity, Movable):
    var vectors: List[VectorValue]
    var queries: List[VectorValue]
    var field: VectorFieldSpec
    var cells: Dict[Int, Float32]
    var evaluations: Int
    var initial_work: Int

    def __init__(
        out self, var vectors: List[VectorValue], field: VectorFieldSpec,
        control: Optional[QueryControl] = None, initial_work: Int = 0,
    ) raises:
        self.vectors = vectors^
        # Qdrant copies retrieved values to volatile F32 storage for MMR,
        # irrespective of the collection's original storage datatype.
        self.field = VectorFieldSpec(field.id, field.name, field.kind, 0, field.metric, UInt8(2 if field.kind == 1 else 0), field.dimension)
        self.queries = List[VectorValue]()
        for i in range(len(self.vectors)):
            if control:
                control.value().checkpoint(i)
            self.queries.append(prepare_recommendation_vector(self.vectors[i], self.field))
        self.cells = Dict[Int, Float32]()
        self.evaluations = 0
        self.initial_work = initial_work

    def get_similarity(mut self, i: Int, j: Int, control: Optional[QueryControl]) raises -> Float32:
        var key = i * len(self.vectors) + j
        if key in self.cells:
            return self.cells[key]
        if control:
            control.value().checkpoint(self.evaluations)
            control.value().validate_candidate_count(self.initial_work + self.evaluations + 1)
        var score = recommendation_similarity(self.queries[i], self.vectors[j], self.field)
        self.cells[key] = score
        self.evaluations += 1
        return score


def rerank_generation_mmr(
    view: ReadGeneration, field: VectorFieldSpec, query: VectorValue,
    var execution: FieldSearchExecution, k: Int, diversity: Float32,
    control: Optional[QueryControl] = None, *, prior_work: Int = -1,
) raises -> FieldSearchExecution:
    var work = view.visible_count if prior_work == -1 else prior_work
    if work < 0:
        raise Error("MMR prior work must be nonnegative")
    var candidates = List[FieldSearchResult]()
    var vectors = List[VectorValue]()
    var seen = Dict[Int, Bool]()
    for i in range(len(execution.results)):
        if control:
            control.value().checkpoint(i)
        var hit = execution.results[i]
        if hit.id in seen:
            continue
        seen[hit.id] = True
        var location = view.find(hit.id)
        if location[0] < 0:
            continue
        ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
        var ordinal = entry.field_ordinal(field.id)
        if ordinal < 0:
            continue
        # Native values remain authoritative; canonicalize for this source
        # scorer without modifying persisted native vectors.
        vectors.append(prepare_recommendation_vector(entry.vector_at(ordinal).value(), field))
        candidates.append(hit)
    var stats = copy_search_stats(execution.stats)
    stats.backend_name = "qdrant-mmr-f32"
    stats.storage_name = "field-mmr"
    stats.base_candidates = len(candidates)
    stats.reranked_candidates = len(candidates)
    var results = List[FieldSearchResult]()
    if len(candidates) < 2:
        results = candidates^
    else:
        if control:
            control.value().validate_candidate_count(work + len(candidates))
        var matrix = MmrMatrix(vectors^, field, control, work + len(candidates))
        var prepared = prepare_recommendation_vector(query, matrix.field)
        var relevance = List[Float32]()
        for i in range(len(candidates)):
            if control:
                control.value().checkpoint(i)
            relevance.append(recommendation_similarity(prepared, matrix.vectors[i], matrix.field))
        var selected = maximal_marginal_relevance(relevance, matrix, Float32(1) - diversity, k, control)
        for i in selected:
            results.append(candidates[i])
        stats.distance_evaluations += len(candidates) + matrix.evaluations
    if control:
        control.value().checkpoint(0)
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "field_mmr")
