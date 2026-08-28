from akasha.compute.metric import MetricDispatcher
from std.collections import Dict


comptime HNSW_EMPTY_NEIGHBOR = UInt32.MAX
comptime _UINT32_MAX_AS_INT = 4_294_967_295
comptime _UINT16_MAX_AS_INT = 65_535


def _validate_append_slot_count(slot_count: UInt64) raises -> UInt32:
    """Return the next slot while reserving UInt32.MAX as the empty marker."""
    if slot_count >= UInt64(UInt32.MAX):
        raise Error("HNSW slot count exceeds the UInt32 edge address space")
    return UInt32(slot_count)


struct HnswStorage:
    """Append-only flat mutable storage for an HNSW graph.

    Public IDs are kept in ``ids`` and ``_current_slots`` only. Graph edges
    are UInt32 slot ordinals. Replaced and deleted slots remain readable as
    history, but their stale map entry is rejected by ``current_slot``; a
    later append of the same public ID simply overwrites that entry.

    Neighbor storage is two flat tapes. ``neighbor_bases`` points into the
    fixed-capacity ``neighbor_slots`` tape and ``neighbor_count_bases`` points
    into the per-level ``neighbor_counts`` tape. Every append reserves exactly
    ``m0 + level * m`` edge cells once, so graph mutation never creates nested
    neighbor collections.
    """

    var dimension: Int
    var m: Int
    var m0: Int
    var ids: List[Int]
    var levels: List[UInt16]
    var current_flags: List[Bool]
    var deleted_flags: List[Bool]
    var replaced_flags: List[Bool]
    var vector_scalars: List[Float32]
    var neighbor_bases: List[Int]
    var neighbor_count_bases: List[Int]
    var neighbor_counts: List[UInt32]
    var neighbor_slots: List[UInt32]
    var _current_slots: Dict[Int, UInt32]
    var _valid: Bool

    def __init__(out self, dimension: Int, m: Int, m0: Int) raises:
        if dimension <= 0:
            raise Error("HNSW storage dimension must be positive")
        if dimension > _UINT32_MAX_AS_INT:
            raise Error("HNSW storage dimension must fit UInt32")
        if m <= 0 or m0 <= 0:
            raise Error("HNSW neighbor capacities must be positive")
        if m > _UINT32_MAX_AS_INT or m0 > _UINT32_MAX_AS_INT:
            raise Error("HNSW neighbor capacities must fit UInt32")

        self.dimension = dimension
        self.m = m
        self.m0 = m0
        self.ids = List[Int]()
        self.levels = List[UInt16]()
        self.current_flags = List[Bool]()
        self.deleted_flags = List[Bool]()
        self.replaced_flags = List[Bool]()
        self.vector_scalars = List[Float32]()
        self.neighbor_bases = List[Int]()
        self.neighbor_count_bases = List[Int]()
        self.neighbor_counts = List[UInt32]()
        self.neighbor_slots = List[UInt32]()
        self._current_slots = Dict[Int, UInt32]()
        self._valid = True

    def is_valid(self) -> Bool:
        """Whether this graph may be exposed to approximate search."""
        return self._valid

    def mark_invalid(mut self):
        """Permanently quarantine a graph after an interrupted link update."""
        self._valid = False

    def slot_count(self) -> Int:
        return len(self.ids)

    def append(
        mut self, id: Int, var values: List[Float32], level: Int
    ) raises -> UInt32:
        """Append a prepared graph vector and reserve its bounded edge cells.

        ``values`` must already have been produced by
        ``MetricDispatcher.prepare_graph_vector`` for the dispatcher used by
        graph construction and search. In particular, cosine vectors must be
        unit-normalized. This storage intentionally does not retain a metric
        or re-prepare vectors on the graph hot path.
        """
        var slot = self._append_unpublished(id, values^, level)
        self._publish_current(id, slot)
        return slot

    def _append_unpublished(
        mut self, id: Int, var values: List[Float32], level: Int
    ) raises -> UInt32:
        """Append a current lifecycle slot without publishing its ID map.

        Incremental HNSW linking uses this narrow staging state so a new slot
        can participate as the link endpoint while public ID resolution still
        names no replacement until every reciprocal link has succeeded.
        """
        if len(values) != self.dimension:
            raise Error("HNSW vector dimension mismatch")
        if level < 0 or level > _UINT16_MAX_AS_INT:
            raise Error("HNSW level must fit UInt16")
        if Bool(self.current_slot(id)):
            raise Error("HNSW public ID already has a current slot")

        var slot = _validate_append_slot_count(UInt64(len(self.ids)))
        var neighbor_cell_count = self.m0 + level * self.m
        var neighbor_base = len(self.neighbor_slots)
        var count_base = len(self.neighbor_counts)

        self.ids.append(id)
        self.levels.append(UInt16(level))
        self.current_flags.append(True)
        self.deleted_flags.append(False)
        self.replaced_flags.append(False)
        for index in range(self.dimension):
            self.vector_scalars.append(values[index])
        self.neighbor_bases.append(neighbor_base)
        self.neighbor_count_bases.append(count_base)
        for _ in range(level + 1):
            self.neighbor_counts.append(UInt32(0))
        for _ in range(neighbor_cell_count):
            self.neighbor_slots.append(HNSW_EMPTY_NEIGHBOR)
        return slot

    def _publish_current(mut self, id: Int, slot: UInt32) raises:
        """Atomically publish an already-appended current slot by public ID."""
        var index = self._slot_index(slot)
        if self.ids[index] != id or not self.current_flags[index]:
            raise Error("HNSW current-slot publication is inconsistent")
        if Bool(self.current_slot(id)):
            raise Error("HNSW public ID already has a current slot")
        self._current_slots[id] = slot

    def current_slot(self, id: Int) -> Optional[UInt32]:
        if id not in self._current_slots:
            return Optional[UInt32]()
        var slot: UInt32
        try:
            slot = self._current_slots[id]
        except:
            return Optional[UInt32]()
        if not self.is_current(slot):
            return Optional[UInt32]()
        if self.ids[Int(slot)] != id:
            return Optional[UInt32]()
        return Optional(slot)

    def mark_replaced(mut self, id: Int) raises -> UInt32:
        var optional = self.current_slot(id)
        if not Bool(optional):
            raise Error("HNSW public ID has no current slot to replace")
        var slot = optional.value()
        var index = Int(slot)
        _ = self._current_slots.pop(id)
        self.current_flags[index] = False
        self.replaced_flags[index] = True
        return slot

    def mark_deleted(mut self, id: Int) -> Bool:
        var optional = self.current_slot(id)
        if not Bool(optional):
            return False
        var index = Int(optional.value())
        try:
            _ = self._current_slots.pop(id)
        except:
            return False
        self.current_flags[index] = False
        self.deleted_flags[index] = True
        return True

    def is_current(self, slot: UInt32) -> Bool:
        var index = UInt64(slot)
        if index >= UInt64(len(self.current_flags)):
            return False
        return self.current_flags[Int(index)]

    def is_deleted(self, slot: UInt32) -> Bool:
        var index = UInt64(slot)
        if index >= UInt64(len(self.deleted_flags)):
            return False
        return self.deleted_flags[Int(index)]

    def is_replaced(self, slot: UInt32) -> Bool:
        var index = UInt64(slot)
        if index >= UInt64(len(self.replaced_flags)):
            return False
        return self.replaced_flags[Int(index)]

    def id_at(self, slot: UInt32) raises -> Int:
        var index = self._slot_index(slot)
        return self.ids[index]

    def level(self, slot: UInt32) raises -> Int:
        var index = self._slot_index(slot)
        return Int(self.levels[index])

    def vector_offset(self, slot: UInt32) raises -> Int:
        return self._slot_index(slot) * self.dimension

    def vector_value(self, slot: UInt32, component: Int) raises -> Float32:
        if component < 0 or component >= self.dimension:
            raise Error("HNSW vector component out of bounds")
        return self.vector_scalars[self.vector_offset(slot) + component]

    def distance_to_slot(
        self,
        dispatcher: MetricDispatcher,
        query: List[Float32],
        slot: UInt32,
    ) raises -> Float32:
        """Score a prepared query against a flat stored vector without copies.

        This is the scalar flat-offset bridge until the one-time SIMD backend
        dispatch introduced by the later backend task. It deliberately avoids
        materializing a temporary List for every graph edge.
        """
        dispatcher.require_supported_backend()
        if dispatcher.dimension() != self.dimension:
            raise Error("metric dispatcher dimension does not match graph")
        if len(query) != self.dimension:
            raise Error("prepared query dimension does not match graph")
        var offset = self.vector_offset(slot)
        return self._distance_query_to_offset(dispatcher, query, offset)

    def distance_between(
        self, dispatcher: MetricDispatcher, lhs: UInt32, rhs: UInt32
    ) raises -> Float32:
        dispatcher.require_supported_backend()
        if dispatcher.dimension() != self.dimension:
            raise Error("metric dispatcher dimension does not match graph")
        var lhs_offset = self.vector_offset(lhs)
        var rhs_offset = self.vector_offset(rhs)
        var product = Float32(0.0)
        var squared_l2 = Float32(0.0)
        for component in range(self.dimension):
            var left = self.vector_scalars[lhs_offset + component]
            var right = self.vector_scalars[rhs_offset + component]
            product += left * right
            var difference = left - right
            squared_l2 += difference * difference
        return self._finish_distance(dispatcher, product, squared_l2)

    def level_capacity(self, slot: UInt32, level: Int) raises -> Int:
        self._validate_level(slot, level)
        if level == 0:
            return self.m0
        return self.m

    def allocated_neighbor_slot_count(self, slot: UInt32) raises -> Int:
        return self.m0 + self.level(slot) * self.m

    def neighbor_count(self, slot: UInt32, level: Int) raises -> Int:
        var count_index = self._count_index(slot, level)
        return Int(self.neighbor_counts[count_index])

    def neighbor_at(
        self, slot: UInt32, level: Int, index: Int
    ) raises -> UInt32:
        var count = self.neighbor_count(slot, level)
        if index < 0 or index >= count:
            raise Error("HNSW neighbor index out of bounds")
        return self.neighbor_slots[self._level_base(slot, level) + index]

    def contains_neighbor(
        self, slot: UInt32, level: Int, neighbor: UInt32
    ) raises -> Bool:
        self._validate_neighbor(slot, neighbor)
        var count = self.neighbor_count(slot, level)
        var base = self._level_base(slot, level)
        for index in range(count):
            if self.neighbor_slots[base + index] == neighbor:
                return True
        return False

    def add_neighbor(
        mut self, slot: UInt32, level: Int, neighbor: UInt32
    ) raises -> Bool:
        self._validate_neighbor(slot, neighbor)
        if self.contains_neighbor(slot, level, neighbor):
            return False
        var count = self.neighbor_count(slot, level)
        if count >= self.level_capacity(slot, level):
            raise Error("HNSW neighbor level is at capacity")
        self.neighbor_slots[self._level_base(slot, level) + count] = neighbor
        self.neighbor_counts[self._count_index(slot, level)] = UInt32(count + 1)
        return True

    def remove_neighbor(
        mut self, slot: UInt32, level: Int, neighbor: UInt32
    ) raises -> Bool:
        self._validate_neighbor(slot, neighbor)
        var count = self.neighbor_count(slot, level)
        var base = self._level_base(slot, level)
        var found = -1
        for index in range(count):
            if self.neighbor_slots[base + index] == neighbor:
                found = index
                break
        if found < 0:
            return False
        for index in range(found, count - 1):
            self.neighbor_slots[base + index] = self.neighbor_slots[
                base + index + 1
            ]
        self.neighbor_slots[base + count - 1] = HNSW_EMPTY_NEIGHBOR
        self.neighbor_counts[self._count_index(slot, level)] = UInt32(count - 1)
        return True

    def set_neighbors(
        mut self, slot: UInt32, level: Int, values: List[UInt32]
    ) raises:
        var capacity = self.level_capacity(slot, level)
        if len(values) > capacity:
            raise Error("HNSW neighbor list exceeds level capacity")
        for index in range(len(values)):
            self._validate_neighbor(slot, values[index])
            for earlier in range(index):
                if values[earlier] == values[index]:
                    raise Error("HNSW neighbor list contains a duplicate")

        var base = self._level_base(slot, level)
        for index in range(capacity):
            self.neighbor_slots[base + index] = HNSW_EMPTY_NEIGHBOR
        for index in range(len(values)):
            self.neighbor_slots[base + index] = values[index]
        self.neighbor_counts[self._count_index(slot, level)] = UInt32(
            len(values)
        )

    def validate_structure(self) raises:
        """Validate all flat-tape bounds before reading either tape.

        Phase one validates configuration, slot columns, packed bases, and
        checked total lengths. Phase two may then safely index neighbor counts
        and edge cells to validate their contents.
        """
        if self.dimension <= 0 or self.dimension > _UINT32_MAX_AS_INT:
            raise Error("HNSW storage dimension is invalid")
        if self.m <= 0 or self.m0 <= 0:
            raise Error("HNSW neighbor capacities are invalid")
        if self.m > _UINT32_MAX_AS_INT or self.m0 > _UINT32_MAX_AS_INT:
            raise Error("HNSW neighbor capacities must fit UInt32")

        # Phase one: prove every tape length and base offset before indexing
        # neighbor_counts or neighbor_slots.
        var slots = len(self.ids)
        if UInt64(slots) > UInt64(UInt32.MAX):
            raise Error("HNSW slot count exceeds the UInt32 edge address space")
        if (
            len(self.levels) != slots
            or len(self.current_flags) != slots
            or len(self.deleted_flags) != slots
            or len(self.replaced_flags) != slots
            or len(self.neighbor_bases) != slots
            or len(self.neighbor_count_bases) != slots
        ):
            raise Error("HNSW slot columns have inconsistent lengths")
        if slots > 0 and self.dimension > Int.MAX // slots:
            raise Error("HNSW flat vector tape length overflows Int")
        var expected_vector_scalars = slots * self.dimension
        if len(self.vector_scalars) != expected_vector_scalars:
            raise Error("HNSW flat vector tape has an invalid length")

        var expected_neighbor_base = 0
        var expected_count_base = 0
        var current_count = 0
        for index in range(slots):
            if self.neighbor_bases[index] != expected_neighbor_base:
                raise Error("HNSW neighbor base offsets are not packed")
            if self.neighbor_count_bases[index] != expected_count_base:
                raise Error("HNSW neighbor count offsets are not packed")
            var node_level = Int(self.levels[index])
            if node_level < 0 or node_level > _UINT16_MAX_AS_INT:
                raise Error("HNSW stored level does not fit UInt16")
            if node_level > (Int.MAX - self.m0) // self.m:
                raise Error("HNSW node neighbor allocation overflows Int")
            var node_neighbor_cells = self.m0 + node_level * self.m
            if node_neighbor_cells > Int.MAX - expected_neighbor_base:
                raise Error("HNSW neighbor tape length overflows Int")
            expected_neighbor_base += node_neighbor_cells
            var node_count_cells = node_level + 1
            if node_count_cells > Int.MAX - expected_count_base:
                raise Error("HNSW neighbor count tape length overflows Int")
            expected_count_base += node_count_cells

        if expected_neighbor_base != len(self.neighbor_slots):
            raise Error("HNSW flat neighbor tape has an invalid length")
        if expected_count_base != len(self.neighbor_counts):
            raise Error("HNSW flat neighbor count tape has an invalid length")

        # Phase two: exact lengths and packed bases now make all tape indexing
        # below safe. Validate lifecycle state, counts, and edge contents.
        for index in range(slots):
            var slot = UInt32(index)
            var node_level = Int(self.levels[index])

            var state_count = Int(self.current_flags[index])
            state_count += Int(self.deleted_flags[index])
            state_count += Int(self.replaced_flags[index])
            if state_count != 1:
                raise Error("HNSW slot lifecycle flags are inconsistent")
            if self.current_flags[index]:
                current_count += 1
                var current = self.current_slot(self.ids[index])
                if not Bool(current) or current.value() != slot:
                    raise Error("HNSW current ID map is inconsistent")

            for graph_level in range(node_level + 1):
                var capacity = self.level_capacity(slot, graph_level)
                var count = self.neighbor_count(slot, graph_level)
                if count < 0 or count > capacity:
                    raise Error("HNSW neighbor count exceeds capacity")
                var base = self._level_base(slot, graph_level)
                var seen_neighbors = Dict[Int, Bool]()
                for edge_index in range(capacity):
                    var neighbor = self.neighbor_slots[base + edge_index]
                    if edge_index < count:
                        self._validate_neighbor(slot, neighbor)
                        var key = Int(neighbor)
                        if key in seen_neighbors:
                            raise Error(
                                "HNSW neighbor tape has a duplicate"
                            )
                        seen_neighbors[key] = True
                    elif neighbor != HNSW_EMPTY_NEIGHBOR:
                        raise Error("HNSW unused neighbor cell is not empty")

        if len(self._current_slots) != current_count:
            raise Error("HNSW current ID map contains stale entries")
        for entry in self._current_slots.items():
            var mapped = self.current_slot(entry.key)
            if not Bool(mapped) or mapped.value() != entry.value:
                raise Error("HNSW current ID map contains an invalid entry")

    def _slot_index(self, slot: UInt32) raises -> Int:
        if UInt64(slot) >= UInt64(len(self.ids)):
            raise Error("HNSW slot out of bounds")
        return Int(slot)

    def _validate_level(self, slot: UInt32, level: Int) raises:
        if level < 0 or level > self.level(slot):
            raise Error("HNSW graph level out of bounds")

    def _count_index(self, slot: UInt32, level: Int) raises -> Int:
        self._validate_level(slot, level)
        return self.neighbor_count_bases[Int(slot)] + level

    def _level_base(self, slot: UInt32, level: Int) raises -> Int:
        self._validate_level(slot, level)
        var base = self.neighbor_bases[Int(slot)]
        if level == 0:
            return base
        return base + self.m0 + (level - 1) * self.m

    def _validate_neighbor(self, slot: UInt32, neighbor: UInt32) raises:
        _ = self._slot_index(slot)
        if neighbor == HNSW_EMPTY_NEIGHBOR:
            raise Error("HNSW empty-neighbor sentinel cannot be an edge")
        _ = self._slot_index(neighbor)
        if neighbor == slot:
            raise Error("HNSW self edges are not allowed")

    def _distance_query_to_offset(
        self,
        dispatcher: MetricDispatcher,
        query: List[Float32],
        offset: Int,
    ) -> Float32:
        var product = Float32(0.0)
        var squared_l2 = Float32(0.0)
        for component in range(self.dimension):
            var left = query[component]
            var right = self.vector_scalars[offset + component]
            product += left * right
            var difference = left - right
            squared_l2 += difference * difference
        return self._finish_distance(dispatcher, product, squared_l2)

    def _finish_distance(
        self,
        dispatcher: MetricDispatcher,
        product: Float32,
        squared_l2: Float32,
    ) -> Float32:
        if dispatcher.metric_name() == "l2":
            return squared_l2
        if dispatcher.metric_name() == "dot":
            return -product
        var clamped = product
        if clamped < -1.0:
            clamped = -1.0
        elif clamped > 1.0:
            clamped = 1.0
        return 1.0 - clamped
