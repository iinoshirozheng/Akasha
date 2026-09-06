from akasha.common.config import (
    I8_MAX_SAFE_DIMENSION,
    MetricKind,
    ScalarKind,
)
from akasha.compute.metric import MetricDispatcher
from akasha.compute.quantization import (
    decode_bf16,
    decode_f16,
    decode_symmetric_i8,
    encode_bf16,
    encode_f16,
    encode_symmetric_i8,
    scaled_i8_accumulator,
    symmetric_i8_scale,
    validate_i8_decoded_component_bound,
)
from std.collections import Dict
from std.math import isfinite
from std.memory import bitcast


comptime HNSW_EMPTY_NEIGHBOR = UInt32.MAX
comptime _UINT32_MAX_AS_INT = 4_294_967_295
comptime _UINT16_MAX_AS_INT = 65_535


trait HnswGraphAccess:
    """Read-only graph contract used by the allocation-free search core."""

    def validate_search_ready(self) raises:
        ...

    def validate_structure(self) raises:
        ...

    def slot_count(self) -> Int:
        ...

    def graph_dimension(self) -> Int:
        ...

    def graph_m(self) -> Int:
        ...

    def graph_m0(self) -> Int:
        ...

    def id_at(self, slot: UInt32) raises -> Int:
        ...

    def level(self, slot: UInt32) raises -> Int:
        ...

    def is_current(self, slot: UInt32) -> Bool:
        ...

    def distance_to_slot(
        self,
        dispatcher: MetricDispatcher,
        query: List[Float32],
        slot: UInt32,
    ) raises -> Float32:
        ...

    def neighbor_count(self, slot: UInt32, level: Int) raises -> Int:
        ...

    def neighbor_at(
        self, slot: UInt32, level: Int, index: Int
    ) raises -> UInt32:
        ...


def _validate_append_slot_count(slot_count: UInt64) raises -> UInt32:
    """Return the next slot while reserving UInt32.MAX as the empty marker."""
    if slot_count >= UInt64(UInt32.MAX):
        raise Error("HNSW slot count exceeds the UInt32 edge address space")
    return UInt32(slot_count)


struct HnswStorage(HnswGraphAccess):
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

    F32 vectors use ``vector_scalars``. BF16/F16/I8 vectors use their native
    byte-width ``vector_bytes`` tape, and I8 dot additionally retains one F32
    scale per slot. Compact member-to-member distance never materializes or
    requantizes a full F32 vector.
    """

    var dimension: Int
    var m: Int
    var m0: Int
    var scalar_kind: ScalarKind
    var metric_kind: MetricKind
    var ids: List[Int]
    var levels: List[UInt16]
    var current_flags: List[Bool]
    var deleted_flags: List[Bool]
    var replaced_flags: List[Bool]
    var vector_scalars: List[Float32]
    var vector_bytes: List[UInt8]
    var vector_scales: List[Float32]
    var neighbor_bases: List[Int]
    var neighbor_count_bases: List[Int]
    var neighbor_counts: List[UInt32]
    var neighbor_slots: List[UInt32]
    var _current_slots: Dict[Int, UInt32]
    var _valid: Bool

    def __init__(
        out self,
        dimension: Int,
        m: Int,
        m0: Int,
        *,
        scalar_kind: ScalarKind = ScalarKind.f32(),
        metric_kind: MetricKind = MetricKind.l2(),
    ) raises:
        if dimension <= 0:
            raise Error("HNSW storage dimension must be positive")
        if dimension > _UINT32_MAX_AS_INT:
            raise Error("HNSW storage dimension must fit UInt32")
        if m <= 0 or m0 <= 0:
            raise Error("HNSW neighbor capacities must be positive")
        if m > _UINT32_MAX_AS_INT or m0 > _UINT32_MAX_AS_INT:
            raise Error("HNSW neighbor capacities must fit UInt32")
        if not scalar_kind.is_valid() or not metric_kind.is_valid():
            raise Error("HNSW storage scalar and metric kinds must be valid")
        if scalar_kind == ScalarKind.i8() and metric_kind == MetricKind.l2():
            raise Error("HNSW I8 storage does not support L2")
        if (
            scalar_kind == ScalarKind.i8()
            and dimension > I8_MAX_SAFE_DIMENSION
        ):
            raise Error("HNSW I8 dimension exceeds the Int32 accumulator bound")

        self.dimension = dimension
        self.m = m
        self.m0 = m0
        self.scalar_kind = scalar_kind.copy()
        self.metric_kind = metric_kind.copy()
        self.ids = List[Int]()
        self.levels = List[UInt16]()
        self.current_flags = List[Bool]()
        self.deleted_flags = List[Bool]()
        self.replaced_flags = List[Bool]()
        self.vector_scalars = List[Float32]()
        self.vector_bytes = List[UInt8]()
        self.vector_scales = List[Float32]()
        self.neighbor_bases = List[Int]()
        self.neighbor_count_bases = List[Int]()
        self.neighbor_counts = List[UInt32]()
        self.neighbor_slots = List[UInt32]()
        self._current_slots = Dict[Int, UInt32]()
        self._valid = True

    def is_valid(self) -> Bool:
        """Whether this graph may be exposed to approximate search."""
        return self._valid

    def validate_search_ready(self) raises:
        if not self._valid:
            raise Error("cannot search an invalid HNSW graph")

    def graph_dimension(self) -> Int:
        return self.dimension

    def graph_m(self) -> Int:
        return self.m

    def graph_m0(self) -> Int:
        return self.m0

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
        unit-normalized. Storage retains metric/scalar identity but never
        re-prepares vectors on the graph hot path.
        """
        var slot = self._append_unpublished(id, values, level)
        self._publish_current(id, slot)
        return slot

    def _append_unpublished(
        mut self, id: Int, values: List[Float32], level: Int
    ) raises -> UInt32:
        """Append a current lifecycle slot without publishing its ID map.

        Incremental HNSW linking uses this narrow staging state so a new slot
        can participate as the link endpoint while public ID resolution still
        names no replacement until every reciprocal link has succeeded.
        """
        var expected_values = self.dimension
        if self.scalar_kind == ScalarKind.i8():
            expected_values += 1
        if len(values) != expected_values:
            raise Error("HNSW vector dimension mismatch")
        if level < 0 or level > _UINT16_MAX_AS_INT:
            raise Error("HNSW level must fit UInt16")
        if Bool(self.current_slot(id)):
            raise Error("HNSW public ID already has a current slot")

        var encoded = List[UInt8]()
        var vector_scale = Float32(0.0)
        if self.scalar_kind == ScalarKind.bf16():
            encoded = List[UInt8](capacity=self.dimension * 2)
            for value in values:
                var bits = encode_bf16(value)
                encoded.append(UInt8(bits))
                encoded.append(UInt8(bits >> UInt16(8)))
        elif self.scalar_kind == ScalarKind.f16():
            encoded = List[UInt8](capacity=self.dimension * 2)
            for value in values:
                var bits = encode_f16(value)
                encoded.append(UInt8(bits))
                encoded.append(UInt8(bits >> UInt16(8)))
        elif self.scalar_kind == ScalarKind.i8():
            encoded = List[UInt8](capacity=self.dimension)
            vector_scale = values[self.dimension]
            if not isfinite(vector_scale) or vector_scale < 0.0:
                raise Error("HNSW I8 vector scale is invalid")
            var has_nonzero_code = False
            var maximum_code = 0
            for index in range(self.dimension):
                if (
                    not isfinite(values[index])
                    or values[index] < -127.0
                    or values[index] > 127.0
                    or Float32(Int(values[index])) != values[index]
                ):
                    raise Error("HNSW I8 vector code is invalid")
                if values[index] != 0.0:
                    has_nonzero_code = True
                var magnitude = Int(values[index])
                if magnitude < 0:
                    magnitude = -magnitude
                if magnitude > maximum_code:
                    maximum_code = magnitude
                encoded.append(
                    bitcast[DType.uint8](
                        Int8(Int(values[index]))
                    )
                )
            if self.metric_kind == MetricKind.cosine():
                if vector_scale != Float32(1.0 / 127.0):
                    raise Error("HNSW I8 cosine scale must be fixed")
                if not has_nonzero_code:
                    raise Error("HNSW I8 cosine vector must be non-zero")
            elif vector_scale == 0.0 and has_nonzero_code:
                raise Error("a zero HNSW I8 scale requires all-zero codes")
            else:
                validate_i8_decoded_component_bound(
                    maximum_code, vector_scale, self.dimension
                )

        var slot = _validate_append_slot_count(UInt64(len(self.ids)))
        var neighbor_cell_count = self.m0 + level * self.m
        var neighbor_base = len(self.neighbor_slots)
        var count_base = len(self.neighbor_counts)

        self.ids.append(id)
        self.levels.append(UInt16(level))
        self.current_flags.append(True)
        self.deleted_flags.append(False)
        self.replaced_flags.append(False)
        if self.scalar_kind == ScalarKind.f32():
            for index in range(self.dimension):
                self.vector_scalars.append(values[index])
        else:
            for byte in encoded:
                self.vector_bytes.append(byte)
            if (
                self.scalar_kind == ScalarKind.i8()
                and self.metric_kind == MetricKind.dot()
            ):
                self.vector_scales.append(vector_scale)
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
        var scalar = self.vector_offset(slot) + component
        if self.scalar_kind == ScalarKind.f32():
            return self.vector_scalars[scalar]
        if self.scalar_kind == ScalarKind.bf16():
            var offset = scalar * 2
            var bits = UInt16(self.vector_bytes[offset]) | (
                UInt16(self.vector_bytes[offset + 1]) << UInt16(8)
            )
            return decode_bf16(bits)
        if self.scalar_kind == ScalarKind.f16():
            var offset = scalar * 2
            var bits = UInt16(self.vector_bytes[offset]) | (
                UInt16(self.vector_bytes[offset + 1]) << UInt16(8)
            )
            return decode_f16(bits)
        var code = bitcast[DType.int8](self.vector_bytes[scalar])
        var magnitude = Int(code)
        if magnitude < 0:
            magnitude = -magnitude
        var scale = self._i8_vector_scale(slot)
        validate_i8_decoded_component_bound(
            magnitude, scale, self.dimension
        )
        return decode_symmetric_i8(code, scale)

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
        if not dispatcher.matches_storage_identity(
            self.metric_kind, self.scalar_kind, self.dimension
        ):
            raise Error("metric dispatcher identity does not match graph")
        var expected_query = self.dimension
        if self.scalar_kind == ScalarKind.i8():
            expected_query += 1
        if len(query) != expected_query:
            raise Error("prepared query dimension does not match graph")
        var offset = self.vector_offset(slot)
        return self._distance_query_to_offset(dispatcher, query, offset)

    def distance_between(
        self, dispatcher: MetricDispatcher, lhs: UInt32, rhs: UInt32
    ) raises -> Float32:
        dispatcher.require_supported_backend()
        if not dispatcher.matches_storage_identity(
            self.metric_kind, self.scalar_kind, self.dimension
        ):
            raise Error("metric dispatcher identity does not match graph")
        var lhs_offset = self.vector_offset(lhs)
        var rhs_offset = self.vector_offset(rhs)
        if self.scalar_kind == ScalarKind.i8():
            var accumulator = Int32(0)
            var lhs_maximum = 0
            var rhs_maximum = 0
            for component in range(self.dimension):
                var lhs_code = bitcast[DType.int8](
                    self.vector_bytes[lhs_offset + component]
                )
                var rhs_code = bitcast[DType.int8](
                    self.vector_bytes[rhs_offset + component]
                )
                var lhs_magnitude = Int(lhs_code)
                if lhs_magnitude < 0:
                    lhs_magnitude = -lhs_magnitude
                if lhs_magnitude > lhs_maximum:
                    lhs_maximum = lhs_magnitude
                var rhs_magnitude = Int(rhs_code)
                if rhs_magnitude < 0:
                    rhs_magnitude = -rhs_magnitude
                if rhs_magnitude > rhs_maximum:
                    rhs_maximum = rhs_magnitude
                accumulator += Int32(lhs_code) * Int32(rhs_code)
            var lhs_scale = self._i8_vector_scale(lhs)
            var rhs_scale = self._i8_vector_scale(rhs)
            validate_i8_decoded_component_bound(
                lhs_maximum, lhs_scale, self.dimension
            )
            validate_i8_decoded_component_bound(
                rhs_maximum, rhs_scale, self.dimension
            )
            var product = scaled_i8_accumulator(
                accumulator,
                lhs_scale,
                rhs_scale,
            )
            return dispatcher._finish_prepared_f32_accumulations(product, 0.0)
        var product = Float32(0.0)
        var squared_l2 = Float32(0.0)
        for component in range(self.dimension):
            var left = self.vector_value(lhs, component)
            var right = self.vector_value(rhs, component)
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
        if not self.scalar_kind.is_valid() or not self.metric_kind.is_valid():
            raise Error("HNSW storage scalar and metric kinds must be valid")
        if (
            self.scalar_kind == ScalarKind.i8()
            and (
                self.metric_kind == MetricKind.l2()
                or self.dimension > I8_MAX_SAFE_DIMENSION
            )
        ):
            raise Error("HNSW I8 storage configuration is invalid")

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
        if self.scalar_kind == ScalarKind.f32():
            if (
                len(self.vector_scalars) != expected_vector_scalars
                or len(self.vector_bytes) != 0
                or len(self.vector_scales) != 0
            ):
                raise Error("HNSW F32 vector tape has an invalid length")
        else:
            var width = 1 if self.scalar_kind == ScalarKind.i8() else 2
            if expected_vector_scalars > Int.MAX // width:
                raise Error("HNSW compact vector tape length overflows Int")
            if (
                len(self.vector_scalars) != 0
                or len(self.vector_bytes) != expected_vector_scalars * width
            ):
                raise Error("HNSW compact vector tape has an invalid length")
            if self.scalar_kind == ScalarKind.i8():
                var expected_scales = (
                    slots if self.metric_kind == MetricKind.dot() else 0
                )
                if len(self.vector_scales) != expected_scales:
                    raise Error("HNSW I8 scale tape has an invalid length")
                for slot_index in range(slots):
                    var has_nonzero_code = False
                    var maximum_code = 0
                    var base = slot_index * self.dimension
                    for component in range(self.dimension):
                        var code = bitcast[DType.int8](
                            self.vector_bytes[base + component]
                        )
                        if code == Int8(-128):
                            raise Error("HNSW I8 vector code is invalid")
                        if code != Int8(0):
                            has_nonzero_code = True
                        var magnitude = Int(code)
                        if magnitude < 0:
                            magnitude = -magnitude
                        if magnitude > maximum_code:
                            maximum_code = magnitude
                    var scale = Float32(1.0 / 127.0)
                    if self.metric_kind == MetricKind.dot():
                        scale = self.vector_scales[slot_index]
                    if not isfinite(scale) or scale < 0.0:
                        raise Error("HNSW I8 vector scale is invalid")
                    if self.metric_kind == MetricKind.cosine():
                        if scale != Float32(1.0 / 127.0):
                            raise Error("HNSW I8 cosine scale must be fixed")
                        if not has_nonzero_code:
                            raise Error("HNSW I8 cosine vector must be non-zero")
                    elif scale == 0.0 and has_nonzero_code:
                        raise Error(
                            "a zero HNSW I8 scale requires all-zero codes"
                        )
                    else:
                        validate_i8_decoded_component_bound(
                            maximum_code, scale, self.dimension
                        )
            elif len(self.vector_scales) != 0:
                raise Error("HNSW half vector tape cannot contain scales")
            else:
                for scalar in range(expected_vector_scalars):
                    var offset = scalar * 2
                    var bits = UInt16(self.vector_bytes[offset]) | (
                        UInt16(self.vector_bytes[offset + 1]) << UInt16(8)
                    )
                    if self.scalar_kind == ScalarKind.bf16():
                        _ = decode_bf16(bits)
                    else:
                        _ = decode_f16(bits)

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
                            raise Error("HNSW neighbor tape has a duplicate")
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
    ) raises -> Float32:
        if self.scalar_kind == ScalarKind.i8():
            var accumulator = Int32(0)
            var maximum_code = 0
            for component in range(self.dimension):
                var code = bitcast[DType.int8](
                    self.vector_bytes[offset + component]
                )
                var magnitude = Int(code)
                if magnitude < 0:
                    magnitude = -magnitude
                if magnitude > maximum_code:
                    maximum_code = magnitude
                accumulator += Int32(query[component]) * Int32(code)
            var slot = UInt32(offset // self.dimension)
            var vector_scale = self._i8_vector_scale(slot)
            validate_i8_decoded_component_bound(
                maximum_code, vector_scale, self.dimension
            )
            var product = scaled_i8_accumulator(
                accumulator,
                query[self.dimension],
                vector_scale,
            )
            return dispatcher._finish_prepared_f32_accumulations(product, 0.0)
        var product = Float32(0.0)
        var squared_l2 = Float32(0.0)
        for component in range(self.dimension):
            var left = query[component]
            var right = self.vector_value(
                UInt32(offset // self.dimension), component
            )
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
        return dispatcher._finish_prepared_f32_accumulations(
            product, squared_l2
        )

    def _i8_vector_scale(self, slot: UInt32) raises -> Float32:
        if self.scalar_kind != ScalarKind.i8():
            raise Error("HNSW graph does not use I8 vector scales")
        if self.metric_kind == MetricKind.cosine():
            return Float32(1.0 / 127.0)
        return self.vector_scales[Int(slot)]
