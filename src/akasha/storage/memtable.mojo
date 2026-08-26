from akasha.document.record import (
    clone_fields,
    DocumentField,
    DocumentRecord,
    validate_fields,
)


struct MemTableEntry(Movable):
    """The newest known state for one point ID."""

    var id: Int
    var sequence: UInt64
    var tombstone: Bool
    var values: List[Float32]
    var fields: List[DocumentField]

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
        self.fields = List[DocumentField]()

    @staticmethod
    def with_fields(
        id: Int,
        sequence: UInt64,
        tombstone: Bool,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) raises -> MemTableEntry:
        validate_fields(fields)
        var entry = MemTableEntry(id, sequence, tombstone, values^)
        entry.fields = fields^
        return entry^

    def clone(self) raises -> MemTableEntry:
        var values = _clone_vector(self.values)
        var fields = clone_fields(self.fields)
        return MemTableEntry.with_fields(
            self.id,
            self.sequence,
            self.tombstone,
            values^,
            fields^,
        )


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

    def clone(self) raises -> MemTable:
        """Return an owned copy preserving stable ordinal slot order."""
        var result = MemTable(self.dimension)
        result.last_sequence = self.last_sequence
        for index in range(len(self._entries)):
            result._entries.append(self._entries[index].clone())
        return result^

    def slot_count(self) -> Int:
        """Return stable ordinal slots, including tombstones."""
        return len(self._entries)

    def entry_at(self, ordinal: Int) raises -> MemTableEntry:
        """Return an owned entry for one stable ordinal slot."""
        if ordinal < 0 or ordinal >= len(self._entries):
            raise Error("memtable ordinal out of bounds")
        return self._entries[ordinal].clone()

    def apply_upsert(
        mut self, id: Int, sequence: UInt64, var values: List[Float32]
    ) raises:
        var fields = List[DocumentField]()
        self.apply_document_upsert(id, sequence, values^, fields^)

    def apply_document_upsert(
        mut self,
        id: Int,
        sequence: UInt64,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) raises:
        if sequence == 0:
            raise Error("memtable sequence must be positive")
        if len(values) != self.dimension:
            raise Error("vector dimension does not match memtable")
        validate_fields(fields)

        self._advance_sequence(sequence)
        var index = self._find_index(id)
        if index >= 0:
            if sequence <= self._entries[index].sequence:
                return
            self._entries[index].sequence = sequence
            self._entries[index].tombstone = False
            self._entries[index].values = values^
            self._entries[index].fields = fields^
            return

        self._entries.append(
            MemTableEntry.with_fields(id, sequence, False, values^, fields^)
        )

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
            self._entries[index].fields = List[DocumentField]()
            return

        self._entries.append(MemTableEntry(id, sequence, True, List[Float32]()))

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        var index = self._find_index(id)
        if index < 0 or self._entries[index].tombstone:
            return Optional[DocumentRecord]()
        var vector = _clone_vector(self._entries[index].values)
        var fields = clone_fields(self._entries[index].fields)
        var record = DocumentRecord(
            id,
            self._entries[index].sequence,
            vector^,
            fields^,
        )
        return Optional(record^)

    def live_entries(self) raises -> List[MemTableEntry]:
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

    def entries_after(
        self, checkpoint_sequence: UInt64
    ) raises -> List[MemTableEntry]:
        """Return owned latest states newer than a checkpoint, including deletes.
        """
        var result = List[MemTableEntry]()
        for index in range(len(self._entries)):
            if self._entries[index].sequence > checkpoint_sequence:
                result.append(self._entries[index].clone())

        for index in range(1, len(result)):
            var cursor = index
            while cursor > 0 and result[cursor].id < result[cursor - 1].id:
                result.swap_elements(cursor, cursor - 1)
                cursor -= 1
        return result^

    def apply_recovered_entries(mut self, entries: List[MemTableEntry]) raises:
        """Linearly merge one ID-ordered immutable segment during recovery."""
        var previous_id = 0
        for index in range(len(entries)):
            if index > 0 and entries[index].id <= previous_id:
                raise Error("recovered point IDs must increase")
            previous_id = entries[index].id
            if entries[index].sequence == 0:
                raise Error("recovered sequence must be positive")
            if entries[index].tombstone:
                if len(entries[index].values) != 0:
                    raise Error("recovered tombstone cannot contain a vector")
            elif len(entries[index].values) != self.dimension:
                raise Error(
                    "recovered vector dimension does not match memtable"
                )
            self._advance_sequence(entries[index].sequence)

        for index in range(1, len(self._entries)):
            if self._entries[index].id <= self._entries[index - 1].id:
                raise Error("recovered memtable state must be ID ordered")

        var merged = List[MemTableEntry](
            capacity=len(self._entries) + len(entries)
        )
        var current_index = 0
        var incoming_index = 0
        while current_index < len(self._entries) and incoming_index < len(
            entries
        ):
            if self._entries[current_index].id < entries[incoming_index].id:
                merged.append(self._entries[current_index].clone())
                current_index += 1
            elif entries[incoming_index].id < self._entries[current_index].id:
                merged.append(entries[incoming_index].clone())
                incoming_index += 1
            else:
                if (
                    entries[incoming_index].sequence
                    > self._entries[current_index].sequence
                ):
                    merged.append(entries[incoming_index].clone())
                else:
                    merged.append(self._entries[current_index].clone())
                current_index += 1
                incoming_index += 1

        while current_index < len(self._entries):
            merged.append(self._entries[current_index].clone())
            current_index += 1
        while incoming_index < len(entries):
            merged.append(entries[incoming_index].clone())
            incoming_index += 1
        self._entries = merged^

    def _find_index(self, id: Int) -> Int:
        for index in range(len(self._entries)):
            if self._entries[index].id == id:
                return index
        return -1

    def _advance_sequence(mut self, sequence: UInt64):
        if sequence > self.last_sequence:
            self.last_sequence = sequence


def _clone_vector(values: List[Float32]) -> List[Float32]:
    var result = List[Float32](capacity=len(values))
    for value in values:
        result.append(value)
    return result^
