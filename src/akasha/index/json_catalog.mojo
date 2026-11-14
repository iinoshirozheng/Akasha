"""Bounded JSON index definitions; publication belongs to the manifest."""
from akasha.document.record import validate_field_name
from akasha.document.jsonb_path import JsonbPath
from akasha.storage.checksum import BinaryWriter, BorrowedBinaryReader


struct JsonIndexDefinition(Copyable, Movable):
    var name: String
    var column: String
    var path: String
    var target: UInt8
    var kind: UInt8

    def __init__(out self, var name: String, var column: String, var path: String,
                 target: UInt8, kind: UInt8 = 1):
        self.name = name^
        self.column = column^
        self.path = path^
        self.target = target
        self.kind = kind

    def validate(self) raises:
        if self.kind != 1 and self.kind != 2:
            raise Error("unsupported JSON index kind")
        validate_field_name(self.name)
        validate_field_name(self.column)
        if self.target < 1 or self.target > 5:
            raise Error("invalid JSON catalog learned type")
        _ = JsonbPath.parse(self.path)


struct JsonIndexCatalog(Copyable, Movable):
    var revision: UInt64
    var definitions: List[JsonIndexDefinition]

    def __init__(out self):
        self.revision = 0
        self.definitions = List[JsonIndexDefinition]()

    def validate(self) raises:
        if len(self.definitions) > 256:
            raise Error("JSON index catalog count exceeds limit")
        if len(self.definitions) != 0 and self.revision == 0:
            raise Error("nonempty JSON index catalog requires a revision")
        var names = Dict[String, Bool]()
        var size = 12
        for definition in self.definitions:
            definition.validate()
            if definition.name in names:
                raise Error("duplicate JSON index name")
            names[definition.name] = True
            size += 16 + definition.name.byte_length() + definition.column.byte_length() + definition.path.byte_length()
            if size > 16 * 1024 * 1024:
                raise Error("JSON index catalog exceeds byte limit")


def encode_json_catalog(catalog: JsonIndexCatalog) raises -> List[UInt8]:
    catalog.validate()
    var writer = BinaryWriter()
    var version = UInt16(1)
    for definition in catalog.definitions:
        if definition.kind == 2:
            version = 2
    writer.write_u16(version)
    writer.write_u16(UInt16(len(catalog.definitions)))
    writer.write_u64(catalog.revision)
    for definition in catalog.definitions:
        writer.write_u32(UInt32(definition.name.byte_length()))
        writer.write_u32(UInt32(definition.column.byte_length()))
        writer.write_u32(UInt32(definition.path.byte_length()))
        writer.write_u8(definition.kind)
        writer.write_u8(definition.target)
        writer.write_u16(0)
        for text in [definition.name.copy(), definition.column.copy(), definition.path.copy()]:
            for byte in text.as_bytes():
                writer.write_u8(byte)
    return writer.take_bytes()


def decode_json_catalog(bytes: Span[UInt8, _]) raises -> JsonIndexCatalog:
    if len(bytes) < 12 or len(bytes) > 16 * 1024 * 1024:
        raise Error("JSON index catalog length exceeds bounds")
    var reader = BorrowedBinaryReader(bytes)
    var version = reader.read_u16()
    if version != 1 and version != 2:
        raise Error("unsupported JSON index catalog version")
    var count = Int(reader.read_u16())
    if count > 256:
        raise Error("JSON index catalog count exceeds limit")
    var catalog = JsonIndexCatalog()
    catalog.revision = reader.read_u64()
    for _ in range(count):
        var name_length = Int(reader.read_u32())
        var column_length = Int(reader.read_u32())
        var path_length = Int(reader.read_u32())
        var kind = reader.read_u8()
        if kind != 1 and (version != 2 or kind != 2):
            raise Error("unsupported JSON index kind")
        var target = reader.read_u8()
        if reader.read_u16() != 0:
            raise Error("nonzero JSON index reserved bytes")
        var name = String(from_utf8=reader.read_span(name_length))
        var column = String(from_utf8=reader.read_span(column_length))
        var path = String(from_utf8=reader.read_span(path_length))
        catalog.definitions.append(JsonIndexDefinition(name^, column^, path^, target, kind))
    if reader.remaining() != 0:
        raise Error("unexpected JSON catalog trailing bytes")
    catalog.validate()
    return catalog^
