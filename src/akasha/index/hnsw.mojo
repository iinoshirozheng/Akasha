from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.flat import SearchResult
from akasha.index.hnsw_core import (
    HnswSearchAdmission,
    connect_bidirectional,
    greedy_descent,
    search_layer,
    select_neighbors_heuristic,
    validate_bidirectional_links,
)
from akasha.index.hnsw_level import sample_level
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswBuildStats, HnswSearchStats
from akasha.index.hnsw_storage import HnswStorage
from akasha.storage.checksum import BinaryReader, BinaryWriter
from std.math import isfinite


comptime _MAX_CACHE_POINTS = 10_000_000
comptime _UINT16_MAX_AS_INT = 65_535


def _legacy_config(
    dimension: Int, m: Int, max_level: Int
) -> CollectionConfig:
    """Build the temporary L2/F32 identity used by the legacy initializer."""
    var config = CollectionConfig.defaults(dimension)
    config.ann_metric = MetricKind.l2()
    config.scalar_kind = ScalarKind.f32()
    config.m = m
    config.m0 = m
    if config.ef_construction < m:
        config.ef_construction = m
    config.max_level = max_level
    return config^


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

    # Compatibility fields used by the collection cache wrapper and older
    # direct callers. They mirror the bound configuration and are immutable.
    var dimension: Int
    var m: Int
    var max_level: Int
    var _legacy_cache_bound: Int

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
        self.dimension = owned.dimension
        self.m = owned.m
        self.max_level = owned.max_level
        self._legacy_cache_bound = 0

    def __init__(
        out self, dimension: Int, *, m: Int = 8, max_level: Int = 12
    ) raises:
        var owned = _legacy_config(dimension, m, max_level)
        owned.validate()
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
        self.dimension = owned.dimension
        self.m = owned.m
        self.max_level = owned.max_level
        self._legacy_cache_bound = 0

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

    def validate_structure(self) raises:
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
            if self.entry_level != self.graph.level(entry):
                raise Error("HNSW entry level does not match entry slot")
        if self.build_stats.slot_count != count:
            raise Error("HNSW build statistics slot count is inconsistent")
        if self.build_stats.maximum_level != self.entry_level:
            raise Error("HNSW build statistics maximum level is inconsistent")

    def add(mut self, id: Int, values: List[Float32]) raises:
        if not self.valid or not self.graph.is_valid():
            raise Error("cannot mutate an invalid HNSW index")
        # Complete every caller-controlled validation before append. The
        # current-slot map makes duplicate rejection O(1).
        if Bool(self.graph.current_slot(id)):
            raise Error("HNSW point IDs must be unique")
        var prepared = self.metric.prepare_graph_vector(values)
        var new_level = sample_level(
            id,
            self.config.level_seed,
            self.config.m,
            self.config.max_level,
        )

        if not Bool(self.entry_slot):
            var first = self.graph.append(id, prepared^, new_level)
            self.entry_slot = Optional(first)
            self.entry_level = new_level
            self.build_stats.slot_count = 1
            self.build_stats.maximum_level = new_level
            return

        var current = self.entry_slot.value()
        var construction_stats = HnswSearchStats()
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
        # published, so construction searches still observe only old nodes.
        var stored = prepared.copy()
        var new_slot = self.graph.append(id, stored^, new_level)
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
                self.config.ef_construction,
                self.config.ef_construction,
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
                self.build_stats,
            )
            try:
                connect_bidirectional(
                    self.graph,
                    self.metric,
                    new_slot,
                    shared_level,
                    selected^,
                    self.build_stats,
                )
            except error:
                self.valid = False
                raise Error(String(error))
            current = next_entry
            shared_level -= 1

        self.build_stats.distance_evaluations += (
            construction_stats.distance_evaluations
        )
        self.build_stats.slot_count = self.graph.slot_count()
        if new_level > self.entry_level:
            self.entry_slot = Optional(new_slot)
            self.entry_level = new_level
            self.build_stats.maximum_level = new_level

    def search(
        mut self,
        query: List[Float32],
        k: Int,
        *,
        ef_search: Int = -1,
    ) raises -> List[SearchResult]:
        var requested = ef_search
        if requested < 0:
            requested = self.config.default_ef_search
        return self._search_bound(query, k, requested)

    def search_dot(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        self._require_metric("dot")
        return self._search_bound(query, k, ef_search)

    def search_l2(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        self._require_metric("l2")
        return self._search_bound(query, k, ef_search)

    def search_cosine(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        self._require_metric("cosine")
        return self._search_bound(query, k, ef_search)

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

    def _search_bound(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        if not self.valid or not self.graph.is_valid():
            raise Error("cannot search an invalid HNSW index")
        if k <= 0:
            raise Error("HNSW search k must be positive")
        if ef_search <= 0:
            raise Error("HNSW search ef must be positive")
        if ef_search > self.config.max_ef_search:
            raise Error("HNSW search ef exceeds collection maximum")
        var prepared = self.metric.prepare_query(query)
        var effective_ef = ef_search
        if effective_ef < k:
            effective_ef = k

        var stats = HnswSearchStats()
        stats.requested_ef = ef_search
        stats.effective_ef = effective_ef
        stats.backend_name = self.metric.backend_name()
        stats.metric_name = self.metric.metric_name()
        stats.scalar_name = self.metric.scalar_name()
        stats.storage_name = "packed-f32"
        if not Bool(self.entry_slot):
            self.last_search_stats = stats^
            return List[SearchResult]()

        var current = self.entry_slot.value()
        var level = self.entry_level
        while level > 0:
            var descended = greedy_descent(
                self.graph,
                self.metric,
                prepared,
                current,
                level,
                stats,
            )
            current = descended.slot
            level -= 1

        var admission = HnswSearchAdmission()
        var candidates = search_layer(
            self.graph,
            self.metric,
            prepared,
            current,
            0,
            k,
            effective_ef,
            admission,
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

    def encode_cache_payload(self) raises -> List[UInt8]:
        """Encode the prototype payload layout against packed storage."""
        if not self.valid or not self.graph.is_valid():
            raise Error("cannot serialize an invalid HNSW index")
        var legacy_bound = self.graph.m
        if self.graph.m0 > legacy_bound:
            legacy_bound = self.graph.m0
        if self._legacy_cache_bound > 0:
            legacy_bound = self._legacy_cache_bound
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
        for slot_index in range(self.graph.slot_count()):
            var slot = UInt32(slot_index)
            var level = self.graph.level(slot)
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
        return writer.take_bytes()

    @staticmethod
    def decode_cache_payload(
        dimension: Int, var payload: List[UInt8]
    ) raises -> HnswIndex:
        var serialized_bytes = len(payload)
        var reader = BinaryReader(payload^)
        var m = Int(reader.read_u16())
        var max_level = Int(reader.read_u16())
        if m <= 0:
            raise Error("HNSW cache neighbor bound must be positive")
        var point_count = Int(reader.read_u32())
        if point_count > _MAX_CACHE_POINTS:
            raise Error("HNSW cache point count exceeds limit")
        var entry_index = Int(reader.read_i64())
        var entry_level = Int(reader.read_i64())
        # The prototype accepted m=1, max_level=0, and max_level values above
        # the durable CollectionConfig range. Use the nearest legal standard
        # identity while retaining the original header for byte-compatible
        # re-encoding; decoded adjacency remains bounded by the old header.
        var standard_m = m
        if standard_m < 2:
            standard_m = 2
        var standard_max_level = max_level
        if standard_max_level < 1:
            standard_max_level = 1
        elif standard_max_level > 63:
            standard_max_level = 63
        var index = HnswIndex(
            dimension, m=standard_m, max_level=standard_max_level
        )
        index.m = m
        index.max_level = max_level
        index._legacy_cache_bound = m
        var edge_counts = List[Int]()
        var edge_slots = List[UInt32]()

        for _ in range(point_count):
            var id = Int(reader.read_i64())
            if Bool(index.graph.current_slot(id)):
                raise Error("HNSW cache contains duplicate point IDs")
            var level = Int(reader.read_u16())
            if reader.read_u16() != UInt16(0) or level > max_level:
                raise Error("HNSW cache node header is invalid")
            var vector = List[Float32](capacity=dimension)
            for _ in range(dimension):
                var value = reader.read_f32()
                if not isfinite(value):
                    raise Error("HNSW cache vector must be finite")
                vector.append(value)
            var prepared = index.metric.prepare_graph_vector(vector^)
            _ = index.graph.append(id, prepared^, level)
            if level > index.build_stats.maximum_level:
                index.build_stats.maximum_level = level
            for _ in range(level + 1):
                var neighbor_count = Int(reader.read_u16())
                if reader.read_u16() != UInt16(0) or neighbor_count > m:
                    raise Error("HNSW cache neighbor header is invalid")
                edge_counts.append(neighbor_count)
                for _ in range(neighbor_count):
                    var neighbor = Int(reader.read_u32())
                    if neighbor < 0 or neighbor >= point_count:
                        raise Error("HNSW cache neighbor ordinal is invalid")
                    edge_slots.append(UInt32(neighbor))

        if reader.remaining() != 0:
            raise Error("HNSW cache has trailing bytes")
        var count_offset = 0
        var edge_offset = 0
        for slot_index in range(point_count):
            var slot = UInt32(slot_index)
            for level in range(index.graph.level(slot) + 1):
                var count = edge_counts[count_offset]
                count_offset += 1
                var neighbors = List[UInt32](capacity=count)
                for _ in range(count):
                    neighbors.append(edge_slots[edge_offset])
                    edge_offset += 1
                index.graph.set_neighbors(slot, level, neighbors^)
                index.build_stats.directed_edges += count

        if point_count == 0:
            if entry_index != -1 or entry_level != -1:
                raise Error("empty HNSW cache entry point is invalid")
        elif (
            entry_index < 0
            or entry_index >= point_count
            or entry_level < 0
            or entry_level > index.graph.level(UInt32(entry_index))
        ):
            raise Error("HNSW cache entry point is invalid")
        else:
            index.entry_slot = Optional(UInt32(entry_index))
            index.entry_level = entry_level
        index.build_stats.slot_count = point_count
        index.build_stats.serialized_bytes = serialized_bytes
        return index^
