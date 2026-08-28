from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.flat import SearchResult
from akasha.index.hnsw_core import (
    HnswEligibility,
    HnswResultAdmission,
    HnswSearchAdmission,
    connect_bidirectional,
    greedy_descent,
    search_layer,
    select_neighbors_heuristic,
    validate_bidirectional_links,
)
from akasha.index.hnsw_level import sample_level
from akasha.index.hnsw_heap import HnswHeapItem, ResultMaxHeap
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswBuildStats, HnswSearchStats
from akasha.index.hnsw_storage import HnswStorage
from akasha.storage.checksum import BinaryReader, BinaryWriter
from std.collections import Dict
from std.math import isfinite


comptime _MAX_CACHE_POINTS = 10_000_000
comptime _UINT16_MAX_AS_INT = 65_535
comptime _UINT32_MAX_AS_INT = 4_294_967_295
comptime _MAX_CACHE_ESTIMATED_BYTES = UInt64(512 * 1024 * 1024)
comptime _CACHE_ALLOCATION_RATIO = UInt64(16)
comptime _CACHE_MIN_ESTIMATED_BYTES = UInt64(4_096)


def _legacy_config(
    dimension: Int, m: Int, max_level: Int
) raises -> CollectionConfig:
    """Build the temporary L2/F32 identity used by the legacy initializer."""
    if dimension <= 0 or dimension > _UINT32_MAX_AS_INT:
        raise Error("HNSW dimension must be positive and fit UInt32")
    if m <= 0 or m > _UINT16_MAX_AS_INT:
        raise Error("legacy HNSW m must be between 1 and 65535")
    if max_level < 0 or max_level > _UINT16_MAX_AS_INT:
        raise Error("legacy HNSW max_level must be between 0 and 65535")
    var config = CollectionConfig.defaults(dimension)
    config.ann_metric = MetricKind.l2()
    config.scalar_kind = ScalarKind.f32()
    config.m = m
    config.m0 = m
    if config.ef_construction < m:
        config.ef_construction = m
    config.max_level = max_level
    return config^


def _copy_build_stats(stats: HnswBuildStats) -> HnswBuildStats:
    var result = HnswBuildStats()
    result.slot_count = stats.slot_count
    result.inactive_slots = stats.inactive_slots
    result.maximum_level = stats.maximum_level
    result.directed_edges = stats.directed_edges
    result.distance_evaluations = stats.distance_evaluations
    result.serialized_bytes = stats.serialized_bytes
    return result^


def _copy_search_stats(stats: HnswSearchStats) -> HnswSearchStats:
    var result = HnswSearchStats()
    result.requested_ef = stats.requested_ef
    result.effective_ef = stats.effective_ef
    result.widening_rounds = stats.widening_rounds
    result.upper_visited = stats.upper_visited
    result.base_visited = stats.base_visited
    result.distance_evaluations = stats.distance_evaluations
    result.retained_candidates = stats.retained_candidates
    result.reranked_candidates = stats.reranked_candidates
    result.filtered_rejections = stats.filtered_rejections
    result.inactive_rejections = stats.inactive_rejections
    result.base_candidates = stats.base_candidates
    result.delta_candidates = stats.delta_candidates
    result.backend_name = stats.backend_name.copy()
    result.metric_name = stats.metric_name.copy()
    result.scalar_name = stats.scalar_name.copy()
    result.storage_name = stats.storage_name.copy()
    result.fallback_reason = stats.fallback_reason.copy()
    return result^


struct HnswIndex:
    """Metric-bound standard HNSW over flat packed graph storage.

    Construction and public traversal share the same canonical-distance core.
    The compatibility initializer binds an L2/F32 graph; legacy metric-named
    search methods are retained only to validate that their name matches the
    graph's immutable metric.
    """

    var config: CollectionConfig
    var metric: MetricDispatcher
    var graph: HnswStorage
    var scratch: HnswSearchScratch
    var _construction_scratch: HnswSearchScratch
    var entry_slot: Optional[UInt32]
    var entry_level: Int
    var valid: Bool
    var build_stats: HnswBuildStats
    var last_search_stats: HnswSearchStats
    var _last_search_query_preparations: Int
    var _last_search_upper_descents: Int

    # Compatibility fields used by the collection cache wrapper and older
    # direct callers. They mirror the bound configuration and are immutable.
    var dimension: Int
    var m: Int
    var max_level: Int
    var _identity_config: CollectionConfig
    var _level_multiplier: Int

    def __init__(out self, config: CollectionConfig) raises:
        config.validate()
        var owned = config.copy()
        self.config = owned.copy()
        self.metric = MetricDispatcher(
            owned.ann_metric, owned.scalar_kind, owned.dimension
        )
        self.graph = HnswStorage(owned.dimension, owned.m, owned.m0)
        self.scratch = HnswSearchScratch()
        self._construction_scratch = HnswSearchScratch()
        self.entry_slot = Optional[UInt32]()
        self.entry_level = -1
        self.valid = True
        self.build_stats = HnswBuildStats()
        self.build_stats.maximum_level = -1
        self.last_search_stats = HnswSearchStats()
        self._last_search_query_preparations = 0
        self._last_search_upper_descents = 0
        self.dimension = owned.dimension
        self.m = owned.m
        self.max_level = owned.max_level
        self._identity_config = owned.copy()
        self._level_multiplier = owned.m

    def __init__(
        out self, dimension: Int, *, m: Int = 8, max_level: Int = 12
    ) raises:
        var owned = _legacy_config(dimension, m, max_level)
        self.config = owned.copy()
        self.metric = MetricDispatcher(
            owned.ann_metric, owned.scalar_kind, owned.dimension
        )
        self.graph = HnswStorage(dimension, m, m)
        self.scratch = HnswSearchScratch()
        self._construction_scratch = HnswSearchScratch()
        self.entry_slot = Optional[UInt32]()
        self.entry_level = -1
        self.valid = True
        self.build_stats = HnswBuildStats()
        self.build_stats.maximum_level = -1
        self.last_search_stats = HnswSearchStats()
        self._last_search_query_preparations = 0
        self._last_search_upper_descents = 0
        self.dimension = owned.dimension
        self.m = owned.m
        self.max_level = owned.max_level
        self._identity_config = owned.copy()
        self._level_multiplier = m
        if self._level_multiplier < 2:
            self._level_multiplier = 2

    def point_count(self) -> Int:
        return self.graph.slot_count()

    def entry_point_level(self) -> Int:
        return self.entry_level

    def entry_point_id(self) raises -> Int:
        if not Bool(self.entry_slot):
            raise Error("empty HNSW index has no entry point")
        return self.graph.id_at(self.entry_slot.value())

    def maximum_neighbor_count(self, level: Int = -1) raises -> Int:
        var maximum = 0
        for slot_index in range(self.graph.slot_count()):
            var slot = UInt32(slot_index)
            var first_level = 0
            var last_level = self.graph.level(slot)
            if level >= 0:
                if level > last_level:
                    continue
                first_level = level
                last_level = level
            for graph_level in range(first_level, last_level + 1):
                var count = self.graph.neighbor_count(slot, graph_level)
                if count > maximum:
                    maximum = count
        return maximum

    def maximum_upper_neighbor_count(self) raises -> Int:
        var maximum = 0
        for slot_index in range(self.graph.slot_count()):
            var slot = UInt32(slot_index)
            for level in range(1, self.graph.level(slot) + 1):
                var count = self.graph.neighbor_count(slot, level)
                if count > maximum:
                    maximum = count
        return maximum

    def build_slot_count(self) -> Int:
        return self.build_stats.slot_count

    def build_distance_evaluations(self) -> Int:
        return self.build_stats.distance_evaluations

    def last_search_distance_evaluations(self) -> Int:
        return self.last_search_stats.distance_evaluations

    def last_search_visited(self) -> Int:
        return (
            self.last_search_stats.upper_visited
            + self.last_search_stats.base_visited
        )

    def last_search_effective_ef(self) -> Int:
        return self.last_search_stats.effective_ef

    def last_search_query_preparations(self) -> Int:
        return self._last_search_query_preparations

    def last_search_upper_descents(self) -> Int:
        return self._last_search_upper_descents

    def _validate_bound_identity(self) raises:
        if self.config != self._identity_config:
            raise Error("HNSW public config diverged from immutable identity")
        if (
            self.dimension != self._identity_config.dimension
            or self.m != self._identity_config.m
            or self.max_level != self._identity_config.max_level
        ):
            raise Error("HNSW compatibility fields diverged from identity")
        if (
            self.metric.dimension() != self._identity_config.dimension
            or self.metric.metric_name()
            != self._identity_config.metric_name()
            or self.metric.scalar_name()
            != self._identity_config.scalar_name()
        ):
            raise Error("HNSW metric dispatcher diverged from identity")
        if (
            self.graph.dimension != self._identity_config.dimension
            or self.graph.m != self._identity_config.m
            or self.graph.m0 != self._identity_config.m0
        ):
            raise Error("HNSW packed storage diverged from identity")

    def validate_structure(self) raises:
        self._validate_bound_identity()
        if not self.valid or not self.graph.is_valid():
            raise Error("HNSW index is marked invalid")
        validate_bidirectional_links(self.graph)
        var count = self.graph.slot_count()
        if count == 0:
            if Bool(self.entry_slot) or self.entry_level != -1:
                raise Error("empty HNSW entry point is invalid")
        else:
            if not Bool(self.entry_slot):
                raise Error("non-empty HNSW index has no entry point")
            var entry = self.entry_slot.value()
            if (
                not self.graph.is_current(entry)
                or self.entry_level != self.graph.level(entry)
            ):
                raise Error("HNSW entry level does not match entry slot")
            var observed_maximum = -1
            for slot_index in range(count):
                var level = self.graph.level(UInt32(slot_index))
                if level > observed_maximum:
                    observed_maximum = level
            if self.entry_level != observed_maximum:
                raise Error("HNSW entry point is not on the highest level")
        if self.build_stats.slot_count != count:
            raise Error("HNSW build statistics slot count is inconsistent")
        if self.build_stats.maximum_level != self.entry_level:
            raise Error("HNSW build statistics maximum level is inconsistent")

    def add(mut self, id: Int, values: List[Float32]) raises:
        self._validate_bound_identity()
        if not self.valid or not self.graph.is_valid():
            raise Error("cannot mutate an invalid HNSW index")
        # Complete every caller-controlled validation before append. The
        # current-slot map makes duplicate rejection O(1).
        if Bool(self.graph.current_slot(id)):
            raise Error("HNSW point IDs must be unique")
        var prepared = self.metric.prepare_graph_vector(values)
        var new_level = sample_level(
            id,
            self._identity_config.level_seed,
            self._level_multiplier,
            self._identity_config.max_level,
        )

        if not Bool(self.entry_slot):
            var first = self.graph.append(id, prepared^, new_level)
            self.entry_slot = Optional(first)
            self.entry_level = new_level
            self.build_stats.slot_count = 1
            self.build_stats.maximum_level = new_level
            return

        var stored = prepared.copy()
        var new_slot = self.graph.append(id, stored^, new_level)
        var local_build = _copy_build_stats(self.build_stats)
        var construction_stats = HnswSearchStats()
        try:
            var current = self.entry_slot.value()
            var upper_level = self.entry_level
            while upper_level > new_level:
                var descended = greedy_descent(
                    self.graph,
                    self.metric,
                    prepared,
                    current,
                    upper_level,
                    construction_stats,
                )
                current = descended.slot
                upper_level -= 1

            # The new slot is unreachable until its first reciprocal link is
            # published, so construction searches still observe old nodes.
            var shared_level = new_level
            if shared_level > self.entry_level:
                shared_level = self.entry_level
            var admission = HnswSearchAdmission()
            while shared_level >= 0:
                var candidates = search_layer(
                    self.graph,
                    self.metric,
                    prepared,
                    current,
                    shared_level,
                    self._identity_config.ef_construction,
                    self._identity_config.ef_construction,
                    admission,
                    self._construction_scratch,
                    construction_stats,
                )
                var next_entry = current
                if len(candidates) > 0:
                    next_entry = candidates[0].slot
                var excluded = Optional(new_slot)
                var selected = select_neighbors_heuristic(
                    self.graph,
                    self.metric,
                    candidates,
                    excluded,
                    self.graph.level_capacity(new_slot, shared_level),
                    True,
                    local_build,
                )
                connect_bidirectional(
                    self.graph,
                    self.metric,
                    new_slot,
                    shared_level,
                    selected^,
                    local_build,
                )
                current = next_entry
                shared_level -= 1
        except error:
            self.graph.mark_invalid()
            self.valid = False
            raise Error(String(error))

        local_build.distance_evaluations += (
            construction_stats.distance_evaluations
        )
        local_build.slot_count = self.graph.slot_count()
        if new_level > self.entry_level:
            self.entry_slot = Optional(new_slot)
            self.entry_level = new_level
            local_build.maximum_level = new_level
        self.build_stats = local_build^

    def search(
        mut self,
        query: List[Float32],
        k: Int,
        *,
        ef_search: Int = -1,
    ) raises -> List[SearchResult]:
        var requested = ef_search
        if requested < 0:
            requested = self._identity_config.default_ef_search
        var allowed = HnswSearchAdmission()
        return self._search_bound(query, k, requested, allowed)

    def search_allowed(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        allowed: HnswEligibility,
    ) raises -> List[SearchResult]:
        return self._search_bound(query, k, ef_search, allowed)

    @staticmethod
    def next_widened_ef(current_ef: Int, max_ef: Int) raises -> Int:
        """Double ``current_ef`` and saturate at ``max_ef`` safely."""
        if current_ef <= 0 or max_ef <= 0 or current_ef > max_ef:
            raise Error("HNSW widening ef range is invalid")
        if current_ef == max_ef or current_ef > max_ef // 2:
            return max_ef
        return current_ef * 2

    def search_allowed_with_widening(
        mut self,
        query: List[Float32],
        k: Int,
        initial_ef: Int,
        max_ef: Int,
        allowed: HnswEligibility,
    ) raises -> List[SearchResult]:
        """Widen from the eligibility bitmap's authoritative cardinality."""
        return self._search_allowed_with_actual_widening(
            query, k, initial_ef, max_ef, allowed
        )

    def search_allowed_with_widening(
        mut self,
        query: List[Float32],
        k: Int,
        initial_ef: Int,
        max_ef: Int,
        matched_count: Int,
        allowed: HnswEligibility,
    ) raises -> List[SearchResult]:
        """Compatibility boundary for callers still carrying match counts."""
        allowed.validate(self.graph.slot_count())
        if matched_count != allowed.eligible_count():
            raise Error(
                "HNSW matched count does not match eligibility cardinality"
            )
        return self._search_allowed_with_actual_widening(
            query, k, initial_ef, max_ef, allowed
        )

    def _search_allowed_with_actual_widening(
        mut self,
        query: List[Float32],
        k: Int,
        initial_ef: Int,
        max_ef: Int,
        allowed: HnswEligibility,
    ) raises -> List[SearchResult]:
        """Run filtered ANN rounds, then exact-scan on exhausted breadth.

        The query and upper descent are prepared once. Each wider round reruns
        only the base layer over the same reusable scratch allocation. Prior
        result lists are replaced, never appended. The index-local exact scan
        is the correctness fallback; collection integration may subsequently
        rerank these IDs against authoritative vectors.
        """
        self._validate_bound_identity()
        if not self.valid or not self.graph.is_valid():
            raise Error("cannot search an invalid HNSW index")
        if k <= 0:
            raise Error("HNSW search k must be positive")
        if initial_ef <= 0 or max_ef <= 0 or initial_ef > max_ef:
            raise Error("HNSW widening ef range is invalid")
        if max_ef > self._identity_config.max_ef_search:
            raise Error("HNSW widening maximum exceeds collection maximum")
        allowed.validate(self.graph.slot_count())

        var matched_count = allowed.eligible_count()
        var slot_count = self.graph.slot_count()
        if matched_count > slot_count:
            raise Error("HNSW eligibility count exceeds graph slots")
        var target_count = k
        if target_count > matched_count:
            target_count = matched_count
        # Every graph slot is a possible navigation bridge, including future
        # historical slots. No base round can usefully retain more state than
        # this traversable population.
        var effective_ceiling = max_ef
        if effective_ceiling > slot_count:
            effective_ceiling = slot_count

        var prepared = self.metric.prepare_query(query)
        if target_count == 0:
            var empty_stats = self._new_search_stats(0, 0)
            self.last_search_stats = empty_stats^
            self._last_search_query_preparations = 1
            self._last_search_upper_descents = 0
            return List[SearchResult]()

        var current_ef = initial_ef
        if current_ef < target_count:
            current_ef = target_count
        if current_ef > effective_ceiling:
            current_ef = effective_ceiling
        if current_ef < target_count:
            raise Error("HNSW result demand exceeds traversable graph slots")

        var upper_stats = self._new_search_stats(current_ef, current_ef)
        var upper_descents = 0
        var has_entry = Bool(self.entry_slot)
        var current = UInt32(0)
        if has_entry:
            current = self.entry_slot.value()
            var level = self.entry_level
            while level > 0:
                var descended = greedy_descent(
                    self.graph,
                    self.metric,
                    prepared,
                    current,
                    level,
                    upper_stats,
                )
                upper_descents += 1
                current = descended.slot
                level -= 1

        var widening_rounds = 0
        var results: List[SearchResult]
        if has_entry:
            results = self._search_base_prepared(
                prepared,
                current,
                target_count,
                current_ef,
                current_ef,
                allowed,
                upper_stats,
            )
        else:
            results = List[SearchResult]()
            self.last_search_stats = _copy_search_stats(upper_stats)

        while len(results) < target_count and current_ef < effective_ceiling:
            var widened = HnswIndex.next_widened_ef(
                current_ef, effective_ceiling
            )
            if widened == current_ef:
                break
            current_ef = widened
            widening_rounds += 1
            # Replace the prior base round wholesale. `search_layer` begins a
            # new scratch epoch while retaining its bounded allocations.
            results = self._search_base_prepared(
                prepared,
                current,
                target_count,
                current_ef,
                current_ef,
                allowed,
                upper_stats,
            )

        var final_stats = _copy_search_stats(self.last_search_stats)
        final_stats.widening_rounds = widening_rounds
        if len(results) >= target_count:
            self.last_search_stats = final_stats^
            self._last_search_query_preparations = 1
            self._last_search_upper_descents = upper_descents
            return results^

        var exact = self._search_allowed_exact_prepared(
            prepared, target_count, allowed
        )
        final_stats.fallback_reason = String("filtered_ann_exhausted")
        self.last_search_stats = final_stats^
        self._last_search_query_preparations = 1
        self._last_search_upper_descents = upper_descents
        return exact^

    def _search_allowed_exact_prepared(
        self,
        prepared: List[Float32],
        k: Int,
        allowed: HnswEligibility,
    ) raises -> List[SearchResult]:
        """Return exact eligible graph results without changing ANN stats."""
        if k == 0:
            return List[SearchResult]()
        allowed.validate(self.graph.slot_count())
        var retained = ResultMaxHeap()
        retained.reserve(k)
        for slot_index in range(self.graph.slot_count()):
            var slot = UInt32(slot_index)
            var id = self.graph.id_at(slot)
            var current = self.graph.current_slot(id)
            if (
                not Bool(current)
                or current.value() != slot
                or not allowed.allows(id)
            ):
                continue
            retained.offer(
                HnswHeapItem(
                    slot,
                    id,
                    self.graph.distance_to_slot(
                        self.metric, prepared, slot
                    ),
                ),
                k,
            )
        var candidates = retained.take_sorted_best()
        var results = List[SearchResult](capacity=len(candidates))
        for candidate in candidates:
            results.append(
                SearchResult(
                    candidate.id,
                    self.metric.public_score(candidate.distance),
                )
            )
        return results^

    def search_dot(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        self._require_metric("dot")
        var allowed = HnswSearchAdmission()
        return self._search_bound(query, k, ef_search, allowed)

    def search_l2(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        self._require_metric("l2")
        var allowed = HnswSearchAdmission()
        return self._search_bound(query, k, ef_search, allowed)

    def search_cosine(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        self._require_metric("cosine")
        var allowed = HnswSearchAdmission()
        return self._search_bound(query, k, ef_search, allowed)

    def _require_metric(self, requested: String) raises:
        var bound = self.metric.metric_name()
        if bound != requested:
            raise Error(
                String(
                    "HNSW metric mismatch: graph is bound to ",
                    bound,
                    " but search requested ",
                    requested,
                )
            )

    def _new_search_stats(
        self, requested_ef: Int, effective_ef: Int
    ) -> HnswSearchStats:
        var stats = HnswSearchStats()
        stats.requested_ef = requested_ef
        stats.effective_ef = effective_ef
        stats.backend_name = self.metric.backend_name()
        stats.metric_name = self.metric.metric_name()
        stats.scalar_name = self.metric.scalar_name()
        stats.storage_name = "packed-f32"
        return stats^

    def _search_base_prepared[AdmissionType: HnswResultAdmission](
        mut self,
        prepared: List[Float32],
        current: UInt32,
        target_count: Int,
        requested_ef: Int,
        effective_ef: Int,
        allowed: AdmissionType,
        upper_stats: HnswSearchStats,
    ) raises -> List[SearchResult]:
        """Run one base round while preserving a single upper-phase prefix."""
        var stats = _copy_search_stats(upper_stats)
        stats.requested_ef = requested_ef
        stats.effective_ef = effective_ef
        var candidates = search_layer(
            self.graph,
            self.metric,
            prepared,
            current,
            0,
            target_count,
            effective_ef,
            allowed,
            self.scratch,
            stats,
        )
        var results = List[SearchResult](capacity=len(candidates))
        for candidate in candidates:
            results.append(
                SearchResult(
                    candidate.id,
                    self.metric.public_score(candidate.distance),
                )
            )
        self.last_search_stats = stats^
        return results^

    def _search_bound[AdmissionType: HnswResultAdmission](
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        allowed: AdmissionType,
    ) raises -> List[SearchResult]:
        self._validate_bound_identity()
        if not self.valid or not self.graph.is_valid():
            raise Error("cannot search an invalid HNSW index")
        if k <= 0:
            raise Error("HNSW search k must be positive")
        if ef_search <= 0:
            raise Error("HNSW search ef must be positive")
        if ef_search > self._identity_config.max_ef_search:
            raise Error("HNSW search ef exceeds collection maximum")
        allowed.validate(self.graph.slot_count())
        var prepared = self.metric.prepare_query(query)
        var target_count = k
        if target_count > self.graph.slot_count():
            target_count = self.graph.slot_count()
        var effective_ef = ef_search
        if effective_ef < target_count:
            effective_ef = target_count
        if effective_ef > self._identity_config.max_ef_search:
            raise Error("HNSW result demand exceeds collection maximum ef")

        var stats = self._new_search_stats(ef_search, effective_ef)
        if not Bool(self.entry_slot):
            stats.effective_ef = 0
            self.last_search_stats = stats^
            self._last_search_query_preparations = 1
            self._last_search_upper_descents = 0
            return List[SearchResult]()

        var current = self.entry_slot.value()
        var level = self.entry_level
        var upper_descents = 0
        while level > 0:
            var descended = greedy_descent(
                self.graph,
                self.metric,
                prepared,
                current,
                level,
                stats,
            )
            upper_descents += 1
            current = descended.slot
            level -= 1

        var results = self._search_base_prepared(
            prepared,
            current,
            target_count,
            ef_search,
            effective_ef,
            allowed,
            stats,
        )
        self._last_search_query_preparations = 1
        self._last_search_upper_descents = upper_descents
        return results^

    def encode_cache_payload(self) raises -> List[UInt8]:
        """Encode the prototype payload layout against packed storage."""
        self._validate_bound_identity()
        if not self.valid or not self.graph.is_valid():
            raise Error("cannot serialize an invalid HNSW index")
        if (
            self._identity_config.ann_metric != MetricKind.l2()
            or self._identity_config.scalar_kind != ScalarKind.f32()
            or self.graph.m0 != self.graph.m
        ):
            raise Error(
                "legacy HNSW cache cannot losslessly encode this identity"
            )
        self.validate_structure()
        var legacy_bound = self.graph.m
        if self.graph.m0 > legacy_bound:
            legacy_bound = self.graph.m0
        if legacy_bound > _UINT16_MAX_AS_INT:
            raise Error("HNSW configuration exceeds cache format")
        if self.max_level > _UINT16_MAX_AS_INT:
            raise Error("HNSW configuration exceeds cache format")
        if self.graph.slot_count() > Int(UInt32.MAX):
            raise Error("HNSW graph exceeds cache format")

        var writer = BinaryWriter()
        writer.write_u16(UInt16(legacy_bound))
        writer.write_u16(UInt16(self.max_level))
        writer.write_u32(UInt32(self.graph.slot_count()))
        if Bool(self.entry_slot):
            writer.write_i64(Int64(self.entry_slot.value()))
        else:
            writer.write_i64(Int64(-1))
        writer.write_i64(Int64(self.entry_level))
        var level_cells = UInt64(0)
        var neighbor_cells = UInt64(0)
        for slot_index in range(self.graph.slot_count()):
            var slot = UInt32(slot_index)
            var level = self.graph.level(slot)
            level_cells = _checked_add_u64(
                level_cells, UInt64(level) + UInt64(1)
            )
            neighbor_cells = _checked_add_u64(
                neighbor_cells,
                UInt64(self.graph.allocated_neighbor_slot_count(slot)),
            )
            writer.write_i64(Int64(self.graph.id_at(slot)))
            writer.write_u16(UInt16(level))
            writer.write_u16(UInt16(0))
            for component in range(self.dimension):
                writer.write_f32(self.graph.vector_value(slot, component))
            for graph_level in range(level + 1):
                var count = self.graph.neighbor_count(slot, graph_level)
                if count > legacy_bound:
                    raise Error("HNSW neighbor list exceeds cache format")
                writer.write_u16(UInt16(count))
                writer.write_u16(UInt16(0))
                for edge_index in range(count):
                    writer.write_u32(
                        self.graph.neighbor_at(slot, graph_level, edge_index)
                    )
        var payload = writer.take_bytes()
        _validate_cache_allocation(
            len(payload),
            self.graph.slot_count(),
            self.dimension,
            level_cells,
            neighbor_cells,
        )
        return payload^

    @staticmethod
    def decode_cache_payload(
        dimension: Int, var payload: List[UInt8]
    ) raises -> HnswIndex:
        var parsed = _preflight_cache(dimension, payload^)
        var index = HnswIndex(
            dimension, m=parsed.m, max_level=parsed.max_level
        )
        return _materialize_cache(index^, parsed^)

    @staticmethod
    def decode_cache_payload_with_config(
        config: CollectionConfig, var payload: List[UInt8]
    ) raises -> HnswIndex:
        """Decode the metricless legacy bytes only with a lossless identity."""
        config.validate()
        if (
            config.ann_metric != MetricKind.l2()
            or config.scalar_kind != ScalarKind.f32()
            or config.m0 != config.m
        ):
            raise Error(
                "legacy HNSW cache cannot losslessly decode this identity"
            )
        var parsed = _preflight_cache(config.dimension, payload^)
        if parsed.m != config.m or parsed.max_level != config.max_level:
            raise Error("HNSW cache configuration does not match collection")
        var index = HnswIndex(config)
        return _materialize_cache(index^, parsed^)


struct _CachePreflight(Movable):
    var m: Int
    var max_level: Int
    var point_count: Int
    var entry_index: Int
    var entry_level: Int
    var maximum_observed_level: Int
    var directed_edges: Int
    var serialized_bytes: Int
    var ids: List[Int]
    var levels: List[Int]
    var vector_scalars: List[Float32]
    var edge_counts: List[Int]
    var edge_slots: List[UInt32]

    def __init__(out self):
        self.m = 0
        self.max_level = 0
        self.point_count = 0
        self.entry_index = -1
        self.entry_level = -1
        self.maximum_observed_level = -1
        self.directed_edges = 0
        self.serialized_bytes = 0
        self.ids = List[Int]()
        self.levels = List[Int]()
        self.vector_scalars = List[Float32]()
        self.edge_counts = List[Int]()
        self.edge_slots = List[UInt32]()


def _checked_add_u64(lhs: UInt64, rhs: UInt64) raises -> UInt64:
    if rhs > UInt64.MAX - lhs:
        raise Error("HNSW cache estimated allocation overflows")
    return lhs + rhs


def _checked_mul_u64(lhs: UInt64, rhs: UInt64) raises -> UInt64:
    if lhs != UInt64(0) and rhs > UInt64.MAX // lhs:
        raise Error("HNSW cache estimated allocation overflows")
    return lhs * rhs


def _validate_cache_allocation(
    serialized_bytes: Int,
    point_count: Int,
    dimension: Int,
    level_cells: UInt64,
    neighbor_cells: UInt64,
) raises:
    var vector_cells = _checked_mul_u64(
        UInt64(point_count), UInt64(dimension)
    )
    # Account for both preflight tapes and final packed tapes conservatively.
    var estimated = _checked_mul_u64(vector_cells, UInt64(8))
    estimated = _checked_add_u64(
        estimated, _checked_mul_u64(level_cells, UInt64(16))
    )
    estimated = _checked_add_u64(
        estimated, _checked_mul_u64(neighbor_cells, UInt64(8))
    )
    estimated = _checked_add_u64(
        estimated,
        _checked_mul_u64(UInt64(point_count), UInt64(64)),
    )
    var amplification_limit = _CACHE_MIN_ESTIMATED_BYTES
    if UInt64(serialized_bytes) <= UInt64.MAX // _CACHE_ALLOCATION_RATIO:
        var scaled = UInt64(serialized_bytes) * _CACHE_ALLOCATION_RATIO
        if scaled > amplification_limit:
            amplification_limit = scaled
    if (
        estimated > amplification_limit
        or estimated > _MAX_CACHE_ESTIMATED_BYTES
    ):
        raise Error(
            "HNSW cache estimated allocation exceeds amplification limit"
        )


def _preflight_cache(
    dimension: Int, var payload: List[UInt8]
) raises -> _CachePreflight:
    if dimension <= 0 or dimension > _UINT32_MAX_AS_INT:
        raise Error("HNSW cache dimension is invalid")
    var result = _CachePreflight()
    result.serialized_bytes = len(payload)
    var reader = BinaryReader(payload^)
    result.m = Int(reader.read_u16())
    result.max_level = Int(reader.read_u16())
    if result.m <= 0:
        raise Error("HNSW cache neighbor bound must be positive")
    result.point_count = Int(reader.read_u32())
    if result.point_count > _MAX_CACHE_POINTS:
        raise Error("HNSW cache point count exceeds limit")
    result.entry_index = Int(reader.read_i64())
    result.entry_level = Int(reader.read_i64())

    var level_cells = UInt64(0)
    var neighbor_cells = UInt64(0)
    _validate_cache_allocation(
        result.serialized_bytes,
        result.point_count,
        dimension,
        level_cells,
        neighbor_cells,
    )
    var seen_ids = Dict[Int, Bool]()
    for slot_index in range(result.point_count):
        var id = Int(reader.read_i64())
        if id in seen_ids:
            raise Error("HNSW cache contains duplicate point IDs")
        seen_ids[id] = True
        result.ids.append(id)
        var level = Int(reader.read_u16())
        if reader.read_u16() != UInt16(0) or level > result.max_level:
            raise Error("HNSW cache node header is invalid")
        result.levels.append(level)
        if level > result.maximum_observed_level:
            result.maximum_observed_level = level

        var node_level_cells = UInt64(level) + UInt64(1)
        level_cells = _checked_add_u64(level_cells, node_level_cells)
        var node_neighbor_cells = _checked_mul_u64(
            UInt64(result.m), node_level_cells
        )
        neighbor_cells = _checked_add_u64(
            neighbor_cells, node_neighbor_cells
        )
        _validate_cache_allocation(
            result.serialized_bytes,
            result.point_count,
            dimension,
            level_cells,
            neighbor_cells,
        )

        for _ in range(dimension):
            var value = reader.read_f32()
            if not isfinite(value):
                raise Error("HNSW cache vector must be finite")
            result.vector_scalars.append(value)
        for _ in range(level + 1):
            var neighbor_count = Int(reader.read_u16())
            if (
                reader.read_u16() != UInt16(0)
                or neighbor_count > result.m
            ):
                raise Error("HNSW cache neighbor header is invalid")
            result.edge_counts.append(neighbor_count)
            result.directed_edges += neighbor_count
            var seen_neighbors = Dict[Int, Bool]()
            for _ in range(neighbor_count):
                var neighbor = Int(reader.read_u32())
                if neighbor < 0 or neighbor >= result.point_count:
                    raise Error("HNSW cache neighbor ordinal is invalid")
                if neighbor == slot_index:
                    raise Error("HNSW cache self edges are not allowed")
                if neighbor in seen_neighbors:
                    raise Error(
                        "HNSW cache neighbor list contains a duplicate"
                    )
                seen_neighbors[neighbor] = True
                result.edge_slots.append(UInt32(neighbor))

    if reader.remaining() != 0:
        raise Error("HNSW cache has trailing bytes")

    var count_offset = 0
    var edge_offset = 0
    for source in range(result.point_count):
        for level in range(result.levels[source] + 1):
            var count = result.edge_counts[count_offset]
            count_offset += 1
            for _ in range(count):
                var target = Int(result.edge_slots[edge_offset])
                edge_offset += 1
                if result.levels[target] < level:
                    raise Error("HNSW edge target does not own graph level")

    if result.point_count == 0:
        if result.entry_index != -1 or result.entry_level != -1:
            raise Error("empty HNSW cache entry point is invalid")
    elif (
        result.entry_index < 0
        or result.entry_index >= result.point_count
        or result.entry_level < 0
        or result.entry_level != result.levels[result.entry_index]
    ):
        raise Error("HNSW cache entry point is invalid")
    elif result.entry_level != result.maximum_observed_level:
        raise Error("HNSW cache entry point is not on the highest graph level")
    return result^


def _materialize_cache(
    var index: HnswIndex, var parsed: _CachePreflight
) raises -> HnswIndex:
    var vector_offset = 0
    for slot_index in range(parsed.point_count):
        var vector = List[Float32](capacity=index.dimension)
        for _ in range(index.dimension):
            vector.append(parsed.vector_scalars[vector_offset])
            vector_offset += 1
        var prepared = index.metric.prepare_graph_vector(vector^)
        var slot = index.graph.append(
            parsed.ids[slot_index], prepared^, parsed.levels[slot_index]
        )
        if Int(slot) != slot_index:
            raise Error("HNSW cache slot materialization is inconsistent")

    # Preflight has already proved bounds, ownership, self/duplicate absence,
    # and allocation limits. Populate the empty packed tapes directly to avoid
    # repeating set_neighbors' quadratic defensive duplicate scan.
    var count_offset = 0
    var edge_offset = 0
    for slot_index in range(parsed.point_count):
        for level in range(parsed.levels[slot_index] + 1):
            var count = parsed.edge_counts[count_offset]
            count_offset += 1
            var base = index.graph.neighbor_bases[slot_index]
            if level > 0:
                base += index.graph.m0 + (level - 1) * index.graph.m
            for edge_index in range(count):
                index.graph.neighbor_slots[base + edge_index] = (
                    parsed.edge_slots[edge_offset]
                )
                edge_offset += 1
            var count_index = (
                index.graph.neighbor_count_bases[slot_index] + level
            )
            index.graph.neighbor_counts[count_index] = UInt32(count)

    if parsed.point_count > 0:
        index.entry_slot = Optional(UInt32(parsed.entry_index))
        index.entry_level = parsed.entry_level
    index.build_stats.slot_count = parsed.point_count
    index.build_stats.maximum_level = parsed.maximum_observed_level
    index.build_stats.directed_edges = parsed.directed_edges
    index.build_stats.serialized_bytes = parsed.serialized_bytes
    index.validate_structure()
    return index^
