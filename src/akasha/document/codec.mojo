from akasha.document.record import DocumentField, validate_fields
from akasha.document.value import PayloadValue
from akasha.storage.checksum import BinaryReader, BinaryWriter


comptime MAX_PAYLOAD_FIELDS = 1024
comptime MAX_PAYLOAD_BYTES = 16 * 1024 * 1024
comptime _STRING_KIND = UInt8(1)
comptime _INT_KIND = UInt8(2)
comptime _FLOAT_KIND = UInt8(3)
comptime _BOOL_KIND = UInt8(4)


def encode_payload(fields: List[DocumentField]) raises -> List[UInt8]:
    """Encode ordered flat document fields into payload format v1."""
    if len(fields) > MAX_PAYLOAD_FIELDS:
        raise Error("payload field count exceeds limit")
    validate_fields(fields)

    var writer = BinaryWriter()
    writer.write_u32(UInt32(len(fields)))
    for index in range(len(fields)):
        var name_length = fields[index].name.byte_length()
        if name_length > Int(UInt16.MAX):
            raise Error("payload field name exceeds limit")
        writer.write_u16(UInt16(name_length))
        for byte in fields[index].name.bytes():
            writer.write_u8(byte)

        var kind = fields[index].value.kind()
        writer.write_u8(kind)
        if kind == _STRING_KIND:
            var value = fields[index].value.as_string()
            if value.byte_length() > Int(UInt32.MAX):
                raise Error("payload string exceeds format limit")
            writer.write_u32(UInt32(value.byte_length()))
            for byte in value.bytes():
                writer.write_u8(byte)
        elif kind == _INT_KIND:
            writer.write_i64(fields[index].value.as_int())
        elif kind == _FLOAT_KIND:
            writer.write_f64(fields[index].value.as_float())
        elif kind == _BOOL_KIND:
            writer.write_u8(
                UInt8(1) if fields[index].value.as_bool() else UInt8(0)
            )
        else:
            raise Error("unknown payload value kind")

    var bytes = writer.take_bytes()
    if len(bytes) > MAX_PAYLOAD_BYTES:
        raise Error("encoded payload exceeds size limit")
    return bytes^


def decode_payload(var bytes: List[UInt8]) raises -> List[DocumentField]:
    """Strictly decode one complete payload format v1 value."""
    if len(bytes) > MAX_PAYLOAD_BYTES:
        raise Error("encoded payload exceeds size limit")

    var reader = BinaryReader(bytes^)
    var field_count = Int(reader.read_u32())
    if field_count > MAX_PAYLOAD_FIELDS:
        raise Error("payload field count exceeds limit")
    var fields = List[DocumentField](capacity=field_count)
    for _ in range(field_count):
        var name_length = Int(reader.read_u16())
        var name_bytes = reader.read_bytes(name_length)
        var name = String(from_utf8=name_bytes)
        var kind = reader.read_u8()
        var value: PayloadValue
        if kind == _STRING_KIND:
            var value_length = Int(reader.read_u32())
            var value_bytes = reader.read_bytes(value_length)
            value = PayloadValue.string(String(from_utf8=value_bytes))
        elif kind == _INT_KIND:
            value = PayloadValue.integer(reader.read_i64())
        elif kind == _FLOAT_KIND:
            value = PayloadValue.floating(reader.read_f64())
        elif kind == _BOOL_KIND:
            var encoded_bool = reader.read_u8()
            if encoded_bool > 1:
                raise Error("invalid payload bool encoding")
            value = PayloadValue.boolean(encoded_bool == 1)
        else:
            raise Error("unknown payload value kind")
        fields.append(DocumentField(name, value^))

    if reader.remaining() != 0:
        raise Error("unexpected trailing payload bytes")
    validate_fields(fields)
    return fields^
