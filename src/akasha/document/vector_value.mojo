from akasha.document.vector_schema import VectorFieldSpec
from akasha.index.sparse import SparseElement, validate_sparse
from std.math import isfinite
from std.utils import Variant


comptime _NumericStorage = Variant[
    List[Float32], List[BFloat16], List[Float16], List[Int8], List[UInt8]
]


struct _NumericValues(Movable):
    """Own concrete scalar storage; the variant never promotes authority."""

    var _data: _NumericStorage
    var scalar: UInt8
    var count: Int

    @staticmethod
    def legacy_f32(var values: List[Float32]) -> _NumericValues:
        """Preserve legacy codec bits; v4 construction uses finite validation.
        """
        return _NumericValues(_NumericStorage(values^))

    def __init__(out self, var data: _NumericStorage):
        self.scalar = 0
        self.count = len(data[List[Float32]])
        self._data = data^

    def __init__[
        dtype: DType
    ](out self, var values: List[Scalar[dtype]]) raises:
        comptime assert dtype in (
            DType.float32,
            DType.bfloat16,
            DType.float16,
            DType.int8,
            DType.uint8,
        )
        comptime if dtype == DType.float32:
            self.scalar = 0
        elif dtype == DType.bfloat16:
            self.scalar = 1
        elif dtype == DType.float16:
            self.scalar = 2
        elif dtype == DType.int8:
            self.scalar = 3
        else:
            self.scalar = 4
        comptime if dtype == DType.float32 or dtype == DType.bfloat16 or dtype == DType.float16:
            for value in values:
                if not isfinite(value):
                    raise Error("vector values must be finite")
        self.count = len(values)
        self._data = _NumericStorage(values^)

    def values[
        dtype: DType
    ](
        self,
    ) raises -> ref[
        origin_of(self._data[List[Scalar[dtype]]], self)
    ] List[Scalar[dtype]]:
        if not self._data.isa[List[Scalar[dtype]]]():
            raise Error("vector scalar type mismatch")
        return self._data[List[Scalar[dtype]]]


@fieldwise_init
struct _DenseValue(Movable):
    var values: _NumericValues


@fieldwise_init
struct _SparseValue(Movable):
    var values: List[SparseElement]


@fieldwise_init
struct _MultiValue(Movable):
    var dimension: Int
    var values: _NumericValues


@fieldwise_init
struct _BinaryValue(Movable):
    var dimension: Int
    var values: List[UInt8]


comptime _VectorStorage = Variant[
    _DenseValue, _SparseValue, _MultiValue, _BinaryValue
]


struct VectorValue(Movable):
    """One immutable, owned field value, independent of its name or index.

    Empty sparse and zero-row multivectors are present values. Dense vectors
    and bit vectors require positive dimensions. Absence is represented by
    the point's field map, never by a zero value or an empty dense vector.
    """

    var _data: _VectorStorage

    def __init__(out self, var data: _VectorStorage):
        self._data = data^

    @staticmethod
    def dense[
        dtype: DType
    ](var values: List[Scalar[dtype]]) raises -> VectorValue:
        _validate_dimension(len(values))
        return VectorValue(_VectorStorage(_DenseValue(_NumericValues(values^))))

    @staticmethod
    def _legacy_dense(var values: List[Float32]) -> VectorValue:
        """Only for old-format descriptors, whose readers validate dimensions.
        """
        return VectorValue(
            _VectorStorage(_DenseValue(_NumericValues.legacy_f32(values^)))
        )

    def _legacy_values(
        self,
    ) -> ref[
        origin_of(self._data[_DenseValue].values._data[List[Float32]], self)
    ] List[Float32]:
        """Borrow field 0: catalogs require this field to be dense F32."""
        return self._data[_DenseValue].values._data[List[Float32]]

    def content_bytes(self) -> Int:
        """Logical native storage bytes, without promotion or owned copies."""
        if self._data.isa[_SparseValue]():
            return len(self._data[_SparseValue].values) * 12
        if self._data.isa[_BinaryValue]():
            return len(self._data[_BinaryValue].values)
        var count = self.dimension()
        if self._data.isa[_MultiValue]():
            count = self._data[_MultiValue].values.count
        var scalar = self.scalar()
        var width = 4 if scalar == 0 else (2 if scalar < 3 else 1)
        return count * width

    @staticmethod
    def sparse(var values: List[SparseElement]) raises -> VectorValue:
        if len(values) > Int(UInt32.MAX):
            raise Error("sparse vector count exceeds format limit")
        if len(values) != 0:
            validate_sparse(values)
        return VectorValue(_VectorStorage(_SparseValue(values^)))

    @staticmethod
    def multivector[
        dtype: DType
    ](dimension: Int, var values: List[Scalar[dtype]]) raises -> VectorValue:
        _validate_dimension(dimension)
        if len(values) % dimension != 0:
            raise Error("multivector contains an incomplete row")
        if len(values) // dimension > Int(UInt32.MAX):
            raise Error("multivector row count exceeds format limit")
        return VectorValue(
            _VectorStorage(_MultiValue(dimension, _NumericValues(values^)))
        )

    @staticmethod
    def binary(dimension: Int, var values: List[UInt8]) raises -> VectorValue:
        _validate_dimension(dimension)
        if len(values) != (dimension + 7) // 8:
            raise Error("binary vector byte count does not match bit dimension")
        var tail = dimension % 8
        if tail != 0 and values[len(values) - 1] >> UInt8(tail) != 0:
            raise Error("binary vector has nonzero padding bits")
        return VectorValue(_VectorStorage(_BinaryValue(dimension, values^)))

    def kind(self) -> UInt8:
        if self._data.isa[_DenseValue]():
            return 0
        if self._data.isa[_SparseValue]():
            return 1
        if self._data.isa[_MultiValue]():
            return 2
        return 3

    def scalar(self) -> UInt8:
        if self._data.isa[_DenseValue]():
            return self._data[_DenseValue].values.scalar
        if self._data.isa[_MultiValue]():
            return self._data[_MultiValue].values.scalar
        return UInt8(0) if self._data.isa[_SparseValue]() else UInt8(5)

    def dimension(self) -> Int:
        if self._data.isa[_DenseValue]():
            return self._data[_DenseValue].values.count
        if self._data.isa[_MultiValue]():
            return self._data[_MultiValue].dimension
        if self._data.isa[_BinaryValue]():
            return self._data[_BinaryValue].dimension
        return 0

    def row_count(self) raises -> Int:
        if not self._data.isa[_MultiValue]():
            raise Error("vector is not a multivector")
        ref matrix = self._data[_MultiValue]
        return matrix.values.count // matrix.dimension

    def validate(self, field: VectorFieldSpec) raises:
        field.validate()
        if self.kind() != field.kind or self.scalar() != field.scalar:
            raise Error("vector field kind or scalar mismatch")
        if self.dimension() != field.dimension:
            raise Error("vector field dimension mismatch")

    def dense_values[
        dtype: DType
    ](
        self,
    ) raises -> ref[
        origin_of(self._data[_DenseValue].values.values[dtype](), self)
    ] List[Scalar[dtype]]:
        if not self._data.isa[_DenseValue]():
            raise Error("vector is not dense")
        return self._data[_DenseValue].values.values[dtype]()

    def sparse_values(
        self,
    ) raises -> ref[origin_of(self._data[_SparseValue].values, self)] List[
        SparseElement
    ]:
        if not self._data.isa[_SparseValue]():
            raise Error("vector is not sparse")
        return self._data[_SparseValue].values

    def multivector_values[
        dtype: DType
    ](
        self,
    ) raises -> ref[
        origin_of(self._data[_MultiValue].values.values[dtype](), self)
    ] List[Scalar[dtype]]:
        if not self._data.isa[_MultiValue]():
            raise Error("vector is not a multivector")
        return self._data[_MultiValue].values.values[dtype]()

    def binary_values(
        self,
    ) raises -> ref[origin_of(self._data[_BinaryValue].values, self)] List[
        UInt8
    ]:
        if not self._data.isa[_BinaryValue]():
            raise Error("vector is not binary")
        return self._data[_BinaryValue].values


def _validate_dimension(dimension: Int) raises:
    if dimension <= 0 or dimension > Int(UInt32.MAX):
        raise Error("vector dimension must be positive and fit UInt32")
