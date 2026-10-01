from akasha.document.point_state import PointField, PointState
from akasha.document.vector_value import VectorValue
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
    """A shared read descriptor for the newest known state of one point.

    All vector kinds use the same immutable field owners as PointState. The
    legacy dense/sparse accessors project reserved fields 0/1 without copying.
    """

    var id: Int
    var sequence: UInt64
    var document_sequence: UInt64
    var tombstone: Bool
    var _vectors: List[PointField]
    var _payload: ArcPointer[List[DocumentField]]
    var _empty_dense: List[Float32]

    def __init__(
        out self,
        id: Int,
        sequence: UInt64,
        tombstone: Bool,
        var values: List[Float32],
    ):
        self.id = id
        self.sequence = sequence
        self.document_sequence = (
            sequence if not tombstone and len(values) else 0
        )
        self.tombstone = tombstone
        self._vectors = List[PointField]()
        if len(values):
            self._vectors.append(
                PointField(0, VectorValue._legacy_dense(values^))
            )
        self._payload = ArcPointer(List[DocumentField]())
        self._empty_dense = List[Float32]()

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

    @staticmethod
    def from_point(point: PointState) -> MemTableEntry:
        """Project an accepted point, sharing every vector and payload owner."""
        var entry = MemTableEntry(point.id, point.sequence, point.tombstone, [])
        entry.document_sequence = point.document_sequence
        entry._vectors = point._fields.copy()
        if point._payload:
            entry._payload = point._payload.value().copy()
        return entry^

    def to_point(self) -> PointState:
        var payload = Optional[ArcPointer[List[DocumentField]]]()
        if not self.tombstone:
            payload = Optional(self._payload.copy())
        return PointState(
            self.id,
            self.sequence,
            self.document_sequence,
            self.tombstone,
            self._vectors.copy(),
            payload^,
        )

    def field_ordinal(self, id: Int) -> Int:
        for ordinal in range(len(self._vectors)):
            if self._vectors[ordinal].id == id:
                return ordinal
        return -1

    def has_dense(self) -> Bool:
        return self.field_ordinal(0) >= 0

    def vector_at(
        self, ordinal: Int
    ) raises -> ref[origin_of(self._vectors[ordinal])] PointField:
        if ordinal < 0 or ordinal >= len(self._vectors):
            raise Error("vector field ordinal out of bounds")
        return self._vectors[ordinal]

    def values(
        self,
    ) -> ref[
        origin_of(
            self._vectors[0].value()._legacy_values(), self._empty_dense, self
        )
    ] List[Float32]:
        var ordinal = self.field_ordinal(0)
        if ordinal >= 0:
            return self._vectors[ordinal].value()._legacy_values()
        return self._empty_dense

    def fields(
        self,
    ) -> ref[origin_of(self._payload[], self)] List[DocumentField]:
        return self._payload[]

    def has_sparse(self) -> Bool:
        return self.field_ordinal(1) >= 0

    def sparse(
        self,
    ) raises -> ref[
        origin_of(self._vectors[0].value().sparse_values(), self)
    ] List[SparseElement]:
        var ordinal = self.field_ordinal(1)
        if ordinal < 0:
            raise Error("point has no sparse field")
        return self._vectors[ordinal].value().sparse_values()

    def dense_bytes(self) -> Int:
        return len(self.values()) * 4

    def payload_bytes(self) -> Int:
        return field_content_bytes(self._payload[])

    def sparse_bytes(self) -> Int:
        var ordinal = self.field_ordinal(1)
        return (
            self._vectors[ordinal].value().content_bytes() if ordinal
            >= 0 else 0
        )

    def content_bytes(self) -> Int:
        var total = self.payload_bytes()
        for field in self._vectors:
            total += field.value().content_bytes()
        return total

    def payload_address(self) -> Int:
        return Int(self._payload.unsafe_ptr())

    def sparse_address(self) -> Int:
        var ordinal = self.field_ordinal(1)
        return self._vectors[ordinal].address() if ordinal >= 0 else 0

    def dense_address(self) -> Int:
        var ordinal = self.field_ordinal(0)
        return self._vectors[ordinal].address() if ordinal >= 0 else 0

    def clone(self) -> MemTableEntry:
        var entry = MemTableEntry(self.id, self.sequence, self.tombstone, [])
        entry.document_sequence = self.document_sequence
        entry._vectors = self._vectors.copy()
        entry._payload = self._payload.copy()
        return entry^

    def dense_descriptor(self) -> MemTableEntry:
        """Project the default dense owner and its independent document version.
        """
        var entry = MemTableEntry(
            self.id,
            self.document_sequence if self.has_dense() else self.sequence,
            self.tombstone or not self.has_dense(),
            [],
        )
        entry.document_sequence = self.document_sequence
        var ordinal = self.field_ordinal(0)
        if ordinal >= 0:
            entry._vectors.append(self._vectors[ordinal].copy())
        return entry^

    def _set_vector(mut self, var field: PointField):
        var ordinal = self.field_ordinal(field.id)
        if ordinal >= 0:
            self._vectors[ordinal] = field^
            return
        # Catalogs bound the field count. Keep descriptors sorted by field ID.
        self._vectors.append(field^)
        var cursor = len(self._vectors) - 1
        while (
            cursor > 0
            and self._vectors[cursor].id < self._vectors[cursor - 1].id
        ):
            self._vectors.swap_elements(cursor, cursor - 1)
            cursor -= 1


struct MemTable:
    """Single-writer latest-state map used for recovery and exact search."""

    var dimension: Int
    var last_sequence: UInt64
    var _entries: List[MemTableEntry]
    var _id_ordinals: Dict[Int, Int]
    var _live_count: Int
    var _dense_live_count: Int

    def __init__(out self, dimension: Int) raises:
        if dimension <= 0:
            raise Error("memtable dimension must be positive")
        self.dimension = dimension
        self.last_sequence = 0
        self._entries = List[MemTableEntry]()
        self._id_ordinals = Dict[Int, Int]()
        self._live_count = 0
        self._dense_live_count = 0

    def entry_count(self) -> Int:
        return len(self._entries)

    def live_count(self) -> Int:
        """Return the number of live records without materializing them."""
        return self._live_count

    def dense_live_count(self) -> Int:
        return self._dense_live_count

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
        result._dense_live_count = self._dense_live_count
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
            if (
                self._entries[index].tombstone
                or not self._entries[index].has_dense()
            ):
                self._dense_live_count += 1
            if self._entries[index].tombstone:
                self._live_count += 1
            self._entries[index].sequence = sequence
            self._entries[index].tombstone = False
            # Replacing default dense and payload keeps other live field owners.
            self._entries[index]._set_vector(
                PointField(0, VectorValue._legacy_dense(values^))
            )
            self._entries[index].document_sequence = sequence
            self._entries[index]._payload = ArcPointer(fields^)
            return

        self._entries.append(
            MemTableEntry.with_fields(id, sequence, False, values^, fields^)
        )
        self._id_ordinals[id] = len(self._entries) - 1
        self._live_count += 1
        self._dense_live_count += 1

    def put(mut self, var entry: MemTableEntry):
        """Install one already-accepted point state, replacing its ID's slot."""
        if entry.sequence > self.last_sequence:
            self.last_sequence = entry.sequence
        var index = self.ordinal_for(entry.id)
        if not entry.tombstone and entry.has_dense():
            self._dense_live_count += 1
        if (
            index >= 0
            and not self._entries[index].tombstone
            and self._entries[index].has_dense()
        ):
            self._dense_live_count -= 1
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
        self._entries[index]._set_vector(
            PointField(1, VectorValue.sparse(elements^))
        )

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
                if self._entries[index].has_dense():
                    self._dense_live_count -= 1
            self._entries[index].sequence = sequence
            self._entries[index].tombstone = True
            self._entries[index].document_sequence = 0
            self._entries[index]._vectors = List[PointField]()
            self._entries[index]._payload = ArcPointer(List[DocumentField]())
            return

        self._entries.append(MemTableEntry(id, sequence, True, List[Float32]()))
        self._id_ordinals[id] = len(self._entries) - 1

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        var index = self.ordinal_for(id)
        if (
            index < 0
            or self._entries[index].tombstone
            or not self._entries[index].has_dense()
        ):
            return Optional[DocumentRecord]()
        var vector = self._entries[index].values().copy()
        var fields = clone_fields(self._entries[index].fields())
        var record = DocumentRecord(
            id,
            self._entries[index].document_sequence,
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
        self._dense_live_count = 0
        for ordinal in range(len(self._entries)):
            self._id_ordinals[self._entries[ordinal].id] = ordinal
            if not self._entries[ordinal].tombstone:
                self._live_count += 1
                if self._entries[ordinal].has_dense():
                    self._dense_live_count += 1

    def _validate_ordinal(self, ordinal: Int) raises:
        if ordinal < 0 or ordinal >= len(self._entries):
            raise Error("memtable ordinal out of bounds")

    def _advance_sequence(mut self, sequence: UInt64):
        if sequence > self.last_sequence:
            self.last_sequence = sequence
