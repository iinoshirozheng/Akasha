from akasha.common.config import CollectionConfig
from akasha.compute.metric import MetricDispatcher
from akasha.index.flat import SearchResult
from akasha.index.hnsw_core import (
    _audit_bidirectional_links,
    HnswSearchAdmission,
    greedy_descent,
    search_layer,
)
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.hnsw_storage import HnswGraphAccess
from akasha.storage.mapped_file import MappedFile
from std.collections import Dict
from std.memory import bitcast


comptime _NODE_BYTES = 40
comptime _CURRENT_FLAG = UInt8(1)
comptime _DELETED_FLAG = UInt8(2)
comptime _REPLACED_FLAG = UInt8(4)


def _copy_stats(stats: HnswSearchStats) -> HnswSearchStats:
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


struct HnswGraphView(HnswGraphAccess, Movable):
    """Immutable graph access over one fully validated mapped v1 sidecar.

    Only the mapping owner and scalar offsets are retained. Every access goes
    through ``MappedFile.byte_at`` so no interior pointer can escape or outlive
    the mapping owner.
    """

    var _mapping: MappedFile
    var _config: CollectionConfig
    var _metric: MetricDispatcher
    var _scratch: HnswSearchScratch
    var _last_stats: HnswSearchStats
    var _slots: Int
    var _live_points: Int
    var _level_cells: Int
    var _directed_edges: Int
    var _entry_slot: Optional[UInt32]
    var _entry_level: Int
    var _node_offset: Int
    var _vector_offset: Int
    var _count_offset: Int
    var _edge_offset: Int

    def __init__(out self) raises:
        """Create a harmless closed view; only the store adopts a mapping."""
        var config = CollectionConfig.defaults(1)
        self._mapping = MappedFile()
        self._config = config.copy()
        self._metric = MetricDispatcher(
            config.ann_metric, config.scalar_kind, config.dimension
        )
        self._scratch = HnswSearchScratch()
        self._last_stats = HnswSearchStats()
        self._slots = 0
        self._live_points = 0
        self._level_cells = 0
        self._directed_edges = 0
        self._entry_slot = Optional[UInt32]()
        self._entry_level = -1
        self._node_offset = 0
        self._vector_offset = 0
        self._count_offset = 0
        self._edge_offset = 0

    @staticmethod
    def _from_validated_mapping(
        var mapping: MappedFile,
        config: CollectionConfig,
        slots: Int,
        live_points: Int,
        level_cells: Int,
        directed_edges: Int,
        entry_slot: Optional[UInt32],
        entry_level: Int,
        node_offset: Int,
        vector_offset: Int,
        count_offset: Int,
        edge_offset: Int,
    ) raises -> HnswGraphView:
        config.validate()
        var result = HnswGraphView()
        result._mapping = mapping^
        result._config = config.copy()
        result._metric = MetricDispatcher(
            config.ann_metric, config.scalar_kind, config.dimension
        )
        result._slots = slots
        result._live_points = live_points
        result._level_cells = level_cells
        result._directed_edges = directed_edges
        result._entry_slot = entry_slot
        result._entry_level = entry_level
        result._node_offset = node_offset
        result._vector_offset = vector_offset
        result._count_offset = count_offset
        result._edge_offset = edge_offset
        return result^

    def close(mut self):
        self._mapping.close()

    def validate_search_ready(self) raises:
        if not self._mapping._is_open():
            raise Error("cannot search a closed HNSW graph view")
        _ = self._mapping.byte_at(0)

    def slot_count(self) -> Int:
        return self._slots

    def live_point_count(self) -> Int:
        return self._live_points

    def graph_dimension(self) -> Int:
        return self._config.dimension

    def graph_m(self) -> Int:
        return self._config.m

    def graph_m0(self) -> Int:
        return self._config.m0

    def entry_slot(self) raises -> UInt32:
        self.validate_search_ready()
        if not Bool(self._entry_slot):
            raise Error("empty HNSW graph view has no entry slot")
        return self._entry_slot.value()

    def entry_slot_optional(self) -> Optional[UInt32]:
        return self._entry_slot

    def entry_level(self) -> Int:
        return self._entry_level

    def metric(self) -> MetricDispatcher:
        return self._metric.copy()

    def config(self) -> CollectionConfig:
        """Return the immutable durable graph identity by explicit copy."""
        return self._config.copy()

    def last_search_stats(self) -> HnswSearchStats:
        return _copy_stats(self._last_stats)

    def id_at(self, slot: UInt32) raises -> Int:
        var node = self._node_record(slot)
        return Int(bitcast[DType.int64](self._read_u64(node)))

    def level(self, slot: UInt32) raises -> Int:
        return Int(self._read_u16(self._node_record(slot) + 8))

    def is_current(self, slot: UInt32) -> Bool:
        if not self._mapping._is_open() or UInt64(slot) >= UInt64(self._slots):
            return False
        try:
            return (
                self._mapping.byte_at(
                    self._node_offset + Int(slot) * _NODE_BYTES + 10
                )
                == _CURRENT_FLAG
            )
        except:
            return False

    def vector_value(self, slot: UInt32, component: Int) raises -> Float32:
        if component < 0 or component >= self._config.dimension:
            raise Error("HNSW vector component out of bounds")
        _ = self._slot_index(slot)
        var scalar = Int(slot) * self._config.dimension + component
        return bitcast[DType.float32](
            self._read_u32(self._vector_offset + scalar * 4)
        )

    def distance_to_slot(
        self,
        dispatcher: MetricDispatcher,
        query: List[Float32],
        slot: UInt32,
    ) raises -> Float32:
        dispatcher.require_supported_backend()
        if dispatcher.dimension() != self._config.dimension:
            raise Error("metric dispatcher dimension does not match graph")
        if len(query) != self._config.dimension:
            raise Error("prepared query dimension does not match graph")
        _ = self._slot_index(slot)
        var product = Float32(0.0)
        var squared_l2 = Float32(0.0)
        for component in range(self._config.dimension):
            var left = query[component]
            var right = self.vector_value(slot, component)
            product += left * right
            var difference = left - right
            squared_l2 += difference * difference
        return dispatcher._finish_prepared_f32_accumulations(
            product, squared_l2
        )

    def neighbor_count(self, slot: UInt32, level: Int) raises -> Int:
        self._validate_level(slot, level)
        var count_base = self._read_u64(self._node_record(slot) + 16)
        return Int(
            self._read_u32(
                self._count_offset + Int(count_base + UInt64(level)) * 4
            )
        )

    def neighbor_at(
        self, slot: UInt32, level: Int, index: Int
    ) raises -> UInt32:
        var count = self.neighbor_count(slot, level)
        if index < 0 or index >= count:
            raise Error("HNSW neighbor index out of bounds")
        var edge_ordinal = self._read_u64(self._node_record(slot) + 24)
        for prior_level in range(level):
            edge_ordinal += UInt64(self.neighbor_count(slot, prior_level))
        return self._read_u32(
            self._edge_offset + Int(edge_ordinal + UInt64(index)) * 4
        )

    def validate_structure(self) raises:
        """Re-audit mapped nodes, vectors, counts, edges, and entry point."""
        self.validate_search_ready()
        if self._slots < 0 or self._live_points < 0:
            raise Error("HNSW graph view counts cannot be negative")
        if self._live_points > self._slots:
            raise Error("HNSW graph view live count exceeds slot count")

        var expected_count_base = UInt64(0)
        var expected_edge_base = UInt64(0)
        var observed_live = 0
        var maximum_live_level = -1
        var current_ids = Dict[Int, Bool]()
        for slot_index in range(self._slots):
            var slot = UInt32(slot_index)
            var node = self._node_record(slot)
            var level = self.level(slot)
            if level < 0 or level > self._config.max_level:
                raise Error("HNSW snapshot node level is invalid")
            var flag = self._mapping.byte_at(node + 10)
            if (
                flag != _CURRENT_FLAG
                and flag != _DELETED_FLAG
                and flag != _REPLACED_FLAG
            ):
                raise Error("HNSW snapshot node lifecycle flags are invalid")
            if self._mapping.byte_at(node + 11) != UInt8(0) or self._read_u32(
                node + 12
            ) != UInt32(0):
                raise Error("nonzero HNSW snapshot node reserved bytes")
            if self._read_u64(node + 16) != expected_count_base:
                raise Error("HNSW snapshot node count offsets are not packed")
            if self._read_u64(node + 24) != expected_edge_base:
                raise Error("HNSW snapshot node edge offsets are not packed")

            var node_edges = UInt64(0)
            for graph_level in range(level + 1):
                var count = self.neighbor_count(slot, graph_level)
                var capacity = self._config.m
                if graph_level == 0:
                    capacity = self._config.m0
                if count < 0 or count > capacity:
                    raise Error("HNSW snapshot neighbor count exceeds capacity")
                node_edges += UInt64(count)
            if self._read_u64(node + 32) != node_edges:
                raise Error("HNSW snapshot node edge count is inconsistent")
            expected_count_base += UInt64(level + 1)
            expected_edge_base += node_edges

            var prepared = List[Float32](capacity=self._config.dimension)
            for component in range(self._config.dimension):
                prepared.append(self.vector_value(slot, component))
            self._metric.validate_prepared_vector(prepared)

            if flag == _CURRENT_FLAG:
                var id = self.id_at(slot)
                if id in current_ids:
                    raise Error(
                        "HNSW snapshot current public IDs must be unique"
                    )
                current_ids[id] = True
                observed_live += 1
                if level > maximum_live_level:
                    maximum_live_level = level

        if observed_live != self._live_points:
            raise Error("HNSW snapshot live count does not match node flags")
        if Int(expected_count_base) != self._level_cells:
            raise Error("HNSW snapshot level count does not match nodes")
        if Int(expected_edge_base) != self._directed_edges:
            raise Error("HNSW snapshot edge count does not match nodes")

        for source_index in range(self._slots):
            var source = UInt32(source_index)
            for level in range(self.level(source) + 1):
                var seen = Dict[Int, Bool]()
                for edge_index in range(self.neighbor_count(source, level)):
                    var neighbor = self.neighbor_at(source, level, edge_index)
                    if UInt64(neighbor) >= UInt64(self._slots):
                        raise Error("HNSW snapshot neighbor ordinal is invalid")
                    if neighbor == source:
                        raise Error("HNSW snapshot self edges are not allowed")
                    if self.level(neighbor) < level:
                        raise Error(
                            "HNSW snapshot edge target lacks graph level"
                        )
                    if Int(neighbor) in seen:
                        raise Error(
                            "HNSW snapshot neighbor list has a duplicate"
                        )
                    seen[Int(neighbor)] = True

        if self._slots == 0:
            if Bool(self._entry_slot) or self._entry_level != -1:
                raise Error("empty HNSW snapshot entry point is invalid")
        else:
            if not Bool(self._entry_slot):
                raise Error("non-empty HNSW snapshot entry point is invalid")
            var entry = self._entry_slot.value()
            if (
                UInt64(entry) >= UInt64(self._slots)
                or self._entry_level != self.level(entry)
                or self._entry_level < maximum_live_level
            ):
                raise Error("HNSW snapshot entry point is invalid")
        _audit_bidirectional_links(self)

    def search(
        mut self,
        query: List[Float32],
        k: Int,
        *,
        ef_search: Int = -1,
    ) raises -> List[SearchResult]:
        self.validate_search_ready()
        if k <= 0:
            raise Error("HNSW search k must be positive")
        var requested = ef_search
        if requested < 0:
            requested = self._config.default_ef_search
        if requested <= 0:
            raise Error("HNSW search ef must be positive")
        if requested > self._config.max_ef_search:
            raise Error("HNSW search ef exceeds collection maximum")

        var prepared = self._metric.prepare_query(query)
        var target_count = k
        if target_count > self._live_points:
            target_count = self._live_points
        var effective_ef = requested
        if effective_ef < target_count:
            effective_ef = target_count
        if effective_ef > self._slots:
            effective_ef = self._slots
        if effective_ef > self._config.max_ef_search:
            raise Error("HNSW result demand exceeds collection maximum ef")

        var stats = HnswSearchStats()
        stats.requested_ef = requested
        stats.effective_ef = effective_ef
        stats.backend_name = self._metric.backend_name()
        stats.metric_name = self._metric.metric_name()
        stats.scalar_name = self._metric.scalar_name()
        stats.storage_name = "mapped-f32"
        if target_count == 0 or not Bool(self._entry_slot):
            stats.effective_ef = 0
            self._last_stats = stats^
            return List[SearchResult]()

        var current = self._entry_slot.value()
        for level in range(self._entry_level, 0, -1):
            current = greedy_descent(
                self, self._metric, prepared, current, level, stats
            ).slot
        var admission = HnswSearchAdmission()
        # Move reusable scratch out so the graph's immutable `self` borrow and
        # scratch's mutable borrow have distinct origins under Mojo 1.0.
        var scratch = self._scratch^
        self._scratch = HnswSearchScratch()
        var candidates = search_layer(
            self,
            self._metric,
            prepared,
            current,
            0,
            target_count,
            effective_ef,
            admission,
            scratch,
            stats,
        )
        self._scratch = scratch^
        var results = List[SearchResult](capacity=len(candidates))
        for candidate in candidates:
            results.append(
                SearchResult(
                    candidate.id,
                    self._metric.public_score(candidate.distance),
                )
            )
        self._last_stats = stats^
        return results^

    def _slot_index(self, slot: UInt32) raises -> Int:
        self.validate_search_ready()
        if UInt64(slot) >= UInt64(self._slots):
            raise Error("HNSW slot out of bounds")
        return Int(slot)

    def _node_record(self, slot: UInt32) raises -> Int:
        return self._node_offset + self._slot_index(slot) * _NODE_BYTES

    def _validate_level(self, slot: UInt32, level: Int) raises:
        if level < 0 or level > self.level(slot):
            raise Error("HNSW graph level out of bounds")

    def _read_u16(self, offset: Int) raises -> UInt16:
        return UInt16(self._mapping.byte_at(offset)) | (
            UInt16(self._mapping.byte_at(offset + 1)) << UInt16(8)
        )

    def _read_u32(self, offset: Int) raises -> UInt32:
        var value = UInt32(0)
        for index in range(4):
            value |= UInt32(self._mapping.byte_at(offset + index)) << UInt32(
                index * 8
            )
        return value

    def _read_u64(self, offset: Int) raises -> UInt64:
        var value = UInt64(0)
        for index in range(8):
            value |= UInt64(self._mapping.byte_at(offset + index)) << UInt64(
                index * 8
            )
        return value
