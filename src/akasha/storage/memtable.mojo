struct MemTableEntry(Movable):
    """The newest known state for one point ID."""

    var id: Int
    var sequence: UInt64
    var tombstone: Bool
    var values: List[Float32]

    def __init__(
        out self,
        id: Int,
        sequence: UInt64,
        tombstone: Bool,
        var values: List[Float32],
    ):
        self.id = id
        self.sequence = sequence
        self.tombstone = tombstone
        self.values = values^

    def clone(self) -> MemTableEntry:
        var values = List[Float32](capacity=len(self.values))
        for value in self.values:
            values.append(value)
        return MemTableEntry(self.id, self.sequence, self.tombstone, values^)


struct MemTable:
    """Single-writer latest-state map used for recovery and exact search."""

    var dimension: Int
    var last_sequence: UInt64
    var _entries: List[MemTableEntry]

    def __init__(out self, dimension: Int) raises:
        if dimension <= 0:
            raise Error("memtable dimension must be positive")
        self.dimension = dimension
        self.last_sequence = 0
        self._entries = List[MemTableEntry]()

    def entry_count(self) -> Int:
        return len(self._entries)

    def apply_upsert(
        mut self, id: Int, sequence: UInt64, var values: List[Float32]
    ) raises:
        if sequence == 0:
            raise Error("memtable sequence must be positive")
        if len(values) != self.dimension:
            raise Error("vector dimension does not match memtable")

        self._advance_sequence(sequence)
        var index = self._find_index(id)
        if index >= 0:
            if sequence <= self._entries[index].sequence:
                return
            self._entries[index].sequence = sequence
            self._entries[index].tombstone = False
            self._entries[index].values = values^
            return

        self._entries.append(MemTableEntry(id, sequence, False, values^))

    def apply_delete(mut self, id: Int, sequence: UInt64) raises:
        if sequence == 0:
            raise Error("memtable sequence must be positive")

        self._advance_sequence(sequence)
        var index = self._find_index(id)
        if index >= 0:
            if sequence <= self._entries[index].sequence:
                return
            self._entries[index].sequence = sequence
            self._entries[index].tombstone = True
            self._entries[index].values = List[Float32]()
            return

        self._entries.append(MemTableEntry(id, sequence, True, List[Float32]()))

    def live_entries(self) -> List[MemTableEntry]:
        """Return owned live entries sorted by ascending point ID."""
        var result = List[MemTableEntry]()
        for index in range(len(self._entries)):
            if not self._entries[index].tombstone:
                result.append(self._entries[index].clone())

        for index in range(1, len(result)):
            var cursor = index
            while cursor > 0 and result[cursor].id < result[cursor - 1].id:
                result.swap_elements(cursor, cursor - 1)
                cursor -= 1
        return result^

    def _find_index(self, id: Int) -> Int:
        for index in range(len(self._entries)):
            if self._entries[index].id == id:
                return index
        return -1

    def _advance_sequence(mut self, sequence: UInt64):
        if sequence > self.last_sequence:
            self.last_sequence = sequence
