from akasha.document.record import (
    clone_fields,
    DocumentField,
    DocumentRecord,
    validate_fields,
)
from std.collections import Dict


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
    var _id_ordinals: Dict[Int, Int]
    var _live_count: Int

    def __init__(out self, dimension: Int) raises:
        if dimension <= 0:
            raise Error("memtable dimension must be positive")
        self.dimension = dimension
        self.last_sequence = 0
        self._entries = List[MemTableEntry]()
        self._id_ordinals = Dict[Int, Int]()
        self._live_count = 0

    def entry_count(self) -> Int:
        return len(self._entries)

    def live_count(self) -> Int:
        """Return the number of live records without materializing them."""
        return self._live_count

    def ordinal_for(self, id: Int) -> Int:
        """Return a stable slot (including tombstones), or -1 for an absent ID.
        """
        return self._id_ordinals.get(id, -1)

    def entry_view(self) -> Span[MemTableEntry, origin_of(self._entries)]:
        """Borrow immutable slots in insertion order, including tombstones."""
        return Span(self._entries)

    def live_ordinals(self, *, id_order: Bool = False) -> List[Int]:
        """Return lightweight live slots, optionally in ascending ID order."""
        var ordinals = List[Int](capacity=self._live_count)
        for ordinal in range(len(self._entries)):
            if not self._entries[ordinal].tombstone:
                ordinals.append(
                    self._entries[ordinal].id if id_order else ordinal
                )
        if id_order:
            sort(Span(ordinals))
            for index in range(len(ordinals)):
                ordinals[index] = self.ordinal_for(ordinals[index])
        return ordinals^

    def clone(self) raises -> MemTable:
        """Return an owned copy preserving stable ordinal slot order."""
        var result = MemTable(self.dimension)
        result.last_sequence = self.last_sequence
        for index in range(len(self._entries)):
            result._entries.append(self._entries[index].clone())
        result._id_ordinals = self._id_ordinals.copy()
        result._live_count = self._live_count
        return result^

    def slot_count(self) -> Int:
        """Return stable ordinal slots, including tombstones."""
        return len(self._entries)

    def id_at(self, ordinal: Int) raises -> Int:
        """Return the public ID at one stable ordinal without cloning data."""
        self._validate_ordinal(ordinal)
        return self._entries[ordinal].id

    def is_live_at(self, ordinal: Int) raises -> Bool:
        """Check stable-ordinal liveness without materializing a record."""
        self._validate_ordinal(ordinal)
        return not self._entries[ordinal].tombstone

    def entry_ref_at(
        self, ordinal: Int
    ) raises -> ref[origin_of(self._entries[ordinal])] MemTableEntry:
        """Borrow one stable-ordinal entry without vector or payload copies."""
        self._validate_ordinal(ordinal)
        return self._entries[ordinal]

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
        var index = self.ordinal_for(id)
        if index >= 0:
            if sequence <= self._entries[index].sequence:
                return
            if self._entries[index].tombstone:
                self._live_count += 1
            self._entries[index].sequence = sequence
            self._entries[index].tombstone = False
            self._entries[index].values = values^
            self._entries[index].fields = fields^
            return

        self._entries.append(
            MemTableEntry.with_fields(id, sequence, False, values^, fields^)
        )
        self._id_ordinals[id] = len(self._entries) - 1
        self._live_count += 1

    def apply_delete(mut self, id: Int, sequence: UInt64) raises:
        if sequence == 0:
            raise Error("memtable sequence must be positive")

        self._advance_sequence(sequence)
        var index = self.ordinal_for(id)
        if index >= 0:
            if sequence <= self._entries[index].sequence:
                return
            if not self._entries[index].tombstone:
                self._live_count -= 1
            self._entries[index].sequence = sequence
            self._entries[index].tombstone = True
            self._entries[index].values = List[Float32]()
            self._entries[index].fields = List[DocumentField]()
            return

        self._entries.append(MemTableEntry(id, sequence, True, List[Float32]()))
        self._id_ordinals[id] = len(self._entries) - 1

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        var index = self.ordinal_for(id)
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
        var ids = List[Int](capacity=self._live_count)
        for index in range(len(self._entries)):
            if not self._entries[index].tombstone:
                ids.append(self._entries[index].id)
        return self._owned_entries_in_id_order(ids^)

    def entries_after(
        self, checkpoint_sequence: UInt64
    ) raises -> List[MemTableEntry]:
        """Return owned latest states newer than a checkpoint, including deletes.
        """
        var ids = List[Int]()
        for index in range(len(self._entries)):
            if self._entries[index].sequence > checkpoint_sequence:
                ids.append(self._entries[index].id)
        return self._owned_entries_in_id_order(ids^)

    def _owned_entries_in_id_order(
        self, var ids: List[Int]
    ) raises -> List[MemTableEntry]:
        sort(Span(ids))
        var result = List[MemTableEntry](capacity=len(ids))
        for id in ids:
            result.append(self._entries[self.ordinal_for(id)].clone())
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
        # Segment merge changes slot order; rebuild both derived indexes here.
        self._id_ordinals = Dict[Int, Int]()
        self._live_count = 0
        for ordinal in range(len(self._entries)):
            self._id_ordinals[self._entries[ordinal].id] = ordinal
            if not self._entries[ordinal].tombstone:
                self._live_count += 1

    def _validate_ordinal(self, ordinal: Int) raises:
        if ordinal < 0 or ordinal >= len(self._entries):
            raise Error("memtable ordinal out of bounds")

    def _advance_sequence(mut self, sequence: UInt64):
        if sequence > self.last_sequence:
            self.last_sequence = sequence


def _clone_vector(values: List[Float32]) -> List[Float32]:
    var result = List[Float32](capacity=len(values))
    for value in values:
        result.append(value)
    return result^
