from akasha.document.record import (
    clone_fields,
    DocumentField,
    DocumentRecord,
    field_content_bytes,
    validate_fields,
)
from akasha.index.sparse import SparseElement, validate_sparse
from std.collections import Dict
from std.memory import ArcPointer


struct MemTableEntry(Movable):
    """The newest known state for one point ID.

    Dense, payload and sparse fields are independent immutable owners shared
    by every descriptor copy. A write installs a new owner for each field it
    changes; published fields are never mutated in place. A tombstone owns no
    fields, so a reinsert cannot inherit any from before the delete.
    """

    var id: Int
    var sequence: UInt64
    var tombstone: Bool
    var _dense: ArcPointer[List[Float32]]
    var _payload: ArcPointer[List[DocumentField]]
    var _sparse: Optional[ArcPointer[List[SparseElement]]]

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
        self._dense = ArcPointer(values^)
        self._payload = ArcPointer(List[DocumentField]())
        self._sparse = Optional[ArcPointer[List[SparseElement]]]()

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
        entry._payload = ArcPointer(fields^)
        return entry^

    def values(self) -> ref[origin_of(self._dense[], self)] List[Float32]:
        """Borrow the immutable dense row; union with self keeps it readonly."""
        return self._dense[]

    def fields(self) -> ref[origin_of(self._payload[], self)] List[DocumentField]:
        """Borrow the immutable payload; union with self keeps it readonly."""
        return self._payload[]

    def has_sparse(self) -> Bool:
        return Bool(self._sparse)

    def sparse(
        self,
    ) raises -> ref[origin_of(self._sparse.value()[], self)] List[SparseElement]:
        """Borrow the immutable sparse field; raises when the point has none."""
        if not self._sparse:
            raise Error("point has no sparse field")
        return self._sparse.value()[]

    def dense_bytes(self) -> Int:
        return len(self._dense[]) * 4

    def payload_bytes(self) -> Int:
        return field_content_bytes(self._payload[])

    def sparse_bytes(self) -> Int:
        """Logical I64 term plus F32 weight bytes, as SparseIndex counts them."""
        return len(self._sparse.value()[]) * 12 if self._sparse else 0

    def payload_address(self) -> Int:
        """Allocation identity of the payload owner, for copy auditing."""
        return Int(self._payload.unsafe_ptr())

    def sparse_address(self) -> Int:
        """Allocation identity of the sparse owner, or 0 without one."""
        return Int(self._sparse.value().unsafe_ptr()) if self._sparse else 0

    def dense_address(self) -> Int:
        """Allocation identity of the dense owner, for copy auditing."""
        return Int(self._dense.unsafe_ptr())

    def clone(self) -> MemTableEntry:
        """Copy the point-state descriptor; share every field owner."""
        var entry = self.dense_descriptor()
        entry._payload = self._payload.copy()
        entry._sparse = self._sparse.copy()
        return entry^

    def dense_descriptor(self) -> MemTableEntry:
        """Copy ID/sequence/tombstone and share dense; other fields omitted."""
        var entry = MemTableEntry(
            self.id, self.sequence, self.tombstone, List[Float32]()
        )
        entry._dense = self._dense.copy()
        return entry^


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
            # Replacing dense and payload keeps a live point's sparse field.
            self._entries[index]._dense = ArcPointer(values^)
            self._entries[index]._payload = ArcPointer(fields^)
            return

        self._entries.append(
            MemTableEntry.with_fields(id, sequence, False, values^, fields^)
        )
        self._id_ordinals[id] = len(self._entries) - 1
        self._live_count += 1

    def put(mut self, var entry: MemTableEntry):
        """Install one already-accepted point state, replacing its ID's slot."""
        if entry.sequence > self.last_sequence:
            self.last_sequence = entry.sequence
        var index = self.ordinal_for(entry.id)
        if index < 0:
            if not entry.tombstone:
                self._live_count += 1
            self._id_ordinals[entry.id] = len(self._entries)
            self._entries.append(entry^)
            return
        if self._entries[index].tombstone != entry.tombstone:
            self._live_count += -1 if entry.tombstone else 1
        self._entries[index] = entry^

    def set_sparse(mut self, id: Int, var elements: List[SparseElement]) raises:
        """Install a new sparse owner on a live point; dense/payload stay."""
        validate_sparse(elements)
        var index = self.ordinal_for(id)
        if index < 0 or self._entries[index].tombstone:
            raise Error("sparse vectors require an existing live point")
        self._entries[index]._sparse = Optional(ArcPointer(elements^))

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
            self._entries[index]._dense = ArcPointer(List[Float32]())
            self._entries[index]._payload = ArcPointer(List[DocumentField]())
            self._entries[index]._sparse = Optional[
                ArcPointer[List[SparseElement]]
            ]()
            return

        self._entries.append(MemTableEntry(id, sequence, True, List[Float32]()))
        self._id_ordinals[id] = len(self._entries) - 1

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        var index = self.ordinal_for(id)
        if index < 0 or self._entries[index].tombstone:
            return Optional[DocumentRecord]()
        var vector = self._entries[index].values().copy()
        var fields = clone_fields(self._entries[index].fields())
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
                if len(entries[index].values()) != 0:
                    raise Error("recovered tombstone cannot contain a vector")
            elif len(entries[index].values()) != self.dimension:
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
