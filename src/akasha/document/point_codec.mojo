from akasha.document.codec import (
    decode_payload,
    encode_payload,
    MAX_PAYLOAD_BYTES,
)
from akasha.document.point_state import PointField, PointState
from akasha.document.vector_schema import (
    FieldCatalog,
    VectorFieldSpec,
    MAX_VECTOR_FIELDS,
)
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from akasha.storage.checksum import BinaryWriter, BorrowedBinaryReader
from std.memory import bitcast
from std.sys import size_of


comptime MAX_POINT_RECORD_BYTES = 256 * 1024 * 1024
comptime _POINT_HEADER_BYTES = 40


def vector_value_size(value: VectorValue, field: VectorFieldSpec) raises -> Int:
    """Validate and bound a typed body before allocating an encoded buffer."""
    value.validate(field)
    var size: Int
    if field.kind == 1:
        var count = len(value.sparse_values())
        if count > (MAX_POINT_RECORD_BYTES - 4) // 12:
            raise Error("sparse vector body exceeds record limit")
        size = 4 + count * 12
    elif field.kind == 3:
        size = (field.dimension + 7) // 8
    else:
        var width = 4 if field.scalar == 0 else (2 if field.scalar <= 2 else 1)
        var rows = value.row_count() if field.kind == 2 else 1
        var prefix = 4 if field.kind == 2 else 0
        if rows > (MAX_POINT_RECORD_BYTES - prefix) // width // field.dimension:
            raise Error("numeric vector body exceeds record limit")
        size = prefix + rows * field.dimension * width
    if size > MAX_POINT_RECORD_BYTES:
        raise Error("vector body exceeds record limit")
    return size


def _write_numeric[
    dtype: DType
](mut writer: BinaryWriter, values: List[Scalar[dtype]]):
    for value in values:
        comptime if dtype == DType.float32:
            writer.write_u32(bitcast[DType.uint32](value))
        elif dtype == DType.float16 or dtype == DType.bfloat16:
            writer.write_u16(bitcast[DType.uint16](value))
        else:
            writer.write_u8(bitcast[DType.uint8](value))


def _write_numeric_value[
    dtype: DType
](mut writer: BinaryWriter, value: VectorValue) raises:
    if value.kind() == 0:
        _write_numeric(writer, value.dense_values[dtype]())
    else:
        writer.write_u32(UInt32(value.row_count()))
        _write_numeric(writer, value.multivector_values[dtype]())


def encode_vector_value(
    value: VectorValue, field: VectorFieldSpec
) raises -> List[UInt8]:
    _ = vector_value_size(value, field)
    var writer = BinaryWriter()
    if field.kind == 1:
        ref elements = value.sparse_values()
        writer.write_u32(UInt32(len(elements)))
        for element in elements:
            writer.write_i64(Int64(element.term_id))
            writer.write_f32(element.weight)
    elif field.kind == 3:
        writer.write_bytes(value.binary_values())
    elif field.scalar == 0:
        _write_numeric_value[DType.float32](writer, value)
    elif field.scalar == 1:
        _write_numeric_value[DType.bfloat16](writer, value)
    elif field.scalar == 2:
        _write_numeric_value[DType.float16](writer, value)
    elif field.scalar == 3:
        _write_numeric_value[DType.int8](writer, value)
    else:
        _write_numeric_value[DType.uint8](writer, value)
    return writer.take_bytes()


def _read_numeric[
    dtype: DType
](bytes: Span[UInt8, _], field: VectorFieldSpec) raises -> VectorValue:
    var reader = BorrowedBinaryReader(bytes)
    var rows = Int(reader.read_u32()) if field.kind == 2 else 1
    comptime width = size_of[Scalar[dtype]]()
    # Derive the possible count from actual bounded bytes before multiplication
    # or reserve; row/dimension tags may independently contain UInt32.MAX.
    if reader.remaining() % width != 0:
        raise Error("truncated numeric scalar")
    var count = reader.remaining() // width
    if count % field.dimension != 0 or count // field.dimension != rows:
        raise Error("numeric body length does not match field shape")
    var values = List[Scalar[dtype]](capacity=count)
    for _ in range(count):
        comptime if dtype == DType.float32:
            values.append(bitcast[dtype](reader.read_u32()))
        elif dtype == DType.float16 or dtype == DType.bfloat16:
            values.append(bitcast[dtype](reader.read_u16()))
        else:
            values.append(bitcast[dtype](reader.read_u8()))
    if field.kind == 0:
        return VectorValue.dense(values^)
    return VectorValue.multivector(field.dimension, values^)


def decode_vector_value(
    bytes: Span[UInt8, _], field: VectorFieldSpec
) raises -> VectorValue:
    field.validate()
    if len(bytes) > MAX_POINT_RECORD_BYTES:
        raise Error("vector body exceeds record limit")
    if field.kind == 1:
        var reader = BorrowedBinaryReader(bytes)
        var count = Int(reader.read_u32())
        if reader.remaining() % 12 != 0 or count != reader.remaining() // 12:
            raise Error("sparse body length does not match term count")
        var elements = List[SparseElement](capacity=count)
        for _ in range(count):
            var term = Int(reader.read_i64())
            var weight = reader.read_f32()
            elements.append(SparseElement(term, weight))
        return VectorValue.sparse(elements^)
    if field.kind == 3:
        if len(bytes) != (field.dimension + 7) // 8:
            raise Error("binary vector body length mismatch")
        var bits = List[UInt8]()
        bits.extend(bytes)
        return VectorValue.binary(field.dimension, bits^)
    if field.scalar == 0:
        return _read_numeric[DType.float32](bytes, field)
    if field.scalar == 1:
        return _read_numeric[DType.bfloat16](bytes, field)
    if field.scalar == 2:
        return _read_numeric[DType.float16](bytes, field)
    if field.scalar == 3:
        return _read_numeric[DType.int8](bytes, field)
    return _read_numeric[DType.uint8](bytes, field)


def encode_point_record(
    point: PointState, catalog: FieldCatalog
) raises -> List[UInt8]:
    point.validate(catalog)
    var payload = List[UInt8]()
    if not point.tombstone:
        payload = encode_payload(point.payload())
    var total = _POINT_HEADER_BYTES + len(payload)
    for ordinal in range(point.field_count()):
        ref field = point.field_at(ordinal)
        var size = vector_value_size(
            field.value(), catalog.field_at(catalog.ordinal_for(field.id))
        )
        if total > MAX_POINT_RECORD_BYTES - 8 - size:
            raise Error("point record exceeds size limit")
        total += 8 + size
    var writer = BinaryWriter()
    writer.write_u32(UInt32(total))
    writer.write_u8(UInt8(2) if point.tombstone else UInt8(1))
    writer.write_u8(0)
    writer.write_u16(0)
    writer.write_i64(Int64(point.id))
    writer.write_u64(point.sequence)
    writer.write_u64(point.document_sequence)
    writer.write_u32(UInt32(point.field_count()))
    writer.write_u32(UInt32(len(payload)))
    writer.write_bytes(payload)
    for ordinal in range(point.field_count()):
        ref field = point.field_at(ordinal)
        var body = encode_vector_value(
            field.value(), catalog.field_at(catalog.ordinal_for(field.id))
        )
        writer.write_u32(UInt32(field.id))
        writer.write_u32(UInt32(len(body)))
        writer.write_bytes(body)
    return writer.take_bytes()


def decode_point_record(
    bytes: List[UInt8], catalog: FieldCatalog
) raises -> PointState:
    return decode_point_record(Span(bytes), catalog)


def decode_point_record(
    bytes: Span[UInt8, _], catalog: FieldCatalog
) raises -> PointState:
    """Decode owned field data from one bounded complete-state record.

    The enclosing durable envelope is responsible for version/catalog binding
    and checksum validation before this decoder's result becomes visible.
    """
    if len(bytes) < _POINT_HEADER_BYTES or len(bytes) > MAX_POINT_RECORD_BYTES:
        raise Error("point record length exceeds bounds")
    var reader = BorrowedBinaryReader(bytes)
    if Int(reader.read_u32()) != len(bytes):
        raise Error("point record length mismatch")
    var state = reader.read_u8()
    if state != 1 and state != 2:
        raise Error("unknown point state")
    if reader.read_u8() != 0 or reader.read_u16() != 0:
        raise Error("point record has unknown flags or reserved bytes")
    var id = Int(reader.read_i64())
    var sequence = reader.read_u64()
    var document_sequence = reader.read_u64()
    if (
        catalog.format_version != 2
        or sequence == 0
        or sequence < catalog.legacy_cutover_sequence
        or document_sequence > sequence
    ):
        raise Error("invalid point catalog or sequence")
    var count = Int(reader.read_u32())
    var payload_length = Int(reader.read_u32())
    if count > MAX_VECTOR_FIELDS or payload_length > MAX_PAYLOAD_BYTES:
        raise Error("point field count or payload exceeds bounds")
    if state == 2:
        if (
            count != 0
            or payload_length != 0
            or document_sequence != 0
            or reader.remaining() != 0
        ):
            raise Error("tombstone cannot contain fields or payload")
        var point = PointState.deleted(id, sequence)
        point.validate(catalog)
        return point^
    var payload = decode_payload(reader.read_span(payload_length))
    if count > reader.remaining() // 8:
        raise Error("truncated point field descriptors")
    var fields = List[PointField](capacity=count)
    var previous = -1
    for _ in range(count):
        var field_id = Int(reader.read_u32())
        var body_length = Int(reader.read_u32())
        var ordinal = catalog.ordinal_for(field_id)
        if field_id <= previous or ordinal < 0:
            raise Error("point fields must be known, unique and sorted")
        previous = field_id
        var value = decode_vector_value(
            reader.read_span(body_length), catalog.field_at(ordinal)
        )
        fields.append(PointField(field_id, value^))
    if reader.remaining() != 0:
        raise Error("unexpected trailing point bytes")
    var point = PointState.live(
        id, sequence, document_sequence, fields^, payload^
    )
    point.validate(catalog)
    return point^
