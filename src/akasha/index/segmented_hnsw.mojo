from akasha.common.config import CollectionConfig
from akasha.compute.dispatch import (
    DISTANCE_DOT_F32,
    DISTANCE_L2_F32,
    DISTANCE_COSINE_F32,
    DISTANCE_DOT_BF16,
    DISTANCE_L2_BF16,
    DISTANCE_COSINE_BF16,
    DISTANCE_DOT_F16,
    DISTANCE_L2_F16,
    DISTANCE_COSINE_F16,
    DISTANCE_DOT_I8,
    DISTANCE_COSINE_I8,
    DISTANCE_DISPATCH_PUBLIC_BOUNDARY,
    DistanceBackend,
    DistanceDispatchCounters,
    record_distance_dispatch,
    select_distance_backend,
)
from akasha.compute.topk import BoundedTopK
from akasha.index.flat import authoritative_f32_score, SearchResult
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import (
    HnswEligibility,
    HnswIdOrdinalLookup,
    HnswResultAdmission,
)
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.hnsw_view import HnswGraphView
from akasha.storage.memtable import MemTable
from std.collections import Dict
from std.memory import ArcPointer


comptime _NO_BASE = 0
comptime _OWNED_BASE = 1
comptime _MAPPED_BASE = 2
comptime _DELTA_SOURCE = -1


struct _CurrentSourceState:
    var sources: Dict[Int, Int]
    var base_count: Int
    var delta_count: Int

    def __init__(out self):
        self.sources = Dict[Int, Int]()
        self.base_count = 0
        self.delta_count = 0


struct _CurrentSourceLookup(Copyable, Movable):
    """The one Arc-shared authoritative ID-to-segment source map."""

    var _state: ArcPointer[_CurrentSourceState]

    def __init__(out self):
        self._state = ArcPointer(_CurrentSourceState())

    def entry_count(self) -> Int:
        return len(self._state[].sources)

    def base_count(self) -> Int:
        return self._state[].base_count

    def delta_count(self) -> Int:
        return self._state[].delta_count

    def contains(self, id: Int) -> Bool:
        return id in self._state[].sources

    def source_for(self, id: Int) raises -> Int:
        if id in self._state[].sources:
            return self._state[].sources[id]
        return 0

    def set_base(mut self, id: Int, source: Int) raises:
        if source <= 0:
            raise Error("HNSW base source must encode a graph slot")
        self._replace(id, source)

    def set_delta(mut self, id: Int) raises:
        self._replace(id, _DELTA_SOURCE)

    def remove(mut self, id: Int) raises -> Bool:
        if id not in self._state[].sources:
            return False
        var source = self._state[].sources[id]
        self._decrement(source)
        _ = self._state[].sources.pop(id)
        return True

    def _replace(mut self, id: Int, source: Int) raises:
        if id in self._state[].sources:
            self._decrement(self._state[].sources[id])
        self._state[].sources[id] = source
        if source == _DELTA_SOURCE:
            self._state[].delta_count += 1
        else:
            self._state[].base_count += 1

    def _decrement(mut self, source: Int) raises:
        if source == _DELTA_SOURCE:
            if self._state[].delta_count <= 0:
                raise Error("HNSW delta source count underflow")
            self._state[].delta_count -= 1
        else:
            if self._state[].base_count <= 0:
                raise Error("HNSW base source count underflow")
            self._state[].base_count -= 1


struct _SourceAdmission(Copyable, HnswResultAdmission, Movable):
    var _sources: _CurrentSourceLookup
    var _delta: Bool

    def __init__(out self, sources: _CurrentSourceLookup, delta: Bool):
        self._sources = sources.copy()
        self._delta = delta

    def is_allow_all(self) -> Bool:
        return False

    def validate(self, slot_count: Int) raises:
        if slot_count < 0:
            raise Error("HNSW admission slot count cannot be negative")

    def _allows_item(self, slot: UInt32, id: Int) raises -> Bool:
        var source = self._sources.source_for(id)
        if self._delta:
            return source == _DELTA_SOURCE
        return source == Int(slot) + 1


struct _FilteredSourceAdmission(Copyable, HnswResultAdmission, Movable):
    var _source: _SourceAdmission
    var _eligibility: HnswEligibility

    def __init__(
        out self,
        sources: _CurrentSourceLookup,
        delta: Bool,
        eligibility: HnswEligibility,
    ):
        self._source = _SourceAdmission(sources, delta)
        self._eligibility = eligibility.copy()

    def is_allow_all(self) -> Bool:
        return False

    def validate(self, slot_count: Int) raises:
        self._source.validate(slot_count)
        self._eligibility.validate(slot_count)

    def _allows_item(self, slot: UInt32, id: Int) raises -> Bool:
        return self._source._allows_item(
            slot, id
        ) and self._eligibility._allows_item(slot, id)


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
    var distance_backend: DistanceBackend
    var _distance_dispatch_counters: DistanceDispatchCounters
    var _base_kind: Int
    var _owned_base: HnswIndex
    var _mapped_base: HnswGraphView
    var _delta: HnswIndex
    var _sources: _CurrentSourceLookup
    var _base_stale_count: Int
    var _delta_mutations: Int
    var _last_stats: HnswSearchStats
    var _last_candidate_merge_insertions: Int
    var _last_rerank_ordinal_lookups: Int
    var _last_rerank_linear_id_scans: Int
    var _last_search_query_preparations: Int
    var _last_search_upper_descents: Int

    def __init__(out self, config: CollectionConfig) raises:
        config.validate()
        var counters = DistanceDispatchCounters()
        var backend = select_distance_backend(config, counters)
        self.config = config.copy()
        self.distance_backend = backend.copy()
        self._distance_dispatch_counters = counters^
        self._base_kind = _NO_BASE
        self._owned_base = HnswIndex(config, backend)
        self._mapped_base = HnswGraphView(config, backend)
        self._delta = HnswIndex(config, backend)
        self._sources = _CurrentSourceLookup()
        self._base_stale_count = 0
        self._delta_mutations = 0
        self._last_stats = HnswSearchStats()
        self._last_candidate_merge_insertions = 0
        self._last_rerank_ordinal_lookups = 0
        self._last_rerank_linear_id_scans = 0
        self._last_search_query_preparations = 0
        self._last_search_upper_descents = 0

    def __init__(
        out self,
        config: CollectionConfig,
        backend: DistanceBackend,
        counters: DistanceDispatchCounters,
    ) raises:
        """Initialize from one selection already made by an adoption path."""
        config.validate()
        backend.validate_identity(config)
        self.config = config.copy()
        self.distance_backend = backend.copy()
        self._distance_dispatch_counters = counters.copy()
        self._base_kind = _NO_BASE
        self._owned_base = HnswIndex(config, backend)
        self._mapped_base = HnswGraphView(config, backend)
        self._delta = HnswIndex(config, backend)
        self._sources = _CurrentSourceLookup()
        self._base_stale_count = 0
        self._delta_mutations = 0
        self._last_stats = HnswSearchStats()
        self._last_candidate_merge_insertions = 0
        self._last_rerank_ordinal_lookups = 0
        self._last_rerank_linear_id_scans = 0
        self._last_search_query_preparations = 0
        self._last_search_upper_descents = 0

    @staticmethod
    def from_owned(var base: HnswIndex) raises -> SegmentedHnsw:
        base.validate_structure()
        var identity = base.config.copy()
        var counters = DistanceDispatchCounters()
        var backend = select_distance_backend(identity, counters)
        var result = SegmentedHnsw(identity, backend, counters)
        base._bind_distance_backend(backend)
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
        var counters = DistanceDispatchCounters()
        var backend = select_distance_backend(identity, counters)
        var result = SegmentedHnsw(identity, backend, counters)
        base._bind_distance_backend(backend)
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

    def close(mut self):
        """Release a mapped base exactly once; owned bases need no action."""
        self._mapped_base.close()

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
        return self._sources.entry_count()

    def contains_current(self, id: Int) -> Bool:
        return self._sources.contains(id)

    def inactive_count(self) -> Int:
        var base_inactive = 0
        if self._base_kind == _OWNED_BASE:
            base_inactive = self._owned_base.inactive_count()
        elif self._base_kind == _MAPPED_BASE:
            base_inactive = (
                self._mapped_base.slot_count()
                - self._mapped_base.live_point_count()
            )
        return (
            base_inactive
            + self._base_stale_count
            + self._delta.inactive_count()
        )

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
        if (
            self._delta_mutations >= self.config.delta_max_points
            or self._delta.needs_rebuild()
        ):
            return True
        var slots = self.point_count()
        var inactive = self.inactive_count()
        return (
            slots > 0
            and inactive > 0
            and inactive * 100 >= slots * self.config.rebuild_inactive_percent
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

    def last_candidate_merge_insertions(self) -> Int:
        return self._last_candidate_merge_insertions

    def last_rerank_ordinal_lookups(self) -> Int:
        return self._last_rerank_ordinal_lookups

    def last_rerank_linear_id_scans(self) -> Int:
        return self._last_rerank_linear_id_scans

    def last_search_query_preparations(self) -> Int:
        return self._last_search_query_preparations

    def last_search_upper_descents(self) -> Int:
        return self._last_search_upper_descents

    def distance_backend_selection_count(self) -> Int:
        return self._distance_dispatch_counters.selection_count()

    def distance_backend_public_switch_count(self) -> Int:
        return self._distance_dispatch_counters.public_boundary_switch_count()

    def distance_backend_hot_loop_selection_count(self) -> Int:
        return self._distance_dispatch_counters.hot_loop_selection_count()

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
        var observed_base_sources = 0
        var observed_delta_sources = 0
        for entry in self._sources._state[].sources.items():
            if entry.value == _DELTA_SOURCE:
                if not Bool(self._delta.graph.current_slot(entry.key)):
                    raise Error("segmented HNSW delta source is not current")
                observed_delta_sources += 1
            elif not self._base_source_matches(entry.key, entry.value):
                raise Error("segmented HNSW base source is inconsistent")
            else:
                observed_base_sources += 1
        if (
            self._base_live_count() - observed_base_sources
            != self._base_stale_count
        ):
            raise Error("segmented HNSW stale base count is inconsistent")
        if (
            observed_base_sources != self._sources.base_count()
            or observed_delta_sources != self._sources.delta_count()
            or observed_base_sources + observed_delta_sources
            != self._sources.entry_count()
        ):
            raise Error("segmented HNSW cached source counts are inconsistent")
        for slot_index in range(self._delta.graph.slot_count()):
            var slot = UInt32(slot_index)
            if not self._delta.graph.is_current(slot):
                continue
            var id = self._delta.graph.id_at(slot)
            if self._sources.source_for(id) != _DELTA_SOURCE:
                raise Error("segmented HNSW current delta slot has no source")

    def promote_delta_base(mut self) raises:
        """Adopt a delta-only graph as the first immutable owned base."""
        if self._base_kind != _NO_BASE and self.base_slot_count() != 0:
            raise Error("segmented HNSW already has a non-empty base")
        self._delta.validate_structure()
        var identity = self.config.copy()
        var replacement = HnswIndex(identity, self.distance_backend)
        self._mapped_base.close()
        self._owned_base = self._delta^
        self._delta = replacement^
        self._base_kind = _OWNED_BASE
        self._sources = _CurrentSourceLookup()
        self._index_owned_base_sources()
        self._base_stale_count = 0
        self._delta_mutations = 0

    def replace_owned_base(mut self, var base: HnswIndex) raises:
        """Install one explicit fully materialized checkpoint base."""
        if base.config != self.config:
            raise Error("segmented HNSW replacement config mismatch")
        base.validate_structure()
        base._bind_distance_backend(self.distance_backend)
        self._mapped_base.close()
        self._owned_base = base^
        self._delta = HnswIndex(self.config, self.distance_backend)
        self._base_kind = _OWNED_BASE
        self._sources = _CurrentSourceLookup()
        self._index_owned_base_sources()
        self._base_stale_count = 0
        self._delta_mutations = 0

    def upsert(mut self, id: Int, values: List[Float32]) raises:
        self._validate_identity()
        record_distance_dispatch(
            self._distance_dispatch_counters,
            DISTANCE_DISPATCH_PUBLIC_BOUNDARY,
        )
        var replaced_base = self._sources.source_for(id) > 0
        var tag = self.distance_backend.tag()
        if tag == DISTANCE_DOT_F32:
            self._delta._upsert_backend[DISTANCE_DOT_F32](id, values)
        elif tag == DISTANCE_L2_F32:
            self._delta._upsert_backend[DISTANCE_L2_F32](id, values)
        elif tag == DISTANCE_COSINE_F32:
            self._delta._upsert_backend[DISTANCE_COSINE_F32](id, values)
        elif tag == DISTANCE_DOT_BF16:
            self._delta._upsert_backend[DISTANCE_DOT_BF16](id, values)
        elif tag == DISTANCE_L2_BF16:
            self._delta._upsert_backend[DISTANCE_L2_BF16](id, values)
        elif tag == DISTANCE_COSINE_BF16:
            self._delta._upsert_backend[DISTANCE_COSINE_BF16](id, values)
        elif tag == DISTANCE_DOT_F16:
            self._delta._upsert_backend[DISTANCE_DOT_F16](id, values)
        elif tag == DISTANCE_L2_F16:
            self._delta._upsert_backend[DISTANCE_L2_F16](id, values)
        elif tag == DISTANCE_COSINE_F16:
            self._delta._upsert_backend[DISTANCE_COSINE_F16](id, values)
        elif tag == DISTANCE_DOT_I8:
            self._delta._upsert_backend[DISTANCE_DOT_I8](id, values)
        else:
            self._delta._upsert_backend[DISTANCE_COSINE_I8](id, values)
        if replaced_base:
            self._base_stale_count += 1
        self._sources.set_delta(id)
        self._record_mutation()

    def delete(mut self, id: Int) raises -> Bool:
        self._validate_identity()
        if not self._sources.contains(id):
            return False
        var source = self._sources.source_for(id)
        if source == _DELTA_SOURCE:
            if not self._delta.delete(id):
                return False
        else:
            self._base_stale_count += 1
        _ = self._sources.remove(id)
        self._record_mutation()
        return True

    def search(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        memtable: MemTable,
        lookup: HnswIdOrdinalLookup,
    ) raises -> List[SearchResult]:
        var candidates = self._search_candidates(query, k, ef_search)
        return self._rerank(query, k, candidates^, memtable, lookup)

    def _search_candidates(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
    ) raises -> List[Int]:
        self._validate_identity()
        record_distance_dispatch(
            self._distance_dispatch_counters,
            DISTANCE_DISPATCH_PUBLIC_BOUNDARY,
        )
        var tag = self.distance_backend.tag()
        var candidates: List[Int]
        if tag == DISTANCE_DOT_F32:
            candidates = self._collect_candidates[DISTANCE_DOT_F32](
                query, k, ef_search
            )
        elif tag == DISTANCE_L2_F32:
            candidates = self._collect_candidates[DISTANCE_L2_F32](
                query, k, ef_search
            )
        elif tag == DISTANCE_COSINE_F32:
            candidates = self._collect_candidates[DISTANCE_COSINE_F32](
                query, k, ef_search
            )
        elif tag == DISTANCE_DOT_BF16:
            candidates = self._collect_candidates[DISTANCE_DOT_BF16](
                query, k, ef_search
            )
        elif tag == DISTANCE_L2_BF16:
            candidates = self._collect_candidates[DISTANCE_L2_BF16](
                query, k, ef_search
            )
        elif tag == DISTANCE_COSINE_BF16:
            candidates = self._collect_candidates[DISTANCE_COSINE_BF16](
                query, k, ef_search
            )
        elif tag == DISTANCE_DOT_F16:
            candidates = self._collect_candidates[DISTANCE_DOT_F16](
                query, k, ef_search
            )
        elif tag == DISTANCE_L2_F16:
            candidates = self._collect_candidates[DISTANCE_L2_F16](
                query, k, ef_search
            )
        elif tag == DISTANCE_COSINE_F16:
            candidates = self._collect_candidates[DISTANCE_COSINE_F16](
                query, k, ef_search
            )
        elif tag == DISTANCE_DOT_I8:
            candidates = self._collect_candidates[DISTANCE_DOT_I8](
                query, k, ef_search
            )
        else:
            candidates = self._collect_candidates[DISTANCE_COSINE_I8](
                query, k, ef_search
            )
        return candidates^

    def search_allowed(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        max_ef: Int,
        allowed: HnswEligibility,
        memtable: MemTable,
        lookup: HnswIdOrdinalLookup,
    ) raises -> List[SearchResult]:
        var candidates = self._search_allowed_candidates(
            query, k, ef_search, max_ef, allowed, memtable
        )
        return self._rerank_allowed(
            query, k, candidates^, memtable, lookup, allowed
        )

    def _search_allowed_candidates(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        max_ef: Int,
        allowed: HnswEligibility,
        memtable: MemTable,
    ) raises -> List[Int]:
        self._validate_identity()
        if max_ef <= 0 or ef_search > max_ef:
            raise Error("segmented HNSW widening range is invalid")
        allowed.validate(memtable.slot_count())
        record_distance_dispatch(
            self._distance_dispatch_counters,
            DISTANCE_DISPATCH_PUBLIC_BOUNDARY,
        )
        var tag = self.distance_backend.tag()
        var candidates: List[Int]
        if tag == DISTANCE_DOT_F32:
            candidates = self._collect_allowed_candidates[DISTANCE_DOT_F32](
                query, k, ef_search, max_ef, allowed
            )
        elif tag == DISTANCE_L2_F32:
            candidates = self._collect_allowed_candidates[DISTANCE_L2_F32](
                query, k, ef_search, max_ef, allowed
            )
        elif tag == DISTANCE_COSINE_F32:
            candidates = self._collect_allowed_candidates[DISTANCE_COSINE_F32](
                query, k, ef_search, max_ef, allowed
            )
        elif tag == DISTANCE_DOT_BF16:
            candidates = self._collect_allowed_candidates[DISTANCE_DOT_BF16](
                query, k, ef_search, max_ef, allowed
            )
        elif tag == DISTANCE_L2_BF16:
            candidates = self._collect_allowed_candidates[DISTANCE_L2_BF16](
                query, k, ef_search, max_ef, allowed
            )
        elif tag == DISTANCE_COSINE_BF16:
            candidates = self._collect_allowed_candidates[DISTANCE_COSINE_BF16](
                query, k, ef_search, max_ef, allowed
            )
        elif tag == DISTANCE_DOT_F16:
            candidates = self._collect_allowed_candidates[DISTANCE_DOT_F16](
                query, k, ef_search, max_ef, allowed
            )
        elif tag == DISTANCE_L2_F16:
            candidates = self._collect_allowed_candidates[DISTANCE_L2_F16](
                query, k, ef_search, max_ef, allowed
            )
        elif tag == DISTANCE_COSINE_F16:
            candidates = self._collect_allowed_candidates[DISTANCE_COSINE_F16](
                query, k, ef_search, max_ef, allowed
            )
        elif tag == DISTANCE_DOT_I8:
            candidates = self._collect_allowed_candidates[DISTANCE_DOT_I8](
                query, k, ef_search, max_ef, allowed
            )
        else:
            candidates = self._collect_allowed_candidates[DISTANCE_COSINE_I8](
                query, k, ef_search, max_ef, allowed
            )
        return candidates^

    def _collect_candidates[
        backend_tag: Int
    ](mut self, query: List[Float32], k: Int, ef_search: Int) raises -> List[
        Int
    ]:
        if k <= 0:
            raise Error("segmented HNSW k must be positive")
        if ef_search <= 0 or ef_search > self.config.max_ef_search:
            raise Error("segmented HNSW ef is outside configured bounds")
        var per_source = k
        if ef_search > per_source:
            per_source = ef_search
        if per_source > self.config.max_ef_search:
            per_source = self.config.max_ef_search
        var prepared = self.distance_backend.prepare_query(query)

        var stats = HnswSearchStats()
        stats.requested_ef = 0
        stats.effective_ef = 0
        stats.backend_name = self.distance_backend.backend_name()
        stats.metric_name = self.distance_backend.metric_name()
        stats.scalar_name = self.distance_backend.scalar_name()
        stats.storage_name = String("segmented-", self.config.scalar_name())
        var merged = List[Int]()
        var seen = Dict[Int, Bool]()
        self._last_candidate_merge_insertions = 0
        self._last_search_query_preparations = 1
        self._last_search_upper_descents = 0

        var base_live = self._sources.base_count()
        var delta_live = self._sources.delta_count()
        var single_source = base_live == 0 or delta_live == 0
        if base_live > 0:
            var base_admission = _SourceAdmission(self._sources, False)
            var base_results: List[SearchResult]
            if self._base_kind == _MAPPED_BASE:
                base_results = self._mapped_base._search_prepared_backend[
                    backend_tag=backend_tag
                ](
                    prepared,
                    per_source,
                    ef_search,
                    self.config.max_ef_search,
                    base_live,
                    base_admission,
                )
                var source_stats = self._mapped_base.last_search_stats()
                self._accumulate_source_stats(stats, source_stats)
                self._last_search_upper_descents += (
                    self._mapped_base.last_search_upper_descents()
                )
            else:
                base_results = (
                    self._owned_base._search_admitted_prepared_backend[
                        backend_tag=backend_tag
                    ](
                        prepared,
                        per_source,
                        ef_search,
                        self.config.max_ef_search,
                        base_live,
                        base_admission,
                    )
                )
                self._accumulate_source_stats(
                    stats, self._owned_base.last_search_stats
                )
                self._last_search_upper_descents += (
                    self._owned_base.last_search_upper_descents()
                )
            for candidate in base_results:
                stats.base_candidates += 1
                if single_source:
                    merged.append(candidate.id)
                elif candidate.id not in seen:
                    seen[candidate.id] = True
                    merged.append(candidate.id)
                    self._last_candidate_merge_insertions += 1

        if delta_live > 0:
            var delta_admission = _SourceAdmission(self._sources, True)
            var delta_results = self._delta._search_admitted_prepared_backend[
                backend_tag=backend_tag
            ](
                prepared,
                per_source,
                ef_search,
                self.config.max_ef_search,
                delta_live,
                delta_admission,
            )
            self._accumulate_source_stats(stats, self._delta.last_search_stats)
            self._last_search_upper_descents += (
                self._delta.last_search_upper_descents()
            )
            for candidate in delta_results:
                stats.delta_candidates += 1
                if single_source:
                    merged.append(candidate.id)
                elif candidate.id not in seen:
                    seen[candidate.id] = True
                    merged.append(candidate.id)
                    self._last_candidate_merge_insertions += 1

        stats.retained_candidates = len(merged)
        self._last_stats = stats^
        return merged^

    def _collect_allowed_candidates[
        backend_tag: Int
    ](
        mut self,
        query: List[Float32],
        k: Int,
        initial_ef: Int,
        max_ef: Int,
        allowed: HnswEligibility,
    ) raises -> List[Int]:
        if k <= 0:
            raise Error("segmented HNSW k must be positive")
        if (
            initial_ef <= 0
            or max_ef <= 0
            or initial_ef > max_ef
            or max_ef > self.config.max_ef_search
        ):
            raise Error("segmented HNSW widening range is invalid")
        var prepared = self.distance_backend.prepare_query(query)
        var stats = HnswSearchStats()
        # Aggregate the effective breadth actually searched by each non-empty
        # source; a tiny source may cap an arbitrarily large requested ef.
        stats.requested_ef = 0
        stats.effective_ef = 0
        stats.backend_name = self.distance_backend.backend_name()
        stats.metric_name = self.distance_backend.metric_name()
        stats.scalar_name = self.distance_backend.scalar_name()
        stats.storage_name = String("segmented-", self.config.scalar_name())
        var merged = List[Int]()
        var seen = Dict[Int, Bool]()
        self._last_candidate_merge_insertions = 0
        self._last_search_query_preparations = 1
        self._last_search_upper_descents = 0

        var base_live = self._sources.base_count()
        var delta_live = self._sources.delta_count()
        var single_source = base_live == 0 or delta_live == 0
        if base_live > 0:
            var base_admission = _FilteredSourceAdmission(
                self._sources, False, allowed
            )
            var base_results: List[SearchResult]
            if self._base_kind == _MAPPED_BASE:
                base_results = self._mapped_base._search_prepared_backend[
                    backend_tag=backend_tag
                ](
                    prepared,
                    k,
                    initial_ef,
                    max_ef,
                    base_live,
                    base_admission,
                )
                var source_stats = self._mapped_base.last_search_stats()
                self._accumulate_source_stats(stats, source_stats)
                self._last_search_upper_descents += (
                    self._mapped_base.last_search_upper_descents()
                )
            else:
                base_results = (
                    self._owned_base._search_admitted_prepared_backend[
                        backend_tag=backend_tag
                    ](
                        prepared,
                        k,
                        initial_ef,
                        max_ef,
                        base_live,
                        base_admission,
                    )
                )
                self._accumulate_source_stats(
                    stats, self._owned_base.last_search_stats
                )
                self._last_search_upper_descents += (
                    self._owned_base.last_search_upper_descents()
                )
            for candidate in base_results:
                stats.base_candidates += 1
                if single_source:
                    merged.append(candidate.id)
                elif candidate.id not in seen:
                    seen[candidate.id] = True
                    merged.append(candidate.id)
                    self._last_candidate_merge_insertions += 1

        if delta_live > 0:
            var delta_admission = _FilteredSourceAdmission(
                self._sources, True, allowed
            )
            var delta_results = self._delta._search_admitted_prepared_backend[
                backend_tag=backend_tag
            ](
                prepared,
                k,
                initial_ef,
                max_ef,
                delta_live,
                delta_admission,
            )
            self._accumulate_source_stats(stats, self._delta.last_search_stats)
            self._last_search_upper_descents += (
                self._delta.last_search_upper_descents()
            )
            for candidate in delta_results:
                stats.delta_candidates += 1
                if single_source:
                    merged.append(candidate.id)
                elif candidate.id not in seen:
                    seen[candidate.id] = True
                    merged.append(candidate.id)
                    self._last_candidate_merge_insertions += 1

        var target = k
        if target > allowed.eligible_count():
            target = allowed.eligible_count()
        if len(merged) < target and stats.fallback_reason == "":
            stats.fallback_reason = "filtered_ann_exhausted"
        stats.retained_candidates = len(merged)
        self._last_stats = stats^
        return merged^

    def _rerank(
        mut self,
        query: List[Float32],
        k: Int,
        var candidates: List[Int],
        memtable: MemTable,
        lookup: HnswIdOrdinalLookup,
    ) raises -> List[SearchResult]:
        var target = k
        if target > self._sources.entry_count():
            target = self._sources.entry_count()
        if len(candidates) < target:
            self.validate_structure()
            self._last_stats.fallback_reason = "segmented_ann_exhausted"
            return self._exact_search(query, target, memtable, lookup)
        return self._rerank_candidates(
            query, target, candidates^, memtable, lookup
        )

    def _exact_search(
        mut self,
        query: List[Float32],
        target: Int,
        memtable: MemTable,
        lookup: HnswIdOrdinalLookup,
    ) raises -> List[SearchResult]:
        """Complete only a globally exhausted segmented unfiltered query."""
        self._reset_rerank_counters(memtable, lookup)
        var topk = BoundedTopK(
            target,
            smaller_is_better=Int(self.config.ann_metric.tag()) == 1,
        )
        var scored = 0
        for ordinal in range(memtable.slot_count()):
            if not memtable.is_live_at(ordinal):
                continue
            var id = memtable.id_at(ordinal)
            if not self._sources.contains(id):
                raise Error("live MemTable ID has no current HNSW source")
            if lookup.ordinal_for(id) != ordinal:
                raise Error("HNSW ID lookup does not match MemTable ordinal")
            self._last_rerank_ordinal_lookups += 1
            ref entry = memtable.entry_ref_at(ordinal)
            topk.offer(
                id,
                authoritative_f32_score(
                    Int(self.config.ann_metric.tag()), query, entry.values
                ),
            )
            scored += 1
        self._last_stats.reranked_candidates = scored
        return self._finish_topk(topk^)

    def _rerank_allowed(
        mut self,
        query: List[Float32],
        k: Int,
        var candidates: List[Int],
        memtable: MemTable,
        lookup: HnswIdOrdinalLookup,
        allowed: HnswEligibility,
    ) raises -> List[SearchResult]:
        var target = k
        if target > allowed.eligible_count():
            target = allowed.eligible_count()
        if self._last_stats.fallback_reason != "":
            self.validate_structure()
            return self._exact_search_allowed(
                query, target, memtable, lookup, allowed
            )
        return self._rerank_allowed_candidates(
            query, target, candidates^, memtable, lookup, allowed
        )

    def _exact_search_allowed(
        mut self,
        query: List[Float32],
        target: Int,
        memtable: MemTable,
        lookup: HnswIdOrdinalLookup,
        allowed: HnswEligibility,
    ) raises -> List[SearchResult]:
        """Complete only a globally exhausted segmented filtered query."""
        self._reset_rerank_counters(memtable, lookup)
        if target == 0:
            self._last_stats.reranked_candidates = 0
            self._last_stats.retained_candidates = 0
            return List[SearchResult]()
        var topk = BoundedTopK(
            target,
            smaller_is_better=Int(self.config.ann_metric.tag()) == 1,
        )
        var scored = 0
        for ordinal in range(memtable.slot_count()):
            if not memtable.is_live_at(ordinal):
                continue
            var id = memtable.id_at(ordinal)
            if not self._sources.contains(id):
                raise Error("live MemTable ID has no current HNSW source")
            if not allowed.allows(id):
                continue
            if lookup.ordinal_for(id) != ordinal:
                raise Error("HNSW ID lookup does not match MemTable ordinal")
            self._last_rerank_ordinal_lookups += 1
            ref entry = memtable.entry_ref_at(ordinal)
            topk.offer(
                id,
                authoritative_f32_score(
                    Int(self.config.ann_metric.tag()), query, entry.values
                ),
            )
            scored += 1
        self._last_stats.reranked_candidates = scored
        return self._finish_topk(topk^)

    def _rerank_candidates(
        mut self,
        query: List[Float32],
        target: Int,
        candidates: List[Int],
        memtable: MemTable,
        lookup: HnswIdOrdinalLookup,
    ) raises -> List[SearchResult]:
        self._reset_rerank_counters(memtable, lookup)
        if target == 0:
            self._last_stats.reranked_candidates = 0
            self._last_stats.retained_candidates = 0
            return List[SearchResult]()
        var topk = BoundedTopK(
            target,
            smaller_is_better=Int(self.config.ann_metric.tag()) == 1,
        )
        var scored = 0
        for id in candidates:
            var ordinal = lookup.ordinal_for(id)
            self._last_rerank_ordinal_lookups += 1
            self._validate_authoritative_ordinal(id, ordinal, memtable)
            ref entry = memtable.entry_ref_at(ordinal)
            topk.offer(
                id,
                authoritative_f32_score(
                    Int(self.config.ann_metric.tag()), query, entry.values
                ),
            )
            scored += 1
        self._last_stats.reranked_candidates = scored
        if scored < target:
            self.validate_structure()
            self._last_stats.fallback_reason = "segmented_ann_exhausted"
        return self._finish_topk(topk^)

    def _rerank_allowed_candidates(
        mut self,
        query: List[Float32],
        target: Int,
        candidates: List[Int],
        memtable: MemTable,
        lookup: HnswIdOrdinalLookup,
        allowed: HnswEligibility,
    ) raises -> List[SearchResult]:
        self._reset_rerank_counters(memtable, lookup)
        if target == 0:
            self._last_stats.reranked_candidates = 0
            self._last_stats.retained_candidates = 0
            return List[SearchResult]()
        var topk = BoundedTopK(
            target,
            smaller_is_better=Int(self.config.ann_metric.tag()) == 1,
        )
        var scored = 0
        for id in candidates:
            var ordinal = lookup.ordinal_for(id)
            self._last_rerank_ordinal_lookups += 1
            self._validate_authoritative_ordinal(id, ordinal, memtable)
            if not allowed.allows(id):
                raise Error("segmented HNSW candidate is not filter eligible")
            ref entry = memtable.entry_ref_at(ordinal)
            topk.offer(
                id,
                authoritative_f32_score(
                    Int(self.config.ann_metric.tag()), query, entry.values
                ),
            )
            scored += 1
        self._last_stats.reranked_candidates = scored
        if scored < target:
            self.validate_structure()
            self._last_stats.fallback_reason = "filtered_ann_exhausted"
        return self._finish_topk(topk^)

    def _finish_topk(mut self, var topk: BoundedTopK) -> List[SearchResult]:
        var retained = topk.sorted_entries()
        var result = List[SearchResult](capacity=len(retained))
        for entry in retained:
            result.append(SearchResult(entry.id, entry.score))
        self._last_stats.retained_candidates = len(result)
        return result^

    def _reset_rerank_counters(
        mut self, memtable: MemTable, lookup: HnswIdOrdinalLookup
    ) raises:
        if lookup.entry_count() != memtable.slot_count():
            raise Error("HNSW ID lookup does not match MemTable ordinals")
        self._last_rerank_ordinal_lookups = 0
        self._last_rerank_linear_id_scans = 0

    def _validate_authoritative_ordinal(
        self, id: Int, ordinal: Int, memtable: MemTable
    ) raises:
        if (
            ordinal < 0
            or ordinal >= memtable.slot_count()
            or not memtable.is_live_at(ordinal)
            or memtable.id_at(ordinal) != id
            or not self._sources.contains(id)
        ):
            raise Error("segmented HNSW candidate is not authoritative")

    def _accumulate_source_stats(
        self, mut target: HnswSearchStats, source: HnswSearchStats
    ):
        _accumulate_search_stats(target, source)
        if source.requested_ef > target.requested_ef:
            target.requested_ef = source.requested_ef
        if source.effective_ef > target.effective_ef:
            target.effective_ef = source.effective_ef
        target.widening_rounds += source.widening_rounds

    def _base_live_count(self) -> Int:
        if self._base_kind == _MAPPED_BASE:
            return self._mapped_base.live_point_count()
        if self._base_kind == _OWNED_BASE:
            return (
                self._owned_base.point_count()
                - self._owned_base.inactive_count()
            )
        return 0

    def _base_source_matches(self, id: Int, source: Int) raises -> Bool:
        if source <= 0:
            return False
        var slot_index = source - 1
        if slot_index < 0 or slot_index >= self.base_slot_count():
            return False
        var slot = UInt32(slot_index)
        if self._base_kind == _MAPPED_BASE:
            return (
                self._mapped_base.is_current(slot)
                and self._mapped_base.id_at(slot) == id
            )
        if self._base_kind == _OWNED_BASE:
            return (
                self._owned_base.graph.is_current(slot)
                and self._owned_base.graph.id_at(slot) == id
            )
        return False

    def _index_owned_base_sources(mut self) raises:
        for slot_index in range(self._owned_base.graph.slot_count()):
            var slot = UInt32(slot_index)
            if not self._owned_base.graph.is_current(slot):
                continue
            var id = self._owned_base.graph.id_at(slot)
            var source = slot_index + 1
            self._sources.set_base(id, source)

    def _index_mapped_base_sources(mut self) raises:
        for slot_index in range(self._mapped_base.slot_count()):
            var slot = UInt32(slot_index)
            if not self._mapped_base.is_current(slot):
                continue
            var id = self._mapped_base.id_at(slot)
            var source = slot_index + 1
            self._sources.set_base(id, source)

    def _record_mutation(mut self):
        if self._delta_mutations < self.config.delta_max_points:
            self._delta_mutations += 1

    def _validate_identity(self) raises:
        self.config.validate()
        self.distance_backend.validate_identity(self.config)
        if self._delta.config != self.config:
            raise Error("segmented HNSW delta config diverged from identity")
        if self._base_kind == _OWNED_BASE:
            if self._owned_base.config != self.config:
                raise Error("segmented HNSW owned base config mismatch")
        elif self._base_kind == _MAPPED_BASE:
            if self._mapped_base.config() != self.config:
                raise Error("segmented HNSW mapped base config mismatch")
