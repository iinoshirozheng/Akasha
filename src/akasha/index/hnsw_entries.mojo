"""Eligible HNSW entries, ported from Qdrant entry_points.rs (21db2f3).

Apache-2.0; see benchmarks/licenses/qdrant-APACHE-2.0.txt. Primary entries
cover independently built components. Extra entries retain the highest levels;
equal levels use Akasha's stable public-ID/slot order.
"""

from akasha.index.hnsw_admission import HnswResultAdmission
from akasha.index.hnsw_heap import HnswHeapItem, ResultMaxHeap
from akasha.index.hnsw_storage import HnswGraphAccess
from akasha.storage.checksum import BinaryReader, BinaryWriter


@fieldwise_init
struct HnswEntry(TrivialRegisterPassable, Equatable, Writable):
    var slot: UInt32
    var level: Int

    def __eq__(self, other: Self) -> Bool:
        return self.slot == other.slot and self.level == other.level

    def __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)


struct HnswEntryPoints(Movable):
    var primary: List[HnswEntry]
    var extra: ResultMaxHeap
    var extra_capacity: Int

    def __init__(out self, extra_capacity: Int = 80):
        # Existing planner's minimum ANN selectivity is 1/8. Qdrant reserves
        # ten extra entries per full-scan-sized block: eight blocks -> 80.
        self.primary = List[HnswEntry]()
        self.extra = ResultMaxHeap()
        self.extra_capacity = extra_capacity

    def validate[GraphType: HnswGraphAccess](self, graph: GraphType) raises:
        if self.extra_capacity <= 0 or self.extra_capacity > Int(UInt32.MAX):
            raise Error("HNSW extra-entry capacity is invalid")
        if len(self.extra) > self.extra_capacity:
            raise Error("HNSW extra entries exceed capacity")
        var seen = Dict[UInt32, Bool]()
        for entry in self.primary:
            var slot = entry.slot
            if UInt64(slot) >= UInt64(graph.slot_count()) or entry.level < 0 or entry.level > graph.level(slot):
                raise Error("HNSW primary entry level is invalid")
            if slot in seen:
                raise Error("HNSW duplicate primary entry")
            seen[slot] = True
        for item in self.extra._heap:
            if item.slot in seen:
                raise Error("HNSW duplicate extra entry")
            if UInt64(item.slot) >= UInt64(graph.slot_count()):
                raise Error("HNSW extra-entry slot is invalid")
            if item.id != graph.id_at(item.slot) or not (item.distance <= 0 and item.distance >= -Float32(graph.level(item.slot))) or Float32(Int(item.distance)) != item.distance:
                raise Error("HNSW extra-entry identity is invalid")
            seen[item.slot] = True
        if graph.slot_count() == 0 and len(seen) != 0:
            raise Error("empty HNSW graph has entries")
        if graph.slot_count() > 0 and len(self.primary) == 0:
            raise Error("nonempty HNSW graph has no primary entry")

    def get_entry[GraphType: HnswGraphAccess, AdmissionType: HnswResultAdmission](
        self, graph: GraphType, allowed: AdmissionType
    ) raises -> Optional[HnswEntry]:
        for entry in self.primary:
            if graph.is_current(entry.slot) and allowed._allows_item(entry.slot, graph.id_at(entry.slot)):
                return Optional(entry)
        var best = Optional[HnswEntry]()
        var best_level = -1
        var best_id = Int.MAX
        for item in self.extra._heap:
            if not graph.is_current(item.slot) or not allowed._allows_item(item.slot, item.id):
                continue
            var level = Int(-item.distance)
            if level > best_level or (level == best_level and item.id < best_id):
                best = Optional(HnswEntry(item.slot, level))
                best_level = level
                best_id = item.id
        return best

    def new_point[GraphType: HnswGraphAccess, AdmissionType: HnswResultAdmission](
        mut self, graph: GraphType, slot: UInt32, allowed: AdmissionType
    ) raises:
        var level = graph.level(slot)
        for ordinal in range(len(self.primary)):
            var candidate = self.primary[ordinal]
            if not graph.is_current(candidate.slot) or not allowed._allows_item(candidate.slot, graph.id_at(candidate.slot)):
                continue
            var extra = HnswEntry(slot, level)
            if candidate.level < level:
                self.primary[ordinal] = HnswEntry(slot, level)
                extra = candidate
            self.extra.offer(
                HnswHeapItem(extra.slot, graph.id_at(extra.slot), -Float32(extra.level)),
                self.extra_capacity,
            )
            return
        self.primary.append(HnswEntry(slot, level))



def entries_from_legacy[GraphType: HnswGraphAccess](
    graph: GraphType, primary: Optional[UInt32]
) raises -> HnswEntryPoints:
    """Reconstruct extra entries at load time for a validated old graph."""
    var result = HnswEntryPoints()
    if primary:
        result.primary.append(HnswEntry(primary.value(), graph.level(primary.value())))
    for ordinal in range(graph.slot_count()):
        var slot = UInt32(ordinal)
        if primary and slot == primary.value():
            continue
        result.extra.offer(
            HnswHeapItem(slot, graph.id_at(slot), -Float32(graph.level(slot))),
            result.extra_capacity,
        )
    result.validate(graph)
    return result^


def encode_entries(entries: HnswEntryPoints) -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_u32(UInt32(len(entries.primary)))
    writer.write_u32(UInt32(len(entries.extra)))
    writer.write_u32(UInt32(entries.extra_capacity))
    writer.write_u32(UInt32(0))
    for entry in entries.primary:
        writer.write_u32(entry.slot)
        writer.write_u32(UInt32(entry.level))
    for item in entries.extra._heap:
        writer.write_u32(item.slot)
        writer.write_u32(UInt32(Int(-item.distance)))
    return writer.take_bytes()


def decode_entries[GraphType: HnswGraphAccess](
    var bytes: List[UInt8], graph: GraphType
) raises -> HnswEntryPoints:
    if len(bytes) < 16:
        raise Error("HNSW entry section is truncated")
    var reader = BinaryReader(bytes^)
    var primary_count = Int(reader.read_u32())
    var extra_count = Int(reader.read_u32())
    var capacity = Int(reader.read_u32())
    if reader.read_u32() != UInt32(0):
        raise Error("HNSW entry section reserved bytes are nonzero")
    if primary_count > graph.slot_count() or extra_count > graph.slot_count() - primary_count:
        raise Error("HNSW entry count exceeds slots")
    if capacity <= 0 or extra_count > capacity or reader.remaining() != (primary_count + extra_count) * 8:
        raise Error("HNSW entry section counts are invalid")
    var result = HnswEntryPoints(capacity)
    # Validate duplicates before offering to a bounded heap, so corruption
    # cannot disappear through heap deduplication or truncation.
    var seen = Dict[UInt32, Bool]()
    for ordinal in range(primary_count + extra_count):
        var slot = reader.read_u32()
        var level = Int(reader.read_u32())
        if UInt64(slot) >= UInt64(graph.slot_count()) or slot in seen:
            raise Error("HNSW entry slot is invalid or duplicated")
        if level > graph.level(slot):
            raise Error("HNSW entry level exceeds point layers")
        seen[slot] = True
        if ordinal < primary_count:
            result.primary.append(HnswEntry(slot, level))
        else:
            result.extra.offer(
                HnswHeapItem(slot, graph.id_at(slot), -Float32(level)), capacity
            )
    result.validate(graph)
    return result^
