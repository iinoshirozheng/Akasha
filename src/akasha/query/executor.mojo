from akasha.index.bitmap import Bitmap
from akasha.storage.memtable import MemTable, MemTableEntry


def candidate_entries(
    memtable: MemTable, candidates: Bitmap
) raises -> List[MemTableEntry]:
    """Materialize only selected live stable slots for physical execution."""
    if candidates.size() != memtable.slot_count():
        raise Error("candidate bitmap does not align with memtable slots")
    var result = List[MemTableEntry](capacity=candidates.count())
    for ordinal in range(candidates.size()):
        if not candidates.contains(ordinal):
            continue
        var entry = memtable.entry_at(ordinal)
        if entry.tombstone:
            continue
        result.append(entry^)
    return result^
