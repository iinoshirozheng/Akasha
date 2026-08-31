from akasha.common.config import CollectionConfig
from akasha.compute.metric import MetricDispatcher
from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswEligibility
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.hnsw_view import HnswGraphView
from akasha.storage.memtable import MemTable
from std.collections import Dict


comptime _NO_BASE = 0
comptime _OWNED_BASE = 1
comptime _MAPPED_BASE = 2
comptime _DELTA_SOURCE = -1


def _accumulate_search_stats(
    mut target: HnswSearchStats, source: HnswSearchStats
):
    target.upper_visited += source.upper_visited
    target.base_visited += source.base_visited
    target.distance_evaluations += source.distance_evaluations
    target.filtered_rejections += source.filtered_rejections
    target.inactive_rejections += source.inactive_rejections


struct SegmentedHnsw(Movable):
    """One immutable checkpoint graph overlaid by a bounded mutable delta.

    The base can be packed owned storage or a validated mapped view. A source
    map binds each current public ID to its immutable base slot or to the
    mutable delta. Historical base nodes remain traversable, but their result
    IDs are admitted only while that exact base slot remains authoritative.
    """

    var config: CollectionConfig
    var _metric: MetricDispatcher
    var _base_kind: Int
    var _owned_base: HnswIndex
    var _mapped_base: HnswGraphView
    var _delta: HnswIndex
    var _sources: Dict[Int, Int]
    var _base_slots: Dict[Int, Int]
    var _delta_mutations: Int
    var _last_stats: HnswSearchStats

    def __init__(out self, config: CollectionConfig) raises:
        config.validate()
        self.config = config.copy()
        self._metric = MetricDispatcher(
            config.ann_metric, config.scalar_kind, config.dimension
        )
        self._base_kind = _NO_BASE
        self._owned_base = HnswIndex(config)
        self._mapped_base = HnswGraphView()
        self._delta = HnswIndex(config)
        self._sources = Dict[Int, Int]()
        self._base_slots = Dict[Int, Int]()
        self._delta_mutations = 0
        self._last_stats = HnswSearchStats()

    @staticmethod
    def from_owned(var base: HnswIndex) raises -> SegmentedHnsw:
        base.validate_structure()
        var result = SegmentedHnsw(base.config)
        result._owned_base = base^
        result._base_kind = _OWNED_BASE
        result._index_owned_base_sources()
        return result^

    @staticmethod
    def from_mapped(var base: HnswGraphView) raises -> SegmentedHnsw:
        # `HnswGraphView` instances are returned only after store validation;
        # avoid rescanning the complete mapping while adopting ownership.
        base.validate_search_ready()
        # Adopt an explicit copy of the view's already validated identity.
        var identity = base.config()
        var result = SegmentedHnsw(identity)
        result._mapped_base = base^
        result._base_kind = _MAPPED_BASE
        result._index_mapped_base_sources()
        return result^

    def base_is_mapped(self) -> Bool:
        return self._base_kind == _MAPPED_BASE

    def base_is_owned(self) -> Bool:
        return self._base_kind == _OWNED_BASE

    def has_base(self) -> Bool:
        return self._base_kind != _NO_BASE

    def base_slot_count(self) -> Int:
        if self._base_kind == _MAPPED_BASE:
            return self._mapped_base.slot_count()
        if self._base_kind == _OWNED_BASE:
            return self._owned_base.point_count()
        return 0

    def point_count(self) -> Int:
        return self.base_slot_count() + self._delta.point_count()

    def build_slot_count(self) -> Int:
        return self.point_count()

    def delta_slot_count(self) -> Int:
        return self._delta.point_count()

    def current_point_count(self) -> Int:
        return len(self._sources)

    def contains_current(self, id: Int) -> Bool:
        return id in self._sources

    def inactive_count(self) -> Int:
        var base_inactive = 0
        if self._base_kind == _OWNED_BASE:
            base_inactive = self._owned_base.inactive_count()
        elif self._base_kind == _MAPPED_BASE:
            base_inactive = (
                self._mapped_base.slot_count()
                - self._mapped_base.live_point_count()
            )
        return base_inactive + self._delta.inactive_count()

    def build_distance_evaluations(self) -> Int:
        var result = self._delta.build_distance_evaluations()
        if self._base_kind == _OWNED_BASE:
            result += self._owned_base.build_distance_evaluations()
        return result

    def mutation_count(self) -> Int:
        return self._delta_mutations

    def has_delta(self) -> Bool:
        # Base-only deletes have no delta slot, but still constitute overlay
        # state that a complete checkpoint must materialize.
        return self._delta_mutations > 0

    def checkpoint_ready(self) -> Bool:
        return self._base_kind == _OWNED_BASE and not self.has_delta()

    def checkpoint_base(
        ref self,
    ) raises -> ref[origin_of(self._owned_base)] HnswIndex:
        """Borrow the complete owned base accepted by durable codecs."""
        if not self.checkpoint_ready():
            raise Error("segmented HNSW has no complete owned checkpoint base")
        return self._owned_base

    def needs_rebuild(self) -> Bool:
        return (
            self._delta_mutations >= self.config.delta_max_points
            or self._delta.needs_rebuild()
        )

    def last_search_stats(self) -> HnswSearchStats:
        var result = HnswSearchStats()
        result.requested_ef = self._last_stats.requested_ef
        result.effective_ef = self._last_stats.effective_ef
        result.widening_rounds = self._last_stats.widening_rounds
        result.upper_visited = self._last_stats.upper_visited
        result.base_visited = self._last_stats.base_visited
        result.distance_evaluations = self._last_stats.distance_evaluations
        result.retained_candidates = self._last_stats.retained_candidates
        result.reranked_candidates = self._last_stats.reranked_candidates
        result.filtered_rejections = self._last_stats.filtered_rejections
        result.inactive_rejections = self._last_stats.inactive_rejections
        result.base_candidates = self._last_stats.base_candidates
        result.delta_candidates = self._last_stats.delta_candidates
        result.backend_name = self._last_stats.backend_name.copy()
        result.metric_name = self._last_stats.metric_name.copy()
        result.scalar_name = self._last_stats.scalar_name.copy()
        result.storage_name = self._last_stats.storage_name.copy()
        result.fallback_reason = self._last_stats.fallback_reason.copy()
        return result^

    def validate_structure(self) raises:
        if self._base_kind == _OWNED_BASE:
            self._owned_base.validate_structure()
        elif self._base_kind == _MAPPED_BASE:
            self._mapped_base.validate_structure()
        self.validate_overlay()

    def validate_overlay(self) raises:
        """Validate delta and source bindings without rescanning frozen base."""
        self._validate_identity()
        self._delta.validate_structure()
        for entry in self._sources.items():
            if entry.value == _DELTA_SOURCE:
                if not Bool(self._delta.graph.current_slot(entry.key)):
                    raise Error("segmented HNSW delta source is not current")
            elif (
                entry.key not in self._base_slots
                or self._base_slots[entry.key] != entry.value
            ):
                raise Error("segmented HNSW base source is inconsistent")
        for slot_index in range(self._delta.graph.slot_count()):
            var slot = UInt32(slot_index)
            if not self._delta.graph.is_current(slot):
                continue
            var id = self._delta.graph.id_at(slot)
            if id not in self._sources or self._sources[id] != _DELTA_SOURCE:
                raise Error("segmented HNSW current delta slot has no source")

    def promote_delta_base(mut self) raises:
        """Adopt a delta-only graph as the first immutable owned base."""
        if self._base_kind != _NO_BASE:
            raise Error("segmented HNSW already has a base")
        self._delta.validate_structure()
        var identity = self.config.copy()
        var replacement = HnswIndex(identity)
        self._owned_base = self._delta^
        self._delta = replacement^
        self._base_kind = _OWNED_BASE
        self._sources = Dict[Int, Int]()
        self._base_slots = Dict[Int, Int]()
        self._index_owned_base_sources()
        self._delta_mutations = 0

    def replace_owned_base(mut self, var base: HnswIndex) raises:
        """Install one explicit fully materialized checkpoint base."""
        if base.config != self.config:
            raise Error("segmented HNSW replacement config mismatch")
        base.validate_structure()
        self._mapped_base.close()
        self._owned_base = base^
        self._delta = HnswIndex(self.config)
        self._base_kind = _OWNED_BASE
        self._sources = Dict[Int, Int]()
        self._base_slots = Dict[Int, Int]()
        self._index_owned_base_sources()
        self._delta_mutations = 0

    def upsert(mut self, id: Int, values: List[Float32]) raises:
        self._validate_identity()
        self._delta.upsert(id, values)
        self._sources[id] = _DELTA_SOURCE
        self._record_mutation()

    def delete(mut self, id: Int) raises -> Bool:
        self._validate_identity()
        if id not in self._sources:
            return False
        if self._sources[id] == _DELTA_SOURCE:
            if not self._delta.delete(id):
                return False
        _ = self._sources.pop(id)
        self._record_mutation()
        return True

    def search(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        memtable: MemTable,
    ) raises -> List[SearchResult]:
        self._validate_identity()
        var candidates = self._collect_candidates(query, k, ef_search)
        return self._rerank(query, k, candidates^, memtable)

    def search_allowed(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        max_ef: Int,
        allowed: HnswEligibility,
        memtable: MemTable,
    ) raises -> List[SearchResult]:
        self._validate_identity()
        if max_ef <= 0 or ef_search > max_ef:
            raise Error("segmented HNSW widening range is invalid")
        allowed.validate(memtable.slot_count())
        var candidates = self._collect_candidates(query, k, max_ef)
        var filtered = List[Int](capacity=len(candidates))
        for id in candidates:
            if allowed.allows(id):
                filtered.append(id)
            else:
                self._last_stats.filtered_rejections += 1
        return self._rerank_allowed(query, k, filtered^, memtable, allowed)

    def _collect_candidates(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[Int]:
        if k <= 0:
            raise Error("segmented HNSW k must be positive")
        if ef_search <= 0 or ef_search > self.config.max_ef_search:
            raise Error("segmented HNSW ef is outside configured bounds")
        var per_source = k
        if ef_search > per_source:
            per_source = ef_search
        if per_source > self.config.max_ef_search:
            per_source = self.config.max_ef_search

        var stats = HnswSearchStats()
        stats.requested_ef = ef_search
        stats.effective_ef = per_source
        stats.backend_name = self._metric.backend_name()
        stats.metric_name = self._metric.metric_name()
        stats.scalar_name = self._metric.scalar_name()
        stats.storage_name = "segmented-f32"
        var merged = List[Int]()
        var seen = Dict[Int, Bool]()

        var base_live = self._base_live_count()
        if base_live > 0:
            var wanted = per_source
            if wanted > base_live:
                wanted = base_live
            var base_results: List[SearchResult]
            if self._base_kind == _MAPPED_BASE:
                base_results = self._mapped_base.search(
                    query, wanted, ef_search=per_source
                )
                _accumulate_search_stats(
                    stats, self._mapped_base.last_search_stats()
                )
            else:
                base_results = self._owned_base.search(
                    query, wanted, ef_search=per_source
                )
                _accumulate_search_stats(
                    stats, self._owned_base.last_search_stats
                )
            for candidate in base_results:
                if not self._is_current_base_id(candidate.id):
                    stats.inactive_rejections += 1
                    continue
                stats.base_candidates += 1
                if candidate.id not in seen:
                    seen[candidate.id] = True
                    merged.append(candidate.id)

        var delta_live = (
            self._delta.point_count() - self._delta.inactive_count()
        )
        if delta_live > 0:
            var wanted = per_source
            if wanted > delta_live:
                wanted = delta_live
            var delta_results = self._delta.search(
                query, wanted, ef_search=per_source
            )
            _accumulate_search_stats(stats, self._delta.last_search_stats)
            for candidate in delta_results:
                if (
                    candidate.id not in self._sources
                    or self._sources[candidate.id] != _DELTA_SOURCE
                ):
                    stats.inactive_rejections += 1
                    continue
                stats.delta_candidates += 1
                if candidate.id not in seen:
                    seen[candidate.id] = True
                    merged.append(candidate.id)

        stats.retained_candidates = len(merged)
        self._last_stats = stats^
        return merged^

    def _rerank(
        mut self,
        query: List[Float32],
        k: Int,
        candidates: List[Int],
        memtable: MemTable,
    ) raises -> List[SearchResult]:
        var candidate_ids = Dict[Int, Bool]()
        for id in candidates:
            candidate_ids[id] = True
        var target = k
        if target > len(self._sources):
            target = len(self._sources)
        return self._rerank_impl(
            query, target, candidate_ids^, memtable, False
        )

    def _rerank_allowed(
        mut self,
        query: List[Float32],
        k: Int,
        candidates: List[Int],
        memtable: MemTable,
        allowed: HnswEligibility,
    ) raises -> List[SearchResult]:
        var candidate_ids = Dict[Int, Bool]()
        for id in candidates:
            candidate_ids[id] = True
        var eligible = 0
        for ordinal in range(memtable.slot_count()):
            if memtable.is_live_at(ordinal) and allowed.allows(
                memtable.id_at(ordinal)
            ):
                eligible += 1
        var target = k
        if target > eligible:
            target = eligible
        if target == 0:
            self._last_stats.reranked_candidates = 0
            self._last_stats.retained_candidates = 0
            return List[SearchResult]()

        var exact_fallback = len(candidate_ids) < target
        if exact_fallback:
            # Candidate exhaustion is expected with source invalidation, but
            # never use exact fallback to conceal a structurally corrupt graph.
            self.validate_structure()
        var topk = BoundedTopK(target, smaller_is_better=True)
        var scored = 0
        for ordinal in range(memtable.slot_count()):
            if not memtable.is_live_at(ordinal):
                continue
            var id = memtable.id_at(ordinal)
            if not allowed.allows(id):
                continue
            if not exact_fallback and id not in candidate_ids:
                continue
            ref entry = memtable.entry_ref_at(ordinal)
            topk.offer(id, self._metric.canonical(query, entry.values))
            scored += 1
        self._last_stats.reranked_candidates = scored
        if exact_fallback:
            self._last_stats.fallback_reason = "filtered_ann_exhausted"
        return self._finish_topk(topk^)

    def _rerank_impl(
        mut self,
        query: List[Float32],
        target: Int,
        var candidate_ids: Dict[Int, Bool],
        memtable: MemTable,
        exact_fallback: Bool,
    ) raises -> List[SearchResult]:
        if target == 0:
            self._last_stats.reranked_candidates = 0
            self._last_stats.retained_candidates = 0
            return List[SearchResult]()
        var use_exact = exact_fallback or len(candidate_ids) < target
        if use_exact:
            self.validate_structure()
        var topk = BoundedTopK(target, smaller_is_better=True)
        var scored = 0
        for ordinal in range(memtable.slot_count()):
            if not memtable.is_live_at(ordinal):
                continue
            var id = memtable.id_at(ordinal)
            if id not in self._sources:
                continue
            if not use_exact and id not in candidate_ids:
                continue
            ref entry = memtable.entry_ref_at(ordinal)
            topk.offer(id, self._metric.canonical(query, entry.values))
            scored += 1
        self._last_stats.reranked_candidates = scored
        if use_exact:
            self._last_stats.fallback_reason = "segmented_ann_exhausted"
        return self._finish_topk(topk^)

    def _finish_topk(
        mut self, var topk: BoundedTopK
    ) -> List[SearchResult]:
        var retained = topk.sorted_entries()
        var result = List[SearchResult](capacity=len(retained))
        for entry in retained:
            result.append(
                SearchResult(entry.id, self._metric.public_score(entry.score))
            )
        self._last_stats.retained_candidates = len(result)
        return result^

    def _base_live_count(self) -> Int:
        if self._base_kind == _MAPPED_BASE:
            return self._mapped_base.live_point_count()
        if self._base_kind == _OWNED_BASE:
            return (
                self._owned_base.point_count()
                - self._owned_base.inactive_count()
            )
        return 0

    def _is_current_base_id(self, id: Int) raises -> Bool:
        return (
            id in self._sources
            and id in self._base_slots
            and self._sources[id] == self._base_slots[id]
        )

    def _index_owned_base_sources(mut self) raises:
        for slot_index in range(self._owned_base.graph.slot_count()):
            var slot = UInt32(slot_index)
            if not self._owned_base.graph.is_current(slot):
                continue
            var id = self._owned_base.graph.id_at(slot)
            var source = slot_index + 1
            self._base_slots[id] = source
            self._sources[id] = source

    def _index_mapped_base_sources(mut self) raises:
        for slot_index in range(self._mapped_base.slot_count()):
            var slot = UInt32(slot_index)
            if not self._mapped_base.is_current(slot):
                continue
            var id = self._mapped_base.id_at(slot)
            var source = slot_index + 1
            self._base_slots[id] = source
            self._sources[id] = source

    def _record_mutation(mut self):
        if self._delta_mutations < self.config.delta_max_points:
            self._delta_mutations += 1

    def _validate_identity(self) raises:
        self.config.validate()
        if self._delta.config != self.config:
            raise Error("segmented HNSW delta config diverged from identity")
        if self._base_kind == _OWNED_BASE:
            if self._owned_base.config != self.config:
                raise Error("segmented HNSW owned base config mismatch")
        elif self._base_kind == _MAPPED_BASE:
            if self._mapped_base.config() != self.config:
                raise Error("segmented HNSW mapped base config mismatch")
