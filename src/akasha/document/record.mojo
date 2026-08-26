from akasha.document.value import PayloadValue


struct DocumentField(Movable):
    """One named, flat typed payload field."""

    var name: String
    var value: PayloadValue

    def __init__(out self, name: String, var value: PayloadValue) raises:
        validate_field_name(name)
        self.name = String(copy=name)
        self.value = value^

    def clone(self) raises -> DocumentField:
        return DocumentField(self.name, self.value.clone())


struct DocumentRecord(Movable):
    """An owned live point vector and its latest typed payload."""

    var id: Int
    var sequence: UInt64
    var vector: List[Float32]
    var fields: List[DocumentField]

    def __init__(
        out self,
        id: Int,
        sequence: UInt64,
        var vector: List[Float32],
        var fields: List[DocumentField],
    ) raises:
        validate_fields(fields)
        self.id = id
        self.sequence = sequence
        self.vector = vector^
        self.fields = fields^

    def get_field(self, name: String) -> Optional[PayloadValue]:
        for index in range(len(self.fields)):
            if self.fields[index].name == name:
                return Optional(self.fields[index].value.clone())
        return Optional[PayloadValue]()

    def clone(self) raises -> DocumentRecord:
        var vector = List[Float32](capacity=len(self.vector))
        for value in self.vector:
            vector.append(value)
        var fields = clone_fields(self.fields)
        return DocumentRecord(self.id, self.sequence, vector^, fields^)


struct FieldProjection(Movable):
    """Controls which owned vector and payload fields cross a read boundary."""

    var include_vector: Bool
    var include_all_fields: Bool
    var field_names: List[String]

    def __init__(
        out self,
        include_vector: Bool,
        include_all_fields: Bool,
        var field_names: List[String],
    ) raises:
        if include_all_fields and len(field_names) != 0:
            raise Error("all-fields projection cannot contain named fields")
        for index in range(len(field_names)):
            validate_field_name(field_names[index])
            for previous in range(index):
                if field_names[index] == field_names[previous]:
                    raise Error("projection field names must be unique")
        self.include_vector = include_vector
        self.include_all_fields = include_all_fields
        self.field_names = field_names^

    @staticmethod
    def all(include_vector: Bool = True) raises -> FieldProjection:
        var names = List[String]()
        return FieldProjection(include_vector, True, names^)

    @staticmethod
    def named(
        include_vector: Bool, var field_names: List[String]
    ) raises -> FieldProjection:
        return FieldProjection(include_vector, False, field_names^)

    @staticmethod
    def metadata_only() raises -> FieldProjection:
        var names = List[String]()
        return FieldProjection(False, False, names^)

    def includes_field(self, name: String) -> Bool:
        if self.include_all_fields:
            return True
        for requested in self.field_names:
            if requested == name:
                return True
        return False


def project_document(
    document: DocumentRecord, projection: FieldProjection
) raises -> DocumentRecord:
    var vector = List[Float32]()
    if projection.include_vector:
        vector = document.vector.copy()
    var fields = List[DocumentField]()
    for index in range(len(document.fields)):
        if projection.includes_field(document.fields[index].name):
            fields.append(document.fields[index].clone())
    return DocumentRecord(document.id, document.sequence, vector^, fields^)


def clone_fields(fields: List[DocumentField]) raises -> List[DocumentField]:
    var result = List[DocumentField](capacity=len(fields))
    for index in range(len(fields)):
        result.append(fields[index].clone())
    return result^


def validate_fields(fields: List[DocumentField]) raises:
    for index in range(len(fields)):
        validate_field_name(fields[index].name)
        for previous in range(index):
            if fields[index].name == fields[previous].name:
                raise Error("document field names must be unique")


def validate_field_name(name: String) raises:
    if name.byte_length() == 0:
        raise Error("document field name cannot be empty")
    for byte in name.bytes():
        if byte == UInt8(0):
            raise Error("document field name cannot contain NUL")
