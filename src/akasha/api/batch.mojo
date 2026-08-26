from akasha.document.record import DocumentField


struct BatchMutation(Movable):
    """One validated-at-commit dense document mutation."""

    var id: Int
    var is_delete: Bool
    var values: List[Float32]
    var fields: List[DocumentField]

    def __init__(
        out self,
        id: Int,
        is_delete: Bool,
        var values: List[Float32],
        var fields: List[DocumentField],
    ):
        self.id = id
        self.is_delete = is_delete
        self.values = values^
        self.fields = fields^

    @staticmethod
    def upsert(id: Int, var values: List[Float32]) -> BatchMutation:
        return BatchMutation(id, False, values^, List[DocumentField]())

    @staticmethod
    def document_upsert(
        id: Int,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) -> BatchMutation:
        return BatchMutation(id, False, values^, fields^)

    @staticmethod
    def delete(id: Int) -> BatchMutation:
        return BatchMutation(id, True, List[Float32](), List[DocumentField]())


struct BatchWriteResult(TrivialRegisterPassable, Writable):
    """The contiguous sequence range committed by one batch."""

    var first_sequence: UInt64
    var last_sequence: UInt64
    var count: Int

    def __init__(
        out self,
        first_sequence: UInt64,
        last_sequence: UInt64,
        count: Int,
    ):
        self.first_sequence = first_sequence
        self.last_sequence = last_sequence
        self.count = count
