from akasha.index.bitmap import Bitmap
from akasha.storage.memtable import MemTable


def candidate_ordinals(
    memtable: MemTable, candidates: Bitmap
) raises -> List[Int]:
    """Select live stable slots without materializing vectors or payloads."""
    if candidates.size() != memtable.slot_count():
        raise Error("candidate bitmap does not align with memtable slots")
    var result = List[Int](capacity=candidates.count())
    for ordinal in candidates.set_ordinals():
        if memtable.is_live_at(ordinal):
            result.append(ordinal)
    return result^
