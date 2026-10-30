"""Arrow C Data buffer ownership for the bounded document scanner.

Column dispatch and vector materialization share the stable C ABI ownership
implementation in arrow_buffers. No raw address crosses the public API.
"""

from akasha.api.scanner import ScanBatch
from akasha.query.jsonb_projection import JsonbProjection
from bindings.arrow_jsonb_export import export_jsonb_column, jsonb_projection_type
from akasha.document.record import validate_field_name
from akasha.document.vector_schema import VectorFieldSpec
from akasha.query.control import QueryControl
from std.python import Python, PythonObject
from std.sys.info import size_of
from bindings.arrow_payload import ArrowPayloadSchema, payload_arrow_type
from bindings.arrow_payload_export import export_payload_column
from bindings.arrow_buffers import ArrowArrayExport, _ArrayData, _BufferBudget, _store, _set_bit, _checked_bytes


struct ArrowColumn(Copyable, Movable):
    var name: String
    # 1=id, 2=sequence, 3=legacy vector, 4=terms, 5=weights;
    # 10=typed vector, 11=document sequence, 12=typed payload, 13=JSONB expression.
    var kind: Int
    var payload_name: String
    var field: Optional[VectorFieldSpec]
    var payload: Optional[ArrowPayloadSchema]
    var jsonb: Optional[JsonbProjection]

    def __init__(
        out self,
        var name: String,
        kind: Int,
        var payload_name: String = String(),
        var field: Optional[VectorFieldSpec] = None,
        var payload: Optional[ArrowPayloadSchema] = None,
        var jsonb: Optional[JsonbProjection] = None,
    ) raises:
        if kind < 1 or kind > 13 or (kind >= 6 and kind <= 9):
            raise Error("unknown scanner column type")
        if Bool(jsonb) != (kind == 13):
            raise Error("JSONB scanner column requires an expression")
        if kind == 13:
            validate_field_name(name)
        if kind == 12:
            validate_field_name(payload_name)
            if not payload:
                raise Error("typed payload column requires a schema")
        elif payload:
            raise Error("unexpected scanner payload schema")
        if kind == 10:
            if not field:
                raise Error("typed scanner column requires a vector schema")
            field.value().validate()
        self.name = name^
        self.kind = kind
        self.payload_name = payload_name^
        self.field = field^
        self.payload = payload^
        self.jsonb = jsonb^


def scanner_schema(
    columns: List[ArrowColumn], dimension: Int
) raises -> PythonObject:
    var pa = Python.import_module("pyarrow")
    var fields = Python.list()
    for column in columns:
        var dtype = pa.int64()
        if column.kind == 2 or column.kind == 11:
            dtype = pa.uint64()
        elif column.kind == 3:
            dtype = pa.list_(pa.float32(), dimension)
        elif column.kind == 4:
            dtype = pa.list_(pa.int64())
        elif column.kind == 5:
            dtype = pa.list_(pa.float32())
        if column.kind == 13:
            var op = column.jsonb.value().operation()
            fields.append(pa.field(PythonObject(column.name), jsonb_projection_type(op), nullable=op != 2))
            continue
        if column.kind == 12:
            ref payload = column.payload.value()
            fields.append(pa.field(PythonObject(column.name), payload_arrow_type(payload),
                                   nullable=payload.nodes[0].nullable, metadata=payload.nodes[0].metadata))
            continue
        if column.kind == 10:
            ref field = column.field.value()
            dtype = vector_arrow_type(field)
            var metadata = Python.dict()
            metadata["akashadb.dtype"] = _arrow_scalar_name(field.scalar)
            fields.append(
                pa.field(
                    PythonObject(column.name),
                    dtype,
                    nullable=True,
                    metadata=metadata,
                )
            )
            continue
        fields.append(
            pa.field(
                PythonObject(column.name),
                dtype,
                nullable=column.kind == 4 or column.kind == 5,
            )
        )
    return pa.schema(fields)


def export_scan_batch(
    batch: ScanBatch,
    columns: List[ArrowColumn],
    max_bytes: Int,
    control: QueryControl,
) raises -> ArrowArrayExport:
    control.checkpoint(0)
    var budget = _BufferBudget(max_bytes)
    var children = List[ArrowArrayExport](capacity=len(columns))
    for column in columns:
        control.checkpoint(0)
        children.append(_export_column(batch, column, budget, control))
    var parent = _ArrayData()
    parent.buffers.append(0)
    control.checkpoint(0)
    return ArrowArrayExport(batch.row_count(), 0, parent^, children^)


def _export_column(
    batch: ScanBatch,
    column: ArrowColumn,
    mut budget: _BufferBudget,
    control: QueryControl,
) raises -> ArrowArrayExport:
    if column.kind == 13:
        return export_jsonb_column(batch, column.jsonb.value(), budget, control)
    if column.kind == 12:
        return export_payload_column(batch, column.payload_name, column.payload.value(), budget, control)
    if column.kind == 10:
        return _export_vector_column(
            batch, column.field.value(), budget, control
        )
    var rows = batch.row_count()
    var data = _ArrayData()
    var children = List[ArrowArrayExport]()
    var nulls = 0
    data.buffers.append(0)
    if column.kind == 1 or column.kind == 2 or column.kind == 11:
        var values = data.allocate(_checked_bytes(rows, 8), budget)
        data.buffers.append(Int64(values))
        for row in range(rows):
            control.checkpoint(row)
            if column.kind == 1:
                _store(values, row, Int64(batch.entry(row).id))
            elif column.kind == 2:
                _store(values, row, batch.entry(row).sequence)
            else:
                _store(values, row, batch.entry(row).document_sequence)
    elif column.kind == 3:
        # This legacy column has a non-nullable fixed-size F32 schema. Never
        # export a missing field's empty allocation as dimension-sized memory.
        for row in range(rows):
            if not batch.entry(row).has_dense():
                raise Error(
                    "legacy vector column requires a present default vector"
                )
        var dimension = batch.root[].config.dimension
        var value_count = _checked_bytes(rows, dimension)
        var values_data = _ArrayData()
        values_data.buffers.append(0)
        if rows == 1:
            values_data.root = Optional(batch.root.copy())
            values_data.borrowed_bytes = _checked_bytes(dimension, 4)
            values_data.buffers.append(
                Int64(Int(Span(batch.entry(0).values()).unsafe_ptr()))
            )
        else:
            var values = values_data.allocate(
                _checked_bytes(value_count, 4), budget
            )
            values_data.buffers.append(Int64(values))
            for row in range(rows):
                ref source = batch.entry(row).values()
                for coordinate in range(dimension):
                    control.checkpoint(coordinate)
                    _store(
                        values, row * dimension + coordinate, source[coordinate]
                    )
        children.append(
            ArrowArrayExport(
                value_count, 0, values_data^, List[ArrowArrayExport]()
            )
        )
    elif column.kind == 4 or column.kind == 5:
        var count = 0
        for row in range(rows):
            control.checkpoint(row)
            ref entry = batch.entry(row)
            if entry.has_sparse():
                var length = len(entry.sparse())
                if length > Int(Int32.MAX) - count:
                    raise Error("scanner sparse offsets overflow")
                count += length
            else:
                nulls += 1
        var validity = 0
        if nulls:
            validity = data.allocate((rows + 7) // 8, budget)
            data.buffers[0] = Int64(validity)
        var offsets = data.allocate(_checked_bytes(rows + 1, 4), budget)
        data.buffers.append(Int64(offsets))
        var values_data = _ArrayData()
        values_data.buffers.append(0)
        var values = values_data.allocate(
            _checked_bytes(count, 8 if column.kind == 4 else 4), budget
        )
        values_data.buffers.append(Int64(values))
        var position = 0
        for row in range(rows):
            control.checkpoint(row)
            ref entry = batch.entry(row)
            if entry.has_sparse():
                if validity:
                    _set_bit(validity, row)
                for element in entry.sparse():
                    control.checkpoint(position)
                    if column.kind == 4:
                        _store(values, position, Int64(element.term_id))
                    else:
                        _store(values, position, element.weight)
                    position += 1
            _store(offsets, row + 1, Int32(position))
        children.append(
            ArrowArrayExport(count, 0, values_data^, List[ArrowArrayExport]())
        )
    return ArrowArrayExport(rows, nulls, data^, children^)


def _arrow_scalar_name(scalar: UInt8) -> String:
    var names: List[String] = ["f32", "bf16", "f16", "i8", "u8", "binary"]
    return names[Int(scalar)].copy()


def vector_arrow_type(field: VectorFieldSpec) raises -> PythonObject:
    var pa = Python.import_module("pyarrow")
    if field.kind == 1:
        var members = Python.list()
        members.append(pa.field("term_id", pa.int64(), nullable=False))
        members.append(pa.field("weight", pa.float32(), nullable=False))
        return pa.list_(pa.struct(members))
    if field.kind == 3:
        return pa.binary((field.dimension + 7) // 8)
    var scalar = pa.float32()
    if field.scalar == 1:
        # Arrow 21 has no BF16 primitive. The field metadata declares these
        # UInt16 values as BF16 bits; no numerical conversion occurs.
        scalar = pa.uint16()
    elif field.scalar == 2:
        scalar = pa.float16()
    elif field.scalar == 3:
        scalar = pa.int8()
    elif field.scalar == 4:
        scalar = pa.uint8()
    var vector = pa.list_(scalar, field.dimension)
    return pa.list_(vector) if field.kind == 2 else vector


def _typed_values[
    dtype: DType
](
    batch: ScanBatch,
    field: VectorFieldSpec,
    slots: List[Int],
    count: Int,
    mut budget: _BufferBudget,
    control: QueryControl,
) raises -> ArrowArrayExport:
    var data = _ArrayData()
    data.buffers.append(0)
    var byte_count = _checked_bytes(count, size_of[Scalar[dtype]]())
    if batch.row_count() == 1 and slots[0] >= 0:
        ref value = batch.entry(0).vector_at(slots[0]).value()
        var address: Int
        if field.kind == 0:
            address = Int(Span(value.dense_values[dtype]()).unsafe_ptr())
        else:
            address = Int(Span(value.multivector_values[dtype]()).unsafe_ptr())
        data.root = Optional(batch.root.copy())
        data.borrowed_bytes = byte_count
        data.buffers.append(Int64(address))
    else:
        var values = data.allocate(byte_count, budget)
        data.buffers.append(Int64(values))
        var position = 0
        for row in range(batch.row_count()):
            control.checkpoint(row)
            if slots[row] >= 0:
                ref value = batch.entry(row).vector_at(slots[row]).value()
                if field.kind == 0:
                    for component in value.dense_values[dtype]():
                        control.checkpoint(position)
                        _store(values, position, component)
                        position += 1
                else:
                    for component in value.multivector_values[dtype]():
                        control.checkpoint(position)
                        _store(values, position, component)
                        position += 1
            elif field.kind == 0:
                position += field.dimension
    return ArrowArrayExport(count, 0, data^, List[ArrowArrayExport]())


def _numeric_child(
    batch: ScanBatch,
    field: VectorFieldSpec,
    slots: List[Int],
    count: Int,
    mut budget: _BufferBudget,
    control: QueryControl,
) raises -> ArrowArrayExport:
    if field.scalar == 0:
        return _typed_values[DType.float32](
            batch, field, slots, count, budget, control
        )
    if field.scalar == 1:
        return _typed_values[DType.bfloat16](
            batch, field, slots, count, budget, control
        )
    if field.scalar == 2:
        return _typed_values[DType.float16](
            batch, field, slots, count, budget, control
        )
    if field.scalar == 3:
        return _typed_values[DType.int8](
            batch, field, slots, count, budget, control
        )
    return _typed_values[DType.uint8](
        batch, field, slots, count, budget, control
    )


def _export_vector_column(
    batch: ScanBatch,
    field: VectorFieldSpec,
    mut budget: _BufferBudget,
    control: QueryControl,
) raises -> ArrowArrayExport:
    var rows = batch.row_count()
    var slots = List[Int](capacity=rows)
    var nulls = 0
    var count = 0
    for row in range(rows):
        control.checkpoint(row)
        var slot = batch.entry(row).field_ordinal(field.id)
        slots.append(slot)
        if slot < 0:
            nulls += 1
        else:
            ref value = batch.entry(row).vector_at(slot).value()
            if (
                value.kind() != field.kind
                or value.scalar() != field.scalar
                or value.dimension() != field.dimension
            ):
                raise Error(
                    "scanner vector schema does not match source buffer"
                )
            if field.kind == 1 or field.kind == 2:
                var length = (
                    len(value.sparse_values()) if field.kind
                    == 1 else value.row_count()
                )
                if length > Int(Int32.MAX) - count:
                    raise Error("scanner vector offsets overflow")
                count += length
    var data = _ArrayData()
    var validity = 0
    if nulls:
        validity = data.allocate((rows + 7) // 8, budget)
        for row in range(rows):
            if slots[row] >= 0:
                _set_bit(validity, row)
    data.buffers.append(Int64(validity))
    var children = List[ArrowArrayExport]()
    if field.kind == 3:
        var width = (field.dimension + 7) // 8
        if rows == 1 and slots[0] >= 0:
            data.root = Optional(batch.root.copy())
            data.borrowed_bytes = width
            data.buffers.append(
                Int64(
                    Int(
                        Span(
                            batch.entry(0)
                            .vector_at(slots[0])
                            .value()
                            .binary_values()
                        ).unsafe_ptr()
                    )
                )
            )
        else:
            var values = data.allocate(_checked_bytes(rows, width), budget)
            data.buffers.append(Int64(values))
            for row in range(rows):
                control.checkpoint(row)
                if slots[row] >= 0:
                    ref source = (
                        batch.entry(row)
                        .vector_at(slots[row])
                        .value()
                        .binary_values()
                    )
                    for index in range(width):
                        control.checkpoint(index)
                        _store(values, row * width + index, source[index])
    elif field.kind == 0:
        children.append(
            _numeric_child(
                batch,
                field,
                slots,
                _checked_bytes(rows, field.dimension),
                budget,
                control,
            )
        )
    else:
        var offsets = data.allocate(_checked_bytes(rows + 1, 4), budget)
        data.buffers.append(Int64(offsets))
        var position = 0
        for row in range(rows):
            control.checkpoint(row)
            if slots[row] >= 0:
                ref value = batch.entry(row).vector_at(slots[row]).value()
                position += (
                    len(value.sparse_values()) if field.kind
                    == 1 else value.row_count()
                )
            _store(offsets, row + 1, Int32(position))
        var nested = _ArrayData()
        nested.buffers.append(0)
        var nested_children = List[ArrowArrayExport]()
        if field.kind == 2:
            nested_children.append(
                _numeric_child(
                    batch,
                    field,
                    slots,
                    _checked_bytes(count, field.dimension),
                    budget,
                    control,
                )
            )
        else:
            var terms = _ArrayData()
            var weights = _ArrayData()
            terms.buffers.append(0)
            weights.buffers.append(0)
            var term_values = terms.allocate(_checked_bytes(count, 8), budget)
            var weight_values = weights.allocate(
                _checked_bytes(count, 4), budget
            )
            terms.buffers.append(Int64(term_values))
            weights.buffers.append(Int64(weight_values))
            position = 0
            for row in range(rows):
                control.checkpoint(row)
                if slots[row] >= 0:
                    for element in (
                        batch.entry(row)
                        .vector_at(slots[row])
                        .value()
                        .sparse_values()
                    ):
                        control.checkpoint(position)
                        _store(term_values, position, Int64(element.term_id))
                        _store(weight_values, position, element.weight)
                        position += 1
            nested_children.append(
                ArrowArrayExport(count, 0, terms^, List[ArrowArrayExport]())
            )
            nested_children.append(
                ArrowArrayExport(count, 0, weights^, List[ArrowArrayExport]())
            )
        children.append(ArrowArrayExport(count, 0, nested^, nested_children^))
    return ArrowArrayExport(rows, nulls, data^, children^)


def import_scan_batch(
    batch: ScanBatch,
    columns: List[ArrowColumn],
    schema: PythonObject,
    max_bytes: Int,
    control: QueryControl,
) raises -> PythonObject:
    var exported = export_scan_batch(batch, columns, max_bytes, control)
    var pa = Python.import_module("pyarrow")
    var result = pa.RecordBatch._import_from_c(exported.address(), schema)
    return Python.dict(
        batch=result,
        materialized_bytes=PythonObject(exported.materialized_bytes),
        borrowed_bytes=PythonObject(exported.borrowed_bytes),
    )
