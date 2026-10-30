from akasha.document.record import DocumentField, validate_fields
from akasha.document.value import PayloadValue
from akasha.document.jsonb import JsonbValue
from akasha.storage.checksum import BorrowedBinaryReader, BinaryWriter


comptime MAX_PAYLOAD_FIELDS = 1024
comptime MAX_PAYLOAD_BYTES = 16 * 1024 * 1024
comptime _STRING_KIND = UInt8(1)
comptime _INT_KIND = UInt8(2)
comptime _FLOAT_KIND = UInt8(3)
comptime _BOOL_KIND = UInt8(4)


def _encode_payload_v1(fields: List[DocumentField]) raises -> List[UInt8]:
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
    """Strictly decode one complete payload in v1, v2 or v3."""
    return decode_payload(Span(bytes))


def decode_payload(bytes: Span[UInt8, _]) raises -> List[DocumentField]:
    """Borrow encoded bytes and return independently owned document fields."""
    if len(bytes) > MAX_PAYLOAD_BYTES:
        raise Error("encoded payload exceeds size limit")

    var reader = BorrowedBinaryReader(bytes)
    var marker = reader.read_u32()
    if marker == UInt32.MAX:
        var version = Int(reader.read_u16())
        if (version != 2 and version != 3) or reader.read_u16() != 0:
            raise Error("unsupported payload version or flags")
        var field_count = Int(reader.read_u32())
        if field_count > MAX_PAYLOAD_FIELDS:
            raise Error("payload field count exceeds limit")
        var fields = List[DocumentField](capacity=field_count)
        var nodes = 0
        for _ in range(field_count):
            var name_length = Int(reader.read_u16())
            var name = String(from_utf8=reader.read_span(name_length))
            var value = _read_value(reader, version, 0, nodes)
            fields.append(DocumentField(name, value^))
        if reader.remaining() != 0:
            raise Error("unexpected trailing payload bytes")
        validate_fields(fields)
        return fields^
    var field_count = Int(marker)
    if field_count > MAX_PAYLOAD_FIELDS:
        raise Error("payload field count exceeds limit")
    var fields = List[DocumentField](capacity=field_count)
    for _ in range(field_count):
        var name_length = Int(reader.read_u16())
        var name_bytes = reader.read_span(name_length)
        var name = String(from_utf8=name_bytes)
        var kind = reader.read_u8()
        var value: PayloadValue
        if kind == _STRING_KIND:
            var value_length = Int(reader.read_u32())
            var value_bytes = reader.read_span(value_length)
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


def encode_payload(fields: List[DocumentField], version: Int = 3) raises -> List[UInt8]:
    """New writes emit v3; explicit v1/v2 encoders retain frozen fixtures."""
    if version == 1:
        return _encode_payload_v1(fields)
    if version != 2 and version != 3:
        raise Error("unsupported payload version")
    if len(fields) > MAX_PAYLOAD_FIELDS:
        raise Error("payload field count exceeds limit")
    validate_fields(fields)
    var size = 12
    var nodes = 0
    for i in range(len(fields)):
        var name_bytes = fields[i].name.byte_length()
        if name_bytes > Int(UInt16.MAX):
            raise Error("payload field name exceeds limit")
        nodes += fields[i].value.node_count()
        if nodes > PayloadValue.MAX_NODES:
            raise Error("payload node count exceeds limit")
        size += 2 + name_bytes + _value_size(fields[i].value, version)
        if size > MAX_PAYLOAD_BYTES:
            raise Error("encoded payload exceeds size limit")
    var writer = BinaryWriter()
    writer.write_u32(UInt32.MAX)
    writer.write_u16(UInt16(version))
    writer.write_u16(0)
    writer.write_u32(UInt32(len(fields)))
    for i in range(len(fields)):
        writer.write_u16(UInt16(fields[i].name.byte_length()))
        for byte in fields[i].name.bytes():
            writer.write_u8(byte)
        _write_value(writer, fields[i].value)
    return writer.take_bytes()


def _value_size(value: PayloadValue, version: Int) raises -> Int:
    if value.is_jsonb():
        if version < 3:
            raise Error("JSONB requires payload version 3")
        return 5 + len(value._jsonb_value.value()._data)
    if value.is_string():
        return 5 + value._string_value.byte_length()
    if value.is_integer() or value.is_floating() or value.is_unsigned():
        return 9
    if value.is_boolean():
        return 2
    if value.is_null():
        return 1
    if not value.is_container():
        raise Error("unknown payload value kind")
    var children = value.children()
    var keys = value.keys() if value.is_object() else List[String]()
    var size = 5
    for i in range(len(children)):
        if value.is_object():
            size += 4 + keys[i].byte_length()
        size += _value_size(children[i], version)
        if size > MAX_PAYLOAD_BYTES:
            raise Error("encoded payload exceeds size limit")
    return size


def _write_value(mut writer: BinaryWriter, value: PayloadValue) raises:
    writer.write_u8(value.kind())
    if value.is_string():
        writer.write_u32(UInt32(value._string_value.byte_length()))
        for byte in value._string_value.bytes():
            writer.write_u8(byte)
    elif value.is_integer():
        writer.write_i64(value.as_int())
    elif value.is_floating():
        writer.write_f64(value.as_float())
    elif value.is_boolean():
        writer.write_u8(UInt8(value.as_bool()))
    elif value.is_unsigned():
        writer.write_u64(value.as_uint())
    elif value.is_jsonb():
        ref body = value._jsonb_value.value()._data
        writer.write_u32(UInt32(len(body)))
        for byte in body:
            writer.write_u8(byte)
    elif value.is_container():
        var children = value.children()
        var keys = value.keys() if value.is_object() else List[String]()
        writer.write_u32(UInt32(len(children)))
        for i in range(len(children)):
            if value.is_object():
                writer.write_u32(UInt32(keys[i].byte_length()))
                for byte in keys[i].bytes():
                    writer.write_u8(byte)
            _write_value(writer, children[i])


def _read_value[origin: ImmOrigin, //](mut reader: BorrowedBinaryReader[origin], version: Int, depth: Int,
                                mut nodes: Int) raises -> PayloadValue:
    nodes += 1
    if nodes > PayloadValue.MAX_NODES:
        raise Error("payload node count exceeds limit")
    var kind = reader.read_u8()
    if kind == 1:
        var length = Int(reader.read_u32())
        return PayloadValue.string(String(from_utf8=reader.read_span(length)))
    if kind == 2:
        return PayloadValue.integer(reader.read_i64())
    if kind == 3:
        return PayloadValue.floating(reader.read_f64())
    if kind == 4:
        var encoded = reader.read_u8()
        if encoded > 1:
            raise Error("invalid payload bool encoding")
        return PayloadValue.boolean(encoded == 1)
    if kind == 5:
        return PayloadValue.null()
    if kind == 8:
        return PayloadValue.unsigned(reader.read_u64())
    if kind == 9 and version >= 3:
        var length = Int(reader.read_u32())
        var value = JsonbValue(reader.read_span(length))
        nodes += value._node_count - 1
        if nodes > PayloadValue.MAX_NODES:
            raise Error("payload node count exceeds limit")
        if depth + value._depth > PayloadValue.MAX_DEPTH:
            raise Error("payload nesting depth exceeds limit")
        return PayloadValue.jsonb(value^)
    if kind != 6 and kind != 7:
        raise Error("unknown payload value kind")
    if depth >= PayloadValue.MAX_DEPTH:
        raise Error("payload nesting depth exceeds limit")
    var count = Int(reader.read_u32())
    if count > PayloadValue.MAX_NODES - nodes or count > reader.remaining():
        raise Error("payload child count exceeds bounds")
    var keys = List[String]()
    var seen = Dict[String, Bool]()
    var children = List[PayloadValue]()
    for _ in range(count):
        if kind == 7:
            var length = Int(reader.read_u32())
            var key = String(from_utf8=reader.read_span(length))
            if key in seen:
                raise Error("duplicate encoded payload object key")
            seen[key] = True
            keys.append(key^)
        children.append(_read_value(reader, version, depth + 1, nodes))
    if kind == 6:
        return PayloadValue.array(children^)
    return PayloadValue.object(keys^, children^)
