"""Shared ordered updates for keyword, integer and floating postings."""


def _lower_bound[
    T: Comparable & Movable & Deinitable
](entries: List[T], key: T) -> Int:
    var low = 0
    var high = len(entries)
    while low < high:
        var middle = low + (high - low) // 2
        if entries[middle] < key:
            low = middle + 1
        else:
            high = middle
    return low


def insert_posting[
    T: Comparable & Movable & Deinitable
](mut entries: List[T], var key: T, bulk: Bool):
    if bulk:
        entries.append(key^)
        return
    var position = _lower_bound(entries, key)
    if position < len(entries) and entries[position] == key:
        return
    entries.insert(position, key^)


def remove_posting[
    T: Comparable & Movable & Deinitable
](mut entries: List[T], key: T, bulk: Bool):
    # Bulk insertion intentionally leaves entries unsorted until finish_bulk.
    # Preserve removal from that state as well as normal ordered updates.
    if bulk:
        for position in range(len(entries)):
            if entries[position] == key:
                _ = entries.pop(position)
                return
        return
    var position = _lower_bound(entries, key)
    if position < len(entries) and entries[position] == key:
        _ = entries.pop(position)
