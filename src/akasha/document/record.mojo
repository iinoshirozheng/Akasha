from akasha.document.value import PayloadValue


struct DocumentField(Movable):
    """One named, flat typed payload field."""

    var name: String
    var value: PayloadValue

    def __init__(out self, name: String, var value: PayloadValue) raises:
        _validate_field_name(name)
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


def clone_fields(fields: List[DocumentField]) raises -> List[DocumentField]:
    var result = List[DocumentField](capacity=len(fields))
    for index in range(len(fields)):
        result.append(fields[index].clone())
    return result^


def validate_fields(fields: List[DocumentField]) raises:
    for index in range(len(fields)):
        _validate_field_name(fields[index].name)
        for previous in range(index):
            if fields[index].name == fields[previous].name:
                raise Error("document field names must be unique")


def _validate_field_name(name: String) raises:
    if name.byte_length() == 0:
        raise Error("document field name cannot be empty")
    for byte in name.bytes():
        if byte == UInt8(0):
            raise Error("document field name cannot contain NUL")
