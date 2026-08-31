from akasha.common.config import CollectionConfig, ScalarKind
from akasha.index.hnsw import HnswIndex
from akasha.storage.checksum import BinaryReader, BinaryWriter, crc32_range
from akasha.storage.filesystem import read_file_bytes_bounded, write_file_sync
from std.collections import Dict
from std.sys.info import is_64bit


comptime HNSW_SNAPSHOT_VERSION = UInt16(1)
comptime HNSW_SNAPSHOT_HEADER_BYTES = 160
comptime HNSW_SNAPSHOT_NODE_BYTES = 40
comptime _CHECKSUM_BYTES = 4
comptime _MAX_SNAPSHOT_BYTES = 512 * 1024 * 1024
comptime _MAX_DECODE_ALLOCATION_BYTES = UInt64(512 * 1024 * 1024)
comptime _MAX_ALLOCATION_RATIO = UInt64(32)
comptime _MIN_ALLOCATION_BUDGET = UInt64(4_096)
comptime _SLOT_PEAK_BYTES = UInt64(128)
comptime _CURRENT_MAP_PEAK_BYTES = UInt64(192)
comptime _LEVEL_VALIDATION_PEAK_BYTES = UInt64(104)
comptime _EDGE_VALIDATION_PEAK_BYTES = UInt64(108)
comptime _MAX_SLOTS = 10_000_000
comptime _CURRENT_FLAG = UInt8(1)
comptime _DELETED_FLAG = UInt8(2)
comptime _REPLACED_FLAG = UInt8(4)
comptime _ENTRY_NONE = UInt64.MAX


struct HnswSnapshotInfo(Movable):
    """Metadata for one fully written and validated HNSW sidecar."""

    var version: UInt16
    var sequence: UInt64
    var config_fingerprint: UInt64
    var checksum: UInt32
    var slot_count: UInt64
    var live_point_count: UInt64
    var directed_edge_count: UInt64
    var byte_length: UInt64

    def __init__(
        out self,
        sequence: UInt64,
        config_fingerprint: UInt64,
        checksum: UInt32,
        slot_count: UInt64,
        live_point_count: UInt64,
        directed_edge_count: UInt64,
        byte_length: UInt64,
    ):
        self.version = HNSW_SNAPSHOT_VERSION
        self.sequence = sequence
        self.config_fingerprint = config_fingerprint
        self.checksum = checksum
        self.slot_count = slot_count
        self.live_point_count = live_point_count
        self.directed_edge_count = directed_edge_count
        self.byte_length = byte_length


struct HnswSnapshotEligibility(Movable):
    """Typed result of checking whether a graph has a v1 representation."""

    var eligible: Bool
    var graph_usable: Bool
    var encoded_bytes: UInt64
    var reason: String

    def __init__(
        out self,
        eligible: Bool,
        graph_usable: Bool,
        encoded_bytes: UInt64,
        reason: String,
    ):
        self.eligible = eligible
        self.graph_usable = graph_usable
        self.encoded_bytes = encoded_bytes
        self.reason = String(copy=reason)


struct _DecodedNodes(Movable):
    var ids: List[Int]
    var levels: List[Int]
    var flags: List[UInt8]
    var edge_counts: List[Int]
    var level_count: Int
    var directed_edge_count: Int
    var live_count: Int

    def __init__(out self, capacity: Int):
        self.ids = List[Int](capacity=capacity)
        self.levels = List[Int](capacity=capacity)
        self.flags = List[UInt8](capacity=capacity)
        self.edge_counts = List[Int](capacity=capacity)
        self.level_count = 0
        self.directed_edge_count = 0
        self.live_count = 0


def encode_hnsw_snapshot(
    index: HnswIndex, sequence: UInt64
) raises -> List[UInt8]:
    """Encode one deterministic, owned HNSW snapshot in sectioned v1."""
    _require_v1_config(index.config)
    index.validate_structure()
    _validate_snapshot_graph_vectors(index)

    var slots = index.graph.slot_count()
    if slots > _MAX_SLOTS:
        raise Error("HNSW snapshot slot count exceeds implementation limit")
    var level_cells = UInt64(0)
    var directed_edges = UInt64(0)
    var allocated_neighbor_cells = UInt64(0)
    var live_points = UInt64(0)
    for slot_index in range(slots):
        var slot = UInt32(slot_index)
        level_cells = _checked_add_u64(
            level_cells, UInt64(index.graph.level(slot)) + UInt64(1)
        )
        allocated_neighbor_cells = _checked_add_u64(
            allocated_neighbor_cells,
            UInt64(index.graph.allocated_neighbor_slot_count(slot)),
        )
        if index.graph.is_current(slot):
            live_points += UInt64(1)
        for level in range(index.graph.level(slot) + 1):
            directed_edges = _checked_add_u64(
                directed_edges,
                UInt64(index.graph.neighbor_count(slot, level)),
            )

    var node_length = _checked_mul_u64(
        UInt64(slots), UInt64(HNSW_SNAPSHOT_NODE_BYTES)
    )
    var vector_scalars = _checked_mul_u64(
        UInt64(slots), UInt64(index.config.dimension)
    )
    var vector_length = _checked_mul_u64(vector_scalars, UInt64(4))
    var count_length = _checked_mul_u64(level_cells, UInt64(4))
    var edge_length = _checked_mul_u64(directed_edges, UInt64(4))
    var node_offset = UInt64(HNSW_SNAPSHOT_HEADER_BYTES)
    var vector_offset = _align8(_checked_add_u64(node_offset, node_length))
    var count_offset = _align8(_checked_add_u64(vector_offset, vector_length))
    var edge_offset = _align8(_checked_add_u64(count_offset, count_length))
    var body_length = _checked_add_u64(edge_offset, edge_length)
    var file_length = _checked_add_u64(body_length, UInt64(_CHECKSUM_BYTES))
    _require_supported_file_length(file_length)
    _validate_decode_allocation(
        file_length,
        UInt64(slots),
        UInt64(index.config.dimension),
        level_cells,
        directed_edges,
        allocated_neighbor_cells,
    )

    var writer = BinaryWriter()
    _write_magic(writer)
    writer.write_u16(HNSW_SNAPSHOT_VERSION)
    writer.write_u16(UInt16(0))
    writer.write_u32(UInt32(HNSW_SNAPSHOT_HEADER_BYTES))
    writer.write_u32(UInt32(0))
    writer.write_u64(index.config.fingerprint())
    writer.write_u64(sequence)
    writer.write_u32(UInt32(index.config.dimension))
    writer.write_u8(index.config.ann_metric.tag())
    writer.write_u8(index.config.scalar_kind.tag())
    writer.write_u16(UInt16(index.config.m))
    writer.write_u16(UInt16(index.config.m0))
    writer.write_u16(UInt16(index.config.max_level))
    writer.write_u32(UInt32(0))
    writer.write_u64(UInt64(slots))
    writer.write_u64(live_points)
    writer.write_u64(directed_edges)
    if Bool(index.entry_slot):
        writer.write_u64(UInt64(index.entry_slot.value()))
    else:
        writer.write_u64(_ENTRY_NONE)
    writer.write_i64(Int64(index.entry_level))
    writer.write_u64(node_offset)
    writer.write_u64(node_length)
    writer.write_u64(vector_offset)
    writer.write_u64(vector_length)
    writer.write_u64(count_offset)
    writer.write_u64(count_length)
    writer.write_u64(edge_offset)
    writer.write_u64(edge_length)
    writer.write_u64(UInt64(0))

    var count_base = UInt64(0)
    var edge_base = UInt64(0)
    for slot_index in range(slots):
        var slot = UInt32(slot_index)
        var node_edge_count = UInt64(0)
        for level in range(index.graph.level(slot) + 1):
            node_edge_count = _checked_add_u64(
                node_edge_count,
                UInt64(index.graph.neighbor_count(slot, level)),
            )
        writer.write_i64(Int64(index.graph.id_at(slot)))
        writer.write_u16(UInt16(index.graph.level(slot)))
        writer.write_u8(_slot_flag(index, slot))
        writer.write_u8(UInt8(0))
        writer.write_u32(UInt32(0))
        writer.write_u64(count_base)
        writer.write_u64(edge_base)
        writer.write_u64(node_edge_count)
        count_base = _checked_add_u64(
            count_base, UInt64(index.graph.level(slot)) + UInt64(1)
        )
        edge_base = _checked_add_u64(edge_base, node_edge_count)

    _write_zeros(writer, Int(vector_offset - (node_offset + node_length)))
    for slot_index in range(slots):
        var slot = UInt32(slot_index)
        for component in range(index.config.dimension):
            writer.write_f32(index.graph.vector_value(slot, component))

    _write_zeros(writer, Int(count_offset - (vector_offset + vector_length)))
    for slot_index in range(slots):
        var slot = UInt32(slot_index)
        for level in range(index.graph.level(slot) + 1):
            writer.write_u32(UInt32(index.graph.neighbor_count(slot, level)))

    _write_zeros(writer, Int(edge_offset - (count_offset + count_length)))
    for slot_index in range(slots):
        var slot = UInt32(slot_index)
        for level in range(index.graph.level(slot) + 1):
            for edge_index in range(index.graph.neighbor_count(slot, level)):
                writer.write_u32(
                    index.graph.neighbor_at(slot, level, edge_index)
                )

    var body = writer.take_bytes()
    if UInt64(len(body)) != body_length:
        raise Error("HNSW snapshot encoder size mismatch")
    var checksum = crc32_range(body, 0, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def hnsw_snapshot_max_bytes() -> UInt64:
    """Return the durable v1 codec's maximum representable byte length."""
    return UInt64(_MAX_SNAPSHOT_BYTES)


def hnsw_snapshot_eligibility(
    index: HnswIndex, maximum_bytes: UInt64
) raises -> HnswSnapshotEligibility:
    """Preflight v1 representation without allocating the encoded payload."""
    if not is_64bit():
        return HnswSnapshotEligibility(
            False, False, 0, "unsupported_target"
        )
    if index.config.scalar_kind != ScalarKind.f32():
        return HnswSnapshotEligibility(
            False, False, 0, "unsupported_scalar"
        )
    try:
        index.config.validate()
        index.validate_structure()
        _validate_snapshot_graph_vectors(index)
    except:
        return HnswSnapshotEligibility(False, False, 0, "invalid_graph")
    try:
        var slots = index.graph.slot_count()
        if slots > _MAX_SLOTS:
            return HnswSnapshotEligibility(
                False, True, 0, "slot_limit"
            )
        var level_cells = UInt64(0)
        var directed_edges = UInt64(0)
        var allocated_neighbor_cells = UInt64(0)
        for slot_index in range(slots):
            var slot = UInt32(slot_index)
            level_cells = _checked_add_u64(
                level_cells, UInt64(index.graph.level(slot)) + UInt64(1)
            )
            allocated_neighbor_cells = _checked_add_u64(
                allocated_neighbor_cells,
                UInt64(index.graph.allocated_neighbor_slot_count(slot)),
            )
            for level in range(index.graph.level(slot) + 1):
                directed_edges = _checked_add_u64(
                    directed_edges,
                    UInt64(index.graph.neighbor_count(slot, level)),
                )
        var node_length = _checked_mul_u64(
            UInt64(slots), UInt64(HNSW_SNAPSHOT_NODE_BYTES)
        )
        var vector_length = _checked_mul_u64(
            _checked_mul_u64(
                UInt64(slots), UInt64(index.config.dimension)
            ),
            UInt64(4),
        )
        var count_length = _checked_mul_u64(level_cells, UInt64(4))
        var edge_length = _checked_mul_u64(directed_edges, UInt64(4))
        var vector_offset = _align8(
            _checked_add_u64(
                UInt64(HNSW_SNAPSHOT_HEADER_BYTES), node_length
            )
        )
        var count_offset = _align8(
            _checked_add_u64(vector_offset, vector_length)
        )
        var edge_offset = _align8(
            _checked_add_u64(count_offset, count_length)
        )
        var file_length = _checked_add_u64(
            _checked_add_u64(edge_offset, edge_length),
            UInt64(_CHECKSUM_BYTES),
        )
        if (
            file_length > UInt64(_MAX_SNAPSHOT_BYTES)
            or file_length > UInt64(Int.MAX)
            or file_length > maximum_bytes
        ):
            return HnswSnapshotEligibility(
                False, True, file_length, "size_limit"
            )
        try:
            _validate_decode_allocation(
                file_length,
                UInt64(slots),
                UInt64(index.config.dimension),
                level_cells,
                directed_edges,
                allocated_neighbor_cells,
            )
        except:
            return HnswSnapshotEligibility(
                False, True, file_length, "allocation_limit"
            )
        return HnswSnapshotEligibility(True, True, file_length, "")
    except:
        return HnswSnapshotEligibility(False, True, 0, "codec_limit")


def decode_hnsw_snapshot_owned(
    var bytes: List[UInt8],
    config: CollectionConfig,
    sequence: UInt64,
) raises -> HnswIndex:
    """Fully validate and materialize one owned HNSW snapshot."""
    _require_v1_config(config)
    if len(bytes) < HNSW_SNAPSHOT_HEADER_BYTES + _CHECKSUM_BYTES:
        raise Error("HNSW snapshot is truncated")
    if len(bytes) > _MAX_SNAPSHOT_BYTES:
        raise Error("HNSW snapshot exceeds implementation size limit")
    var checksum_offset = len(bytes) - _CHECKSUM_BYTES
    var stored_checksum = _read_u32_at(bytes, checksum_offset)
    if crc32_range(bytes, 0, checksum_offset) != stored_checksum:
        raise Error("HNSW snapshot checksum mismatch")

    var encoded_size = len(bytes)
    var reader = BinaryReader(bytes^)
    _read_magic(reader)
    if reader.read_u16() != HNSW_SNAPSHOT_VERSION:
        raise Error("unsupported HNSW snapshot version")
    if reader.read_u16() != UInt16(0):
        raise Error("unsupported HNSW snapshot flags")
    if reader.read_u32() != UInt32(HNSW_SNAPSHOT_HEADER_BYTES):
        raise Error("unsupported HNSW snapshot header size")
    if reader.read_u32() != UInt32(0):
        raise Error("nonzero HNSW snapshot reserved header bytes")
    if reader.read_u64() != config.fingerprint():
        raise Error("HNSW snapshot configuration fingerprint mismatch")
    if reader.read_u64() != sequence:
        raise Error("HNSW snapshot sequence mismatch")
    if reader.read_u32() != UInt32(config.dimension):
        raise Error("HNSW snapshot dimension mismatch")
    if reader.read_u8() != config.ann_metric.tag():
        raise Error("HNSW snapshot metric mismatch")
    if reader.read_u8() != config.scalar_kind.tag():
        raise Error("HNSW snapshot scalar kind mismatch")
    if (
        reader.read_u16() != UInt16(config.m)
        or reader.read_u16() != UInt16(config.m0)
        or reader.read_u16() != UInt16(config.max_level)
    ):
        raise Error("HNSW snapshot graph configuration mismatch")
    if reader.read_u32() != UInt32(0):
        raise Error("nonzero HNSW snapshot reserved config bytes")

    var slot_count_u64 = reader.read_u64()
    var live_count_u64 = reader.read_u64()
    var directed_edges_u64 = reader.read_u64()
    var entry_slot_u64 = reader.read_u64()
    var entry_level_i64 = reader.read_i64()
    var node_offset = reader.read_u64()
    var node_length = reader.read_u64()
    var vector_offset = reader.read_u64()
    var vector_length = reader.read_u64()
    var count_offset = reader.read_u64()
    var count_length = reader.read_u64()
    var edge_offset = reader.read_u64()
    var edge_length = reader.read_u64()
    if reader.read_u64() != UInt64(0):
        raise Error("nonzero HNSW snapshot reserved extension bytes")
    if reader.position() != HNSW_SNAPSHOT_HEADER_BYTES:
        raise Error("HNSW snapshot header decoder size mismatch")

    var slots = _bounded_count(slot_count_u64, _MAX_SLOTS, "slot")
    if live_count_u64 > slot_count_u64:
        raise Error("HNSW snapshot live count exceeds slot count")
    var live_count = _bounded_count(live_count_u64, slots, "live point")
    var directed_edges = _bounded_count(
        directed_edges_u64, Int.MAX, "directed edge"
    )
    if count_length % UInt64(4) != UInt64(0):
        raise Error("HNSW snapshot count section length is invalid")
    var level_count = _bounded_count(
        count_length // UInt64(4), Int.MAX, "level count"
    )
    # This lower-bound peak check deliberately precedes all attacker-sized
    # node lists and dictionaries. It assumes every slot may be current because
    # the encoded live count is not trusted until the node scan completes.
    _validate_hnsw_snapshot_header_allocation(
        UInt64(encoded_size),
        slot_count_u64,
        UInt64(config.dimension),
        UInt64(level_count),
        directed_edges_u64,
        UInt64(config.m0),
    )
    _validate_section_layout(
        UInt64(encoded_size),
        slot_count_u64,
        UInt64(config.dimension),
        directed_edges_u64,
        node_offset,
        node_length,
        vector_offset,
        vector_length,
        count_offset,
        count_length,
        edge_offset,
        edge_length,
    )

    var nodes = _DecodedNodes(slots)
    var allocated_neighbor_cells = UInt64(0)
    var seen_current_ids = Dict[Int, Bool]()
    for _ in range(slots):
        var id = Int(reader.read_i64())
        var level = Int(reader.read_u16())
        var flag = reader.read_u8()
        if reader.read_u8() != UInt8(0) or reader.read_u32() != UInt32(0):
            raise Error("nonzero HNSW snapshot node reserved bytes")
        if level < 0 or level > config.max_level:
            raise Error("HNSW snapshot node level is invalid")
        allocated_neighbor_cells = _checked_add_u64(
            allocated_neighbor_cells,
            _checked_add_u64(
                UInt64(config.m0),
                _checked_mul_u64(UInt64(level), UInt64(config.m)),
            ),
        )
        if (
            flag != _CURRENT_FLAG
            and flag != _DELETED_FLAG
            and flag != _REPLACED_FLAG
        ):
            raise Error("HNSW snapshot node lifecycle flags are invalid")
        var count_base = reader.read_u64()
        var edge_base = reader.read_u64()
        var node_edges_u64 = reader.read_u64()
        if count_base != UInt64(nodes.level_count):
            raise Error("HNSW snapshot node count offsets are not packed")
        if edge_base != UInt64(nodes.directed_edge_count):
            raise Error("HNSW snapshot node edge offsets are not packed")
        if node_edges_u64 > directed_edges_u64 - UInt64(
            nodes.directed_edge_count
        ):
            raise Error("HNSW snapshot node edge range exceeds section")
        var node_edges = _bounded_count(
            node_edges_u64, directed_edges, "node edge"
        )
        if level + 1 > level_count - nodes.level_count:
            raise Error("HNSW snapshot node count range exceeds section")
        nodes.level_count += level + 1
        nodes.directed_edge_count += node_edges
        if flag == _CURRENT_FLAG:
            if id in seen_current_ids:
                raise Error("HNSW snapshot current public IDs must be unique")
            seen_current_ids[id] = True
            nodes.live_count += 1
        nodes.ids.append(id)
        nodes.levels.append(level)
        nodes.flags.append(flag)
        nodes.edge_counts.append(node_edges)
    if nodes.level_count != level_count:
        raise Error("HNSW snapshot level count does not match nodes")
    if nodes.directed_edge_count != directed_edges:
        raise Error("HNSW snapshot edge count does not match nodes")
    if nodes.live_count != live_count:
        raise Error("HNSW snapshot live count does not match node flags")
    _validate_decode_allocation(
        UInt64(encoded_size),
        slot_count_u64,
        UInt64(config.dimension),
        UInt64(level_count),
        directed_edges_u64,
        allocated_neighbor_cells,
    )

    var index = HnswIndex(config)
    _read_zero_padding(reader, Int(vector_offset - (node_offset + node_length)))
    var vector_scalars = List[Float32](
        capacity=_bounded_count(
            vector_length // UInt64(4), Int.MAX, "vector scalar"
        )
    )
    for _ in range(slots):
        var prepared = List[Float32](capacity=config.dimension)
        for _ in range(config.dimension):
            var value = reader.read_f32()
            prepared.append(value)
        index.metric.validate_prepared_vector(prepared)
        for value in prepared:
            vector_scalars.append(value)

    _read_zero_padding(
        reader, Int(count_offset - (vector_offset + vector_length))
    )
    var level_edge_counts = List[Int](capacity=level_count)
    var total_edges_from_counts = 0
    var count_index = 0
    for slot_index in range(slots):
        var node_sum = 0
        for level in range(nodes.levels[slot_index] + 1):
            var count_u32 = reader.read_u32()
            var capacity = config.m if level > 0 else config.m0
            if UInt64(count_u32) > UInt64(capacity):
                raise Error("HNSW snapshot neighbor count exceeds capacity")
            var count = Int(count_u32)
            if count > directed_edges - total_edges_from_counts:
                raise Error("HNSW snapshot neighbor counts exceed edge section")
            node_sum += count
            total_edges_from_counts += count
            level_edge_counts.append(count)
            count_index += 1
        if node_sum != nodes.edge_counts[slot_index]:
            raise Error("HNSW snapshot node edge count is inconsistent")
    if count_index != level_count or total_edges_from_counts != directed_edges:
        raise Error("HNSW snapshot neighbor counts are inconsistent")

    _read_zero_padding(reader, Int(edge_offset - (count_offset + count_length)))
    var edge_slots = List[UInt32](capacity=directed_edges)
    var edge_index = 0
    var level_index = 0
    for source_index in range(slots):
        for level in range(nodes.levels[source_index] + 1):
            var seen_neighbors = Dict[Int, Bool]()
            var count = level_edge_counts[level_index]
            level_index += 1
            for _ in range(count):
                var neighbor = reader.read_u32()
                if UInt64(neighbor) >= slot_count_u64:
                    raise Error("HNSW snapshot neighbor ordinal is invalid")
                if Int(neighbor) == source_index:
                    raise Error("HNSW snapshot self edges are not allowed")
                if nodes.levels[Int(neighbor)] < level:
                    raise Error("HNSW snapshot edge target lacks graph level")
                var key = Int(neighbor)
                if key in seen_neighbors:
                    raise Error("HNSW snapshot neighbor list has a duplicate")
                seen_neighbors[key] = True
                edge_slots.append(neighbor)
                edge_index += 1
    if edge_index != directed_edges:
        raise Error("HNSW snapshot edge section length is inconsistent")
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("HNSW snapshot has trailing bytes")

    var entry_level = Int(entry_level_i64)
    if slots == 0:
        if (
            entry_slot_u64 != _ENTRY_NONE
            or entry_level != -1
            or live_count != 0
        ):
            raise Error("empty HNSW snapshot entry point is invalid")
    elif (
        entry_slot_u64 >= slot_count_u64
        or entry_level < 0
        or entry_level != nodes.levels[Int(entry_slot_u64)]
    ):
        raise Error("HNSW snapshot entry point is invalid")

    var vector_index = 0
    var inactive_count = 0
    for slot_index in range(slots):
        var vector = List[Float32](capacity=config.dimension)
        for _ in range(config.dimension):
            vector.append(vector_scalars[vector_index])
            vector_index += 1
        var slot = index.graph.append(
            nodes.ids[slot_index], vector^, nodes.levels[slot_index]
        )
        if Int(slot) != slot_index:
            raise Error("HNSW snapshot slot materialization is inconsistent")
        if nodes.flags[slot_index] == _DELETED_FLAG:
            if not index.graph.mark_deleted(nodes.ids[slot_index]):
                raise Error("HNSW snapshot deleted slot is inconsistent")
            inactive_count += 1
        elif nodes.flags[slot_index] == _REPLACED_FLAG:
            _ = index.graph.mark_replaced(nodes.ids[slot_index])
            inactive_count += 1

    var materialized_edge_index = 0
    var materialized_level_index = 0
    for slot_index in range(slots):
        for level in range(nodes.levels[slot_index] + 1):
            var count = level_edge_counts[materialized_level_index]
            materialized_level_index += 1
            var base = index.graph.neighbor_bases[slot_index]
            if level > 0:
                base += index.graph.m0 + (level - 1) * index.graph.m
            for local_index in range(count):
                index.graph.neighbor_slots[base + local_index] = edge_slots[
                    materialized_edge_index
                ]
                materialized_edge_index += 1
            index.graph.neighbor_counts[
                index.graph.neighbor_count_bases[slot_index] + level
            ] = UInt32(count)

    if slots > 0:
        index.entry_slot = Optional(UInt32(entry_slot_u64))
        index.entry_level = entry_level
    index.build_stats.slot_count = slots
    index.build_stats.inactive_slots = inactive_count
    index.build_stats.maximum_level = entry_level
    index.build_stats.directed_edges = directed_edges
    index.build_stats.serialized_bytes = encoded_size
    index.validate_structure()
    return index^


def write_hnsw_snapshot(
    path: String, index: HnswIndex, sequence: UInt64
) raises -> HnswSnapshotInfo:
    """Synchronously write one sidecar and return its manifest metadata."""
    var bytes = encode_hnsw_snapshot(index, sequence)
    var checksum = _read_u32_at(bytes, len(bytes) - _CHECKSUM_BYTES)
    write_file_sync(path, bytes)
    return HnswSnapshotInfo(
        sequence,
        index.config.fingerprint(),
        checksum,
        UInt64(index.graph.slot_count()),
        UInt64(index.graph.slot_count() - index.inactive_count()),
        _count_directed_edges(index),
        UInt64(len(bytes)),
    )


def read_hnsw_snapshot_owned(
    path: String, config: CollectionConfig, sequence: UInt64
) raises -> HnswIndex:
    """Read and fully validate one sidecar into independent owned storage."""
    return decode_hnsw_snapshot_owned(
        read_file_bytes_bounded(path, _MAX_SNAPSHOT_BYTES), config, sequence
    )


def try_read_compatible_hnsw_snapshot_owned(
    path: String,
    config: CollectionConfig,
    sequence: UInt64,
    manifest_checksum: UInt32,
    manifest_live_point_count: UInt64,
) raises -> Optional[HnswIndex]:
    """Return an owned compatible sidecar or `None` for stale metadata.

    The manifest checksum is compared with the bounded trailer first. Only a
    file matching that committed identity receives CRC and layout validation.
    """
    var bytes = read_file_bytes_bounded(path, _MAX_SNAPSHOT_BYTES)
    if len(bytes) < _CHECKSUM_BYTES:
        raise Error("HNSW snapshot is truncated")
    var checksum_offset = len(bytes) - _CHECKSUM_BYTES
    var stored_checksum = _read_u32_at(bytes, checksum_offset)
    if stored_checksum != manifest_checksum:
        return Optional[HnswIndex]()
    if crc32_range(bytes, 0, checksum_offset) != stored_checksum:
        raise Error("HNSW snapshot checksum mismatch")
    _require_v1_config(config)
    if len(bytes) < HNSW_SNAPSHOT_HEADER_BYTES + _CHECKSUM_BYTES:
        raise Error("HNSW snapshot is truncated")
    if (
        not hnsw_snapshot_identity_matches(
            bytes, config, sequence, manifest_live_point_count
        )
    ):
        return Optional[HnswIndex]()

    var decoded = decode_hnsw_snapshot_owned(bytes^, config, sequence)
    return Optional(decoded^)


def hnsw_snapshot_identity_matches(
    bytes: List[UInt8],
    config: CollectionConfig,
    sequence: UInt64,
    live_point_count: UInt64,
) -> Bool:
    """Compare only fixed identity fields without copying the snapshot."""
    if len(bytes) < HNSW_SNAPSHOT_HEADER_BYTES + _CHECKSUM_BYTES:
        return False
    return (
        _read_u64_at(bytes, 16) == config.fingerprint()
        and _read_u64_at(bytes, 24) == sequence
        and _read_u32_at(bytes, 32) == UInt32(config.dimension)
        and bytes[36] == config.ann_metric.tag()
        and bytes[37] == config.scalar_kind.tag()
        and _read_u16_at(bytes, 38) == UInt16(config.m)
        and _read_u16_at(bytes, 40) == UInt16(config.m0)
        and _read_u16_at(bytes, 42) == UInt16(config.max_level)
        and _read_u64_at(bytes, 56) == live_point_count
    )


def _slot_flag(index: HnswIndex, slot: UInt32) raises -> UInt8:
    if index.graph.is_current(slot):
        return _CURRENT_FLAG
    if index.graph.is_deleted(slot):
        return _DELETED_FLAG
    if index.graph.is_replaced(slot):
        return _REPLACED_FLAG
    raise Error("HNSW snapshot slot lifecycle flags are inconsistent")


def _require_v1_config(config: CollectionConfig) raises:
    config.validate()
    if not is_64bit():
        raise Error("HNSW snapshot v1 requires a 64-bit Int target")
    if config.scalar_kind != ScalarKind.f32():
        raise Error("HNSW snapshot v1 requires scalar kind f32")


def _copy_graph_vector(index: HnswIndex, slot: UInt32) raises -> List[Float32]:
    var values = List[Float32](capacity=index.config.dimension)
    for component in range(index.config.dimension):
        values.append(index.graph.vector_value(slot, component))
    return values^


def _validate_snapshot_graph_vectors(index: HnswIndex) raises:
    """Apply the codec's prepared-vector contract without encoding bytes."""
    for slot_index in range(index.graph.slot_count()):
        var prepared = _copy_graph_vector(index, UInt32(slot_index))
        index.metric.validate_prepared_vector(prepared)


def _count_directed_edges(index: HnswIndex) raises -> UInt64:
    var result = UInt64(0)
    for slot_index in range(index.graph.slot_count()):
        var slot = UInt32(slot_index)
        for level in range(index.graph.level(slot) + 1):
            result = _checked_add_u64(
                result, UInt64(index.graph.neighbor_count(slot, level))
            )
    return result


def _checked_add_u64(lhs: UInt64, rhs: UInt64) raises -> UInt64:
    if rhs > UInt64.MAX - lhs:
        raise Error("HNSW snapshot offset arithmetic overflows")
    return lhs + rhs


def _checked_mul_u64(lhs: UInt64, rhs: UInt64) raises -> UInt64:
    if lhs != UInt64(0) and rhs > UInt64.MAX // lhs:
        raise Error("HNSW snapshot length arithmetic overflows")
    return lhs * rhs


def _align8(value: UInt64) raises -> UInt64:
    var remainder = value % UInt64(8)
    if remainder == UInt64(0):
        return value
    return _checked_add_u64(value, UInt64(8) - remainder)


def _require_supported_file_length(length: UInt64) raises:
    if length > UInt64(_MAX_SNAPSHOT_BYTES) or length > UInt64(Int.MAX):
        raise Error("HNSW snapshot exceeds implementation size limit")


def _validate_decode_allocation(
    serialized_bytes: UInt64,
    slot_count: UInt64,
    dimension: UInt64,
    level_count: UInt64,
    directed_edges: UInt64,
    allocated_neighbor_cells: UInt64,
) raises:
    """Bound the conservative peak after exact node capacities are known."""
    _validate_decode_peak(
        serialized_bytes,
        slot_count,
        dimension,
        level_count,
        directed_edges,
        allocated_neighbor_cells,
    )


def _validate_hnsw_snapshot_header_allocation(
    serialized_bytes: UInt64,
    slot_count: UInt64,
    dimension: UInt64,
    level_count: UInt64,
    directed_edges: UInt64,
    m0: UInt64,
) raises:
    """Reject hostile header capacities before staging lists or maps exist."""
    var minimum_neighbor_cells = _checked_mul_u64(slot_count, m0)
    _validate_decode_peak(
        serialized_bytes,
        slot_count,
        dimension,
        level_count,
        directed_edges,
        minimum_neighbor_cells,
    )


def _validate_decode_peak(
    serialized_bytes: UInt64,
    slot_count: UInt64,
    dimension: UInt64,
    level_count: UInt64,
    directed_edges: UInt64,
    allocated_neighbor_cells: UInt64,
) raises:
    """Conservatively bound decode, materialization, and validation peak.

    Mojo 1.0 does not expose stable `List` or `Dict` allocation overhead. The
    documented per-entry constants therefore intentionally exceed payload
    widths and include both staging and final graph columns. Current-ID maps
    assume every untrusted slot is current. Level and edge constants include
    the bidirectional validator's dictionaries and reverse-edge tape.
    """
    var vector_cells = _checked_mul_u64(slot_count, dimension)
    var estimated = serialized_bytes
    estimated = _checked_add_u64(
        estimated, _checked_mul_u64(vector_cells, UInt64(8))
    )
    estimated = _checked_add_u64(
        estimated, _checked_mul_u64(dimension, UInt64(4))
    )
    estimated = _checked_add_u64(
        estimated,
        _checked_mul_u64(level_count, _LEVEL_VALIDATION_PEAK_BYTES),
    )
    estimated = _checked_add_u64(
        estimated,
        _checked_mul_u64(directed_edges, _EDGE_VALIDATION_PEAK_BYTES),
    )
    estimated = _checked_add_u64(
        estimated, _checked_mul_u64(allocated_neighbor_cells, UInt64(4))
    )
    estimated = _checked_add_u64(
        estimated, _checked_mul_u64(slot_count, _SLOT_PEAK_BYTES)
    )
    estimated = _checked_add_u64(
        estimated,
        _checked_mul_u64(slot_count, _CURRENT_MAP_PEAK_BYTES),
    )
    var amplification_budget = _MIN_ALLOCATION_BUDGET
    if serialized_bytes <= UInt64.MAX // _MAX_ALLOCATION_RATIO:
        var scaled = serialized_bytes * _MAX_ALLOCATION_RATIO
        if scaled > amplification_budget:
            amplification_budget = scaled
    if (
        estimated > amplification_budget
        or estimated > _MAX_DECODE_ALLOCATION_BYTES
    ):
        raise Error("HNSW snapshot decoded allocation exceeds safe limit")


def _bounded_count(value: UInt64, maximum: Int, label: String) raises -> Int:
    if value > UInt64(maximum) or value > UInt64(Int.MAX):
        raise Error(String("HNSW snapshot ", label, " count is too large"))
    return Int(value)


def _validate_section_layout(
    file_length: UInt64,
    slot_count: UInt64,
    dimension: UInt64,
    directed_edges: UInt64,
    node_offset: UInt64,
    node_length: UInt64,
    vector_offset: UInt64,
    vector_length: UInt64,
    count_offset: UInt64,
    count_length: UInt64,
    edge_offset: UInt64,
    edge_length: UInt64,
) raises:
    var expected_node_length = _checked_mul_u64(
        slot_count, UInt64(HNSW_SNAPSHOT_NODE_BYTES)
    )
    var expected_vector_length = _checked_mul_u64(
        _checked_mul_u64(slot_count, dimension), UInt64(4)
    )
    var expected_edge_length = _checked_mul_u64(directed_edges, UInt64(4))
    if (
        node_offset != UInt64(HNSW_SNAPSHOT_HEADER_BYTES)
        or node_length != expected_node_length
        or vector_offset != _align8(_checked_add_u64(node_offset, node_length))
        or vector_length != expected_vector_length
        or count_offset
        != _align8(_checked_add_u64(vector_offset, vector_length))
        or edge_offset != _align8(_checked_add_u64(count_offset, count_length))
        or edge_length != expected_edge_length
    ):
        raise Error("HNSW snapshot section layout is invalid")
    var body_end = _checked_add_u64(edge_offset, edge_length)
    if _checked_add_u64(body_end, UInt64(_CHECKSUM_BYTES)) != file_length:
        raise Error("HNSW snapshot section range exceeds file")


def _write_magic(mut writer: BinaryWriter):
    writer.write_u8(UInt8(0x41))  # A
    writer.write_u8(UInt8(0x4B))  # K
    writer.write_u8(UInt8(0x48))  # H
    writer.write_u8(UInt8(0x47))  # G


def _read_magic(mut reader: BinaryReader) raises:
    if (
        reader.read_u8() != UInt8(0x41)
        or reader.read_u8() != UInt8(0x4B)
        or reader.read_u8() != UInt8(0x48)
        or reader.read_u8() != UInt8(0x47)
    ):
        raise Error("invalid HNSW snapshot magic")


def _write_zeros(mut writer: BinaryWriter, count: Int):
    for _ in range(count):
        writer.write_u8(UInt8(0))


def _read_zero_padding(mut reader: BinaryReader, count: Int) raises:
    for _ in range(count):
        if reader.read_u8() != UInt8(0):
            raise Error("nonzero HNSW snapshot alignment padding")


def _read_u32_at(bytes: List[UInt8], offset: Int) -> UInt32:
    return (
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )


def _read_u16_at(bytes: List[UInt8], offset: Int) -> UInt16:
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << UInt16(8))


def _read_u64_at(bytes: List[UInt8], offset: Int) -> UInt64:
    return (
        UInt64(bytes[offset])
        | (UInt64(bytes[offset + 1]) << UInt64(8))
        | (UInt64(bytes[offset + 2]) << UInt64(16))
        | (UInt64(bytes[offset + 3]) << UInt64(24))
        | (UInt64(bytes[offset + 4]) << UInt64(32))
        | (UInt64(bytes[offset + 5]) << UInt64(40))
        | (UInt64(bytes[offset + 6]) << UInt64(48))
        | (UInt64(bytes[offset + 7]) << UInt64(56))
    )
