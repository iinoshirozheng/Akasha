"""Sparse value ownership and frozen input/format validation contracts."""

from std.math import isfinite


@no_inline
def sparse_product(left: Float32, right: Float32) -> Float32:
    """Round the product before addition, as Qdrant's Rust sparse loops do.

    Mojo 1.0 defaults to contract=fast, even across source statements. This
    call boundary prevents FMA from changing cancellation and overflow results.
    """
    return left * right


struct SparseElement(TrivialRegisterPassable, Writable):
    var term_id: Int
    var weight: Float32

    def __init__(out self, term_id: Int, weight: Float32):
        self.term_id = term_id
        self.weight = weight


struct SparseRecord(Movable):
    var id: Int
    var elements: List[SparseElement]

    def __init__(out self, id: Int, var elements: List[SparseElement]):
        self.id = id
        self.elements = elements^

    def clone(self) -> SparseRecord:
        var elements = self.elements.copy()
        return SparseRecord(self.id, elements^)


def validate_sparse(elements: List[SparseElement]) raises:
    var previous = -1
    for element in elements:
        if element.term_id < 0:
            raise Error("sparse term IDs must be non-negative")
        if element.term_id <= previous:
            raise Error("sparse term IDs must be unique and ascending")
        if not isfinite(element.weight):
            raise Error("sparse weights must be finite")
        previous = element.term_id


def validate_legacy_sparse(elements: List[SparseElement]) raises:
    """Validate the frozen sparse WAL v1 and segment v1/v2 contract."""
    validate_sparse(elements)
    if len(elements) == 0:
        raise Error("legacy sparse vectors cannot be empty")
    for element in elements:
        if element.weight == 0.0:
            raise Error("legacy sparse weights must be non-zero")


