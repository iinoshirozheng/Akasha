from akasha.document.codec import encode_payload
from akasha.document.record import DocumentField, DocumentRecord, clone_fields
from akasha.document.vector_schema import FieldCatalog, MAX_VECTOR_FIELDS
from akasha.document.vector_value import VectorValue
from std.memory import ArcPointer
from std.math import isfinite


def _validate_payload(fields: List[DocumentField]) raises:
    for index in range(len(fields)):
        ref field = fields[index]
        if field.value.is_floating() and not isfinite(field.value.as_float()):
            raise Error("point payload floats must be finite")
    _ = encode_payload(fields)


struct PointField(Copyable, Movable):
    """A field descriptor whose copies retain the same immutable value."""

    var id: Int
    var _value: ArcPointer[VectorValue]

    def __init__(out self, id: Int, var value: VectorValue):
        self.id = id
        self._value = ArcPointer(value^)

    def __init__(out self, id: Int, var value: ArcPointer[VectorValue]):
        self.id = id
        self._value = value^

    def value(self) -> ref[origin_of(self._value[], self)] VectorValue:
        return self._value[]

    def address(self) -> Int:
        return Int(self._value.unsafe_ptr())


@fieldwise_init
struct FieldUpdate(Copyable, Movable):
    """Set a concrete field value, or explicitly remove that field."""

    var id: Int
    var _value: Optional[ArcPointer[VectorValue]]

    @staticmethod
    def set(id: Int, var value: VectorValue) -> FieldUpdate:
        return FieldUpdate(id, Optional(ArcPointer(value^)))

    @staticmethod
    def remove(id: Int) -> FieldUpdate:
        return FieldUpdate(id, Optional[ArcPointer[VectorValue]]())

    def is_remove(self) -> Bool:
        return not self._value

    def value(
        self,
    ) raises -> ref[origin_of(self._value.value()[], self)] VectorValue:
        if not self._value:
            raise Error("removed field has no value")
        return self._value.value()[]


struct PointMutation(Movable):
    """A field patch; kinds are merge/create=1, delete=2, patch-existing=3.

    An absent payload preserves the current payload. A present empty payload
    clears it. Field updates are unique and sorted by catalog ID on the wire.
    """

    var id: Int
    var kind: UInt8
    var _fields: List[FieldUpdate]
    var _payload: Optional[ArcPointer[List[DocumentField]]]

    def __init__(
        out self,
        id: Int,
        kind: UInt8,
        var fields: List[FieldUpdate],
        var payload: Optional[List[DocumentField]] = Optional[
            List[DocumentField]
        ](),
    ):
        self.id = id
        self.kind = kind
        self._fields = fields^
        self._payload = Optional[ArcPointer[List[DocumentField]]]()
        if payload:
            self._payload = Optional(ArcPointer(payload.take()))

    @staticmethod
    def delete(id: Int) -> PointMutation:
        return PointMutation(id, 2, List[FieldUpdate]())

    def field_count(self) -> Int:
        return len(self._fields)

    def field_at(
        self, ordinal: Int
    ) raises -> ref[origin_of(self._fields[ordinal])] FieldUpdate:
        if ordinal < 0 or ordinal >= len(self._fields):
            raise Error("field update ordinal out of bounds")
        return self._fields[ordinal]

    def replaces_payload(self) -> Bool:
        return Bool(self._payload)

    def payload(
        self,
    ) raises -> ref[origin_of(self._payload.value()[], self)] List[
        DocumentField
    ]:
        if not self._payload:
            raise Error("mutation does not replace payload")
        return self._payload.value()[]

    def validate(self, catalog: FieldCatalog) raises:
        if catalog.format_version != 2:
            raise Error("point mutations require a field catalog")
        if self.kind < 1 or self.kind > 3:
            raise Error("unknown point mutation kind")
        if self.kind == 2 and (len(self._fields) != 0 or self._payload):
            raise Error("point deletion cannot contain fields or payload")
        if len(self._fields) > MAX_VECTOR_FIELDS:
            raise Error("point field count exceeds catalog bounds")
        var previous = -1
        for index in range(len(self._fields)):
            ref field = self._fields[index]
            var ordinal = catalog.ordinal_for(field.id)
            if field.id <= previous or ordinal < 0:
                raise Error("field updates must be known, unique and sorted")
            previous = field.id
            if field._value:
                field.value().validate(catalog.field_at(ordinal))
        if self._payload:
            _validate_payload(self._payload.value()[])


@fieldwise_init
struct PointState(Copyable, Movable):
    """A complete immutable point version, including independent field owners.

    sequence covers every point mutation. document_sequence preserves the
    legacy default-dense/payload projection; it is zero without default dense.
    A tombstone has no payload or vector owner. Copying shares all field data.
    """

    var id: Int
    var sequence: UInt64
    var document_sequence: UInt64
    var tombstone: Bool
    var _fields: List[PointField]
    var _payload: Optional[ArcPointer[List[DocumentField]]]

    @staticmethod
    def live(
        id: Int,
        sequence: UInt64,
        document_sequence: UInt64,
        var fields: List[PointField],
        var payload: List[DocumentField],
    ) -> PointState:
        return PointState(
            id,
            sequence,
            document_sequence,
            False,
            fields^,
            Optional(ArcPointer(payload^)),
        )

    @staticmethod
    def deleted(id: Int, sequence: UInt64) -> PointState:
        return PointState(
            id,
            sequence,
            0,
            True,
            List[PointField](),
            Optional[ArcPointer[List[DocumentField]]](),
        )

    def field_count(self) -> Int:
        return len(self._fields)

    def field_at(
        self, ordinal: Int
    ) raises -> ref[origin_of(self._fields[ordinal])] PointField:
        if ordinal < 0 or ordinal >= len(self._fields):
            raise Error("point field ordinal out of bounds")
        return self._fields[ordinal]

    def ordinal_for(self, field_id: Int) -> Int:
        var low = 0
        var high = len(self._fields)
        while low < high:
            var mid = low + (high - low) // 2
            if self._fields[mid].id < field_id:
                low = mid + 1
            else:
                high = mid
        if low < len(self._fields) and self._fields[low].id == field_id:
            return low
        return -1

    def payload(
        self,
    ) raises -> ref[origin_of(self._payload.value()[], self)] List[
        DocumentField
    ]:
        if not self._payload:
            raise Error("deleted point has no payload")
        return self._payload.value()[]

    def payload_address(self) -> Int:
        return Int(self._payload.value().unsafe_ptr()) if self._payload else 0

    def validate(self, catalog: FieldCatalog) raises:
        if (
            catalog.format_version != 2
            or self.sequence == 0
            or self.sequence < catalog.legacy_cutover_sequence
        ):
            raise Error("point state requires a catalog and positive sequence")
        if self.document_sequence > self.sequence:
            raise Error("document version exceeds point version")
        if self.tombstone:
            if (
                self.document_sequence != 0
                or len(self._fields) != 0
                or self._payload
            ):
                raise Error("tombstone cannot contain fields or payload")
            return
        if not self._payload or len(self._fields) > MAX_VECTOR_FIELDS:
            raise Error("invalid live point field owners")
        var previous = -1
        for index in range(len(self._fields)):
            ref field = self._fields[index]
            var ordinal = catalog.ordinal_for(field.id)
            if field.id <= previous or ordinal < 0:
                raise Error("point fields must be known, unique and sorted")
            previous = field.id
            field.value().validate(catalog.field_at(ordinal))
        if (self.ordinal_for(0) >= 0) != (self.document_sequence != 0):
            raise Error(
                "document version requires default dense and vice versa"
            )
        _validate_payload(self.payload())

    def legacy_document(self) raises -> Optional[DocumentRecord]:
        var ordinal = self.ordinal_for(0)
        if self.tombstone or ordinal < 0:
            return Optional[DocumentRecord]()
        return Optional(
            DocumentRecord(
                self.id,
                self.document_sequence,
                self._fields[ordinal]
                .value()
                .dense_values[DType.float32]()
                .copy(),
                clone_fields(self.payload()),
            )
        )


def apply_point_mutation(
    previous: Optional[PointState],
    mutation: PointMutation,
    sequence: UInt64,
    catalog: FieldCatalog,
) raises -> PointState:
    """Prepare a complete replacement without changing any previous owner.

    This pure transition is not a durable commit. The collection must stage
    all batch transitions, append one validated WAL envelope, and only then
    publish. New-format mutations strictly follow the legacy cutover.
    """
    mutation.validate(catalog)
    if sequence == 0 or sequence <= catalog.legacy_cutover_sequence:
        raise Error("point mutation does not follow legacy cutover")
    if previous:
        if (
            previous.value().id != mutation.id
            or sequence <= previous.value().sequence
        ):
            raise Error("point mutation ID or sequence mismatch")
    var live = Bool(previous) and not previous.value().tombstone
    if mutation.kind == 3 and not live:
        raise Error("point patch requires an existing live point")
    if mutation.kind == 2:
        return PointState.deleted(mutation.id, sequence)

    var fields = List[PointField]()
    var old_count = previous.value().field_count() if live else 0
    var old = 0
    var document_changed = mutation.replaces_payload()
    for index in range(len(mutation._fields)):
        ref update = mutation._fields[index]
        while old < old_count and previous.value()._fields[old].id < update.id:
            fields.append(previous.value()._fields[old].copy())
            old += 1
        if old < old_count and previous.value()._fields[old].id == update.id:
            old += 1
        if not update.is_remove():
            fields.append(PointField(update.id, update._value.value().copy()))
        if update.id == 0:
            document_changed = True
    while old < old_count:
        fields.append(previous.value()._fields[old].copy())
        old += 1

    var payload: Optional[ArcPointer[List[DocumentField]]]
    if mutation._payload:
        payload = mutation._payload.copy()
    elif live:
        payload = previous.value()._payload.copy()
    else:
        payload = Optional(ArcPointer(List[DocumentField]()))
    var document_sequence = UInt64(0)
    if len(fields) != 0 and fields[0].id == 0:
        if document_changed or not live:
            document_sequence = sequence
        else:
            document_sequence = previous.value().document_sequence
    return PointState(
        mutation.id, sequence, document_sequence, False, fields^, payload^
    )
