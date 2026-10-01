from akasha.common.config import CollectionConfig
from std.collections import Dict


comptime MAX_VECTOR_FIELDS = 1024
comptime MAX_VECTOR_FIELD_NAME_BYTES = 65_535
comptime MAX_FIELD_CATALOG_BYTES = (
    36 + MAX_VECTOR_FIELDS * (24 + MAX_VECTOR_FIELD_NAME_BYTES + 60)
)


struct VectorFieldSpec(Copyable, Movable):
    """A field's authority schema and separate derived-index configuration."""

    var id: Int
    var name: String
    var kind: UInt8
    var scalar: UInt8
    var metric: UInt8
    var index: UInt8
    var dimension: Int
    var hnsw: Optional[CollectionConfig]

    def __init__(
        out self,
        id: Int,
        name: String,
        kind: UInt8,
        scalar: UInt8,
        metric: UInt8,
        index: UInt8,
        dimension: Int,
        var hnsw: Optional[CollectionConfig] = Optional[CollectionConfig](),
    ):
        self.id = id
        self.name = String(copy=name)
        self.kind = kind
        self.scalar = scalar
        self.metric = metric
        self.index = index
        self.dimension = dimension
        self.hnsw = hnsw^

    def validate(self) raises:
        if self.id < 0 or self.id > Int(UInt32.MAX):
            raise Error("vector field ID must fit UInt32")
        if self.dimension < 0 or self.dimension > Int(UInt32.MAX):
            raise Error("vector field dimension must fit UInt32")
        if self.name.byte_length() > MAX_VECTOR_FIELD_NAME_BYTES:
            raise Error("vector field name exceeds format limit")
        for byte in self.name.bytes():
            if byte == 0:
                raise Error("vector field name cannot contain NUL")
        if self.id < 2:
            if self.name.byte_length() != 0:
                raise Error("legacy vector field names must be empty")
        elif self.name.byte_length() == 0:
            raise Error("named vector field requires a name")

        if self.kind == 0 or self.kind == 2:
            if self.scalar > 4 or self.metric > 2 or self.dimension == 0:
                raise Error("invalid dense or multivector schema")
            if self.index > 1 or (self.kind == 2 and self.index != 0):
                raise Error("invalid dense or multivector index")
        elif self.kind == 1:
            if (
                self.scalar != 0
                or self.metric != 0
                or self.dimension != 0
                or self.index != 2
            ):
                raise Error("invalid sparse vector schema")
        elif self.kind == 3:
            if (
                self.scalar != 5
                or (self.metric != 3 and self.metric != 4)
                or self.dimension == 0
                or self.index != 0
            ):
                raise Error("invalid binary vector schema")
        else:
            raise Error("unknown vector field kind")

        if self.index == 1:
            if not self.hnsw:
                raise Error("HNSW field requires index configuration")
            self.hnsw.value().validate()
            if (
                self.hnsw.value().dimension != self.dimension
                or self.hnsw.value().ann_metric.tag() != self.metric
            ):
                raise Error("HNSW identity does not match vector field")
        elif self.hnsw:
            raise Error("non-HNSW field cannot contain HNSW configuration")

        if self.id == 0 and (
            self.kind != 0 or self.scalar != 0 or self.index != 1
        ):
            raise Error("legacy dense field must use F32 authority and HNSW")
        if self.id == 1 and self.kind != 1:
            raise Error("legacy sparse field must be sparse")


def legacy_vector_fields(
    config: CollectionConfig,
) raises -> List[VectorFieldSpec]:
    """Map legacy authority without interpreting graph encoding as its dtype."""
    config.validate()
    var fields = List[VectorFieldSpec](capacity=2)
    fields.append(
        VectorFieldSpec(
            0,
            "",
            0,
            0,
            config.ann_metric.tag(),
            1,
            config.dimension,
            Optional(config.copy()),
        )
    )
    fields.append(VectorFieldSpec(1, "", 1, 0, 0, 2, 0))
    return fields^


struct FieldCatalog(Movable):
    """Owned validated metadata; accepting a schema does not enable its writer.
    """

    var format_version: Int
    var schema_revision: UInt64
    var legacy_cutover_sequence: UInt64
    var _fields: List[VectorFieldSpec]
    var _id_ordinals: Dict[Int, Int]
    var _name_ordinals: Dict[String, Int]

    def __init__(
        out self,
        schema_revision: UInt64,
        legacy_cutover_sequence: UInt64,
        var fields: List[VectorFieldSpec],
        *,
        format_version: Int = 2,
    ) raises:
        self.format_version = format_version
        self.schema_revision = schema_revision
        self.legacy_cutover_sequence = legacy_cutover_sequence
        self._fields = fields^
        self._id_ordinals = Dict[Int, Int]()
        self._name_ordinals = Dict[String, Int]()
        self.validate()
        for ordinal in range(len(self._fields)):
            ref field = self._fields[ordinal]
            self._id_ordinals[field.id] = ordinal
            if field.id >= 2:
                self._name_ordinals[field.name] = ordinal

    def validate(self) raises:
        if len(self._fields) < 2 or len(self._fields) > MAX_VECTOR_FIELDS:
            raise Error("vector field count exceeds catalog bounds")
        if self.format_version == 1:
            if (
                self.schema_revision != 0
                or self.legacy_cutover_sequence != 0
                or len(self._fields) != 2
            ):
                raise Error("legacy catalog cannot contain extended metadata")
        elif self.format_version == 2:
            if self.schema_revision == 0:
                raise Error("field catalog revision must be positive")
        else:
            raise Error("unsupported field catalog version")
        if self._fields[0].id != 0 or self._fields[1].id != 1:
            raise Error("field catalog requires both legacy identities")
        var names = Dict[String, Int]()
        var previous = -1
        for ordinal in range(len(self._fields)):
            ref field = self._fields[ordinal]
            field.validate()
            if field.id <= previous:
                raise Error("vector field IDs must strictly increase")
            previous = field.id
            if field.id >= 2:
                if field.name in names:
                    raise Error("vector field names must be unique")
                names[field.name] = ordinal

    def field_count(self) -> Int:
        return len(self._fields)

    def field_at(
        self, ordinal: Int
    ) raises -> ref[origin_of(self._fields[ordinal])] VectorFieldSpec:
        if ordinal < 0 or ordinal >= len(self._fields):
            raise Error("vector field ordinal out of bounds")
        return self._fields[ordinal]

    def ordinal_for(self, id: Int) -> Int:
        return self._id_ordinals.get(id, -1)

    def named_ordinal(self, name: String) raises -> Int:
        if name.byte_length() == 0:
            raise Error("named vector lookup requires a nonempty name")
        return self._name_ordinals.get(name, -1)
