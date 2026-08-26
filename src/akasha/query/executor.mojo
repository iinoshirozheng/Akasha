from akasha.index.bitmap import Bitmap
from akasha.storage.memtable import MemTable, MemTableEntry


def candidate_entries(
    memtable: MemTable, candidates: Bitmap
) raises -> List[MemTableEntry]:
    """Materialize only selected live stable slots for physical execution."""
    if candidates.size() != memtable.slot_count():
        raise Error("candidate bitmap does not align with memtable slots")
    var result = List[MemTableEntry](capacity=candidates.count())
    var ordinals = candidates.set_ordinals()
    for ordinal in ordinals:
        var entry = memtable.entry_at(ordinal)
        if entry.tombstone:
            continue
        result.append(entry^)
    return result^
