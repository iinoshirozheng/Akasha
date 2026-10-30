"""Recursive typed payload export following Arrow/Lance array and null rules.

Cells address immutable native payload nodes, never Python row values. Owned
Arrow buffers use the same recursive C Data release implementation as vectors.
"""

from akasha.api.scanner import ScanBatch
from akasha.document.jsonb_writer import format_jsonb
from akasha.query.control import QueryControl
from bindings.arrow_payload import ArrowPayloadSchema
from bindings.arrow_buffers import ArrowArrayExport, _ArrayData, _BufferBudget, _store, _set_bit, _checked_bytes
from std.math import isfinite
from std.sys.info import size_of


@no_inline
def _rounded_f32(value: Float64) -> Float32:
    # Preserve Arrow/half's intermediate rounding across the compiler boundary.
    return Float32(value)


@fieldwise_init
struct _Cell(Copyable, Movable):
    var row: Int
    var slot: Int
    var node: Int
    var masked: Bool

    def kind(self, batch: ScanBatch) raises -> UInt8:
        if self.slot < 0:
            return 5
        ref value = batch.entry(self.row).fields()[self.slot].value
        return value.kind() if self.node < 0 else value._nodes[self.node].kind


struct _TraversalBudget:
    var remaining: Int

    def __init__(out self, max_bytes: Int):
        # Output byte accounting remains unchanged. A separate finite work cap
        # also bounds null-only nested projections that allocate no value bytes.
        self.remaining = max(1024, max_bytes // size_of[_Cell]())

    def reserve(mut self, count: Int) raises:
        if count < 0 or count > self.remaining:
            raise Error("scanner payload traversal resource limit exceeded")
        self.remaining -= count


def _key(batch: ScanBatch, cell: _Cell, name: String, control: QueryControl) raises -> _Cell:
    if cell.kind(batch) == 5:
        return _Cell(cell.row, -1, -1, True)
    ref value = batch.entry(cell.row).fields()[cell.slot].value
    var parent = max(0, cell.node)
    var i = parent + 1
    while i < value._nodes[parent].end:
        control.checkpoint(i)
        if value._nodes[i].key == name:
            return _Cell(cell.row, cell.slot, i, False)
        i = value._nodes[i].end
    return _Cell(cell.row, -1, -1, False)


def _list_length(batch: ScanBatch, cell: _Cell, control: QueryControl) raises -> Int:
    if cell.kind(batch) == 5:
        return 0
    ref value = batch.entry(cell.row).fields()[cell.slot].value
    var parent = max(0, cell.node)
    var i = parent + 1
    var count = 0
    while i < value._nodes[parent].end:
        control.checkpoint(count)
        count += 1
        i = value._nodes[i].end
    return count


def _string_length(batch: ScanBatch, cell: _Cell) raises -> Int:
    ref value = batch.entry(cell.row).fields()[cell.slot].value
    return value._string_value.byte_length() if cell.node < 0 else value._nodes[cell.node].text.byte_length()


def _copy_string(text: String, address: Int, begin: Int, control: QueryControl) raises -> Int:
    var position = begin
    for byte in text.bytes():
        control.checkpoint(position)
        _store(address, position, byte)
        position += 1
    return position


def _write_string(batch: ScanBatch, cell: _Cell, address: Int, begin: Int, control: QueryControl) raises -> Int:
    ref value = batch.entry(cell.row).fields()[cell.slot].value
    if cell.node < 0:
        return _copy_string(value._string_value, address, begin, control)
    return _copy_string(value._nodes[cell.node].text, address, begin, control)


def _json_text(batch: ScanBatch, cell: _Cell, limit: Int, control: QueryControl) raises -> String:
    ref value = batch.entry(cell.row).fields()[cell.slot].value
    if cell.node < 0:
        return format_jsonb(value._jsonb_value.value(), max_bytes=limit, control=control.copy())
    return format_jsonb(value._nodes[cell.node].jsonb.value(), max_bytes=limit, control=control.copy())


def _byte_length(batch: ScanBatch, cell: _Cell, extension: Int, texts: List[String], row: Int) raises -> Int:
    if extension == 1:
        return texts[row].byte_length()
    if extension == 2:
        ref value = batch.entry(cell.row).fields()[cell.slot].value
        if cell.node < 0:
            return len(value._jsonb_value.value()._data)
        return len(value._nodes[cell.node].jsonb.value()._data)
    return _string_length(batch, cell)


def _copy_bytes(bytes: Span[UInt8, _], address: Int, begin: Int, control: QueryControl) raises -> Int:
    for i in range(len(bytes)):
        control.checkpoint(i)
        _store(address, begin + i, bytes[i])
    return begin + len(bytes)


def _write_bytes(batch: ScanBatch, cell: _Cell, extension: Int, texts: List[String], row: Int, address: Int, begin: Int, control: QueryControl) raises -> Int:
    if extension == 1:
        return _copy_string(texts[row], address, begin, control)
    if extension == 2:
        ref value = batch.entry(cell.row).fields()[cell.slot].value
        if cell.node < 0:
            return _copy_bytes(Span(value._jsonb_value.value()._data), address, begin, control)
        return _copy_bytes(Span(value._nodes[cell.node].jsonb.value()._data), address, begin, control)
    return _write_string(batch, cell, address, begin, control)


def _numbers[dtype: DType](batch: ScanBatch, cells: List[_Cell], address: Int, control: QueryControl) raises:
    for row in range(len(cells)):
        control.checkpoint(row)
        ref cell = cells[row]
        if cell.kind(batch) == 5:
            continue
        ref value = batch.entry(cell.row).fields()[cell.slot].value
        comptime if dtype.is_floating_point():
            var source = value._float_value if cell.node < 0 else value._nodes[cell.node].floating
            var narrowed: Scalar[dtype]
            comptime if dtype == DType.float16:
                # Arrow num_cast -> half 2.7.1 NumCast::from first calls
                # ToPrimitive::to_f32, then f16::from_f32. Keep both roundings.
                narrowed = Scalar[dtype](_rounded_f32(source))
            else:
                narrowed = Scalar[dtype](source)
            if not isfinite(narrowed):
                raise Error("scanner floating payload overflows requested Arrow type")
            _store(address, row, narrowed)
        elif dtype.is_signed():
            var source = value._int_value if cell.node < 0 else value._nodes[cell.node].integer
            if source < Int64(Scalar[dtype].MIN) or source > Int64(Scalar[dtype].MAX):
                raise Error("scanner integer payload overflows requested Arrow type")
            _store(address, row, Scalar[dtype](source))
        else:
            var source = value._uint_value if cell.node < 0 else value._nodes[cell.node].unsigned
            if source > UInt64(Scalar[dtype].MAX):
                raise Error("scanner unsigned payload overflows requested Arrow type")
            _store(address, row, Scalar[dtype](source))


def _numeric_buffer(batch: ScanBatch, cells: List[_Cell], kind: Int, bits: Int, address: Int, control: QueryControl) raises:
    if kind == 2:
        if bits == 8:
            _numbers[DType.int8](batch, cells, address, control)
        elif bits == 16:
            _numbers[DType.int16](batch, cells, address, control)
        elif bits == 32:
            _numbers[DType.int32](batch, cells, address, control)
        else:
            _numbers[DType.int64](batch, cells, address, control)
    elif kind == 3:
        if bits == 8:
            _numbers[DType.uint8](batch, cells, address, control)
        elif bits == 16:
            _numbers[DType.uint16](batch, cells, address, control)
        elif bits == 32:
            _numbers[DType.uint32](batch, cells, address, control)
        else:
            _numbers[DType.uint64](batch, cells, address, control)
    elif bits == 16:
        _numbers[DType.float16](batch, cells, address, control)
    elif bits == 32:
        _numbers[DType.float32](batch, cells, address, control)
    else:
        _numbers[DType.float64](batch, cells, address, control)


def _offset(address: Int, row: Int, value: Int, wide: Bool) raises:
    if not wide and value > Int(Int32.MAX):
        raise Error("scanner payload Arrow offsets overflow")
    if wide:
        _store(address, row, Int64(value))
    else:
        _store(address, row, Int32(value))


def _export(
    batch: ScanBatch, schema: ArrowPayloadSchema, index: Int, cells: List[_Cell],
    mut budget: _BufferBudget, mut traversal: _TraversalBudget, control: QueryControl,
) raises -> ArrowArrayExport:
    control.checkpoint(0)
    ref spec = schema.nodes[index]
    var rows = len(cells)
    var nulls = 0
    var expected: UInt8 = 5
    if spec.kind == 1:
        expected = 4
    elif spec.kind == 2:
        expected = 2
    elif spec.kind == 3:
        expected = 8
    elif spec.kind == 4:
        expected = 3
    elif spec.kind == 5 or spec.kind == 6 or spec.kind == 11:
        expected = 1
    elif spec.kind == 7:
        expected = 7
    elif spec.kind >= 8:
        expected = 6
    if spec.extension != 0:
        expected = 9
    for row in range(rows):
        control.checkpoint(row)
        var kind = cells[row].kind(batch)
        if kind == 5:
            if not spec.nullable and not cells[row].masked:
                raise Error("scanner required payload field is missing or null")
            nulls += 1
        elif kind != expected:
            raise Error("scanner payload type mismatch: " + spec.name)
    var data = _ArrayData()
    var children = List[ArrowArrayExport]()
    if spec.kind == 0:
        return ArrowArrayExport(rows, nulls, data^, children^)
    var validity = data.allocate((rows + 7) // 8, budget) if nulls else 0
    data.buffers.append(Int64(validity))
    if validity:
        for row in range(rows):
            control.checkpoint(row)
            if cells[row].kind(batch) != 5:
                _set_bit(validity, row)
    # Render each JSON cell once, with a shared finite expansion budget. View
    # inline text is bounded by its 16-byte descriptor; external text consumes
    # the same budget as the eventual Arrow backing buffer.
    var texts = List[String]()
    if spec.extension == 1:
        var remaining = budget.limit - budget.used
        for row in range(rows):
            control.checkpoint(row)
            var text = String()
            if cells[row].kind(batch) != 5:
                text = _json_text(batch, cells[row], max(12, remaining) if spec.kind == 11 else remaining, control)
                if spec.kind != 11 or text.byte_length() > 12:
                    remaining -= text.byte_length()
            texts.append(text^)
    if spec.kind == 1:
        var address = data.allocate((rows + 7) // 8, budget)
        data.buffers.append(Int64(address))
        for row in range(rows):
            control.checkpoint(row)
            ref cell = cells[row]
            if cell.kind(batch) != 5:
                ref value = batch.entry(cell.row).fields()[cell.slot].value
                if value._bool_value if cell.node < 0 else value._nodes[cell.node].boolean:
                    _set_bit(address, row)
    elif spec.kind <= 4:
        var address = data.allocate(_checked_bytes(rows, spec.bits // 8), budget)
        data.buffers.append(Int64(address))
        _numeric_buffer(batch, cells, spec.kind, spec.bits, address, control)
    elif spec.kind == 5 or spec.kind == 6 or spec.kind == 12:
        var wide = spec.kind != 5
        var count = 0
        for row in range(rows):
            control.checkpoint(row)
            if cells[row].kind(batch) != 5:
                var length = _byte_length(batch, cells[row], spec.extension, texts, row)
                if length > Int.MAX - count or (not wide and length > Int(Int32.MAX) - count):
                    raise Error("scanner string offsets overflow")
                count += length
        var offsets = data.allocate(_checked_bytes(rows + 1, 8 if wide else 4), budget)
        var values = data.allocate(count, budget)
        data.buffers.append(Int64(offsets))
        data.buffers.append(Int64(values))
        var position = 0
        for row in range(rows):
            control.checkpoint(row)
            if cells[row].kind(batch) != 5:
                position = _write_bytes(batch, cells[row], spec.extension, texts, row, values, position, control)
            _offset(offsets, row + 1, position, wide)
    elif spec.kind == 11:
        # Arrow byte_view.rs layout and ffi.rs variadic buffer-size trailer.
        var count = 0
        for row in range(rows):
            control.checkpoint(row)
            if cells[row].kind(batch) != 5:
                var length = _byte_length(batch, cells[row], spec.extension, texts, row)
                if length > Int(UInt32.MAX):
                    raise Error("scanner StringView length overflows")
                if length > 12:
                    if length > Int(UInt32.MAX) - count:
                        raise Error("scanner StringView backing buffer overflows")
                    count += length
        var views = data.allocate(_checked_bytes(rows, 16), budget)
        data.buffers.append(Int64(views))
        var values = 0
        var sizes = 0
        if count:
            values = data.allocate(count, budget)
            sizes = data.allocate(8, budget)
            _store(sizes, 0, Int64(count))
            data.buffers.append(Int64(values))
        data.buffers.append(Int64(sizes))
        var position = 0
        for row in range(rows):
            control.checkpoint(row)
            ref cell = cells[row]
            if cell.kind(batch) == 5:
                continue
            var length = _byte_length(batch, cell, spec.extension, texts, row)
            _store(views, row * 4, UInt32(length))
            if length <= 12:
                _ = _write_bytes(batch, cell, spec.extension, texts, row, views, row * 16 + 4, control)
            else:
                _store(views, row * 4 + 3, UInt32(position))
                var begin = position
                position = _write_bytes(batch, cell, spec.extension, texts, row, values, position, control)
                var source = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=values)
                for i in range(4):
                    _store(views, row * 16 + 4 + i, source[unsafe_offset=begin + i])
    elif spec.kind == 7:
        for child in spec.children:
            control.checkpoint(0)
            traversal.reserve(rows)
            var selected = List[_Cell](capacity=rows)
            for row in range(rows):
                control.checkpoint(row)
                selected.append(_key(batch, cells[row], schema.nodes[child].name, control))
            children.append(_export(batch, schema, child, selected, budget, traversal, control))
    else:
        var count = 0
        var lengths = List[Int](capacity=rows)
        for row in range(rows):
            control.checkpoint(row)
            var length = _list_length(batch, cells[row], control)
            if spec.kind == 10:
                if cells[row].kind(batch) != 5 and length != spec.size:
                    raise Error("scanner fixed-size payload list length mismatch")
                length = spec.size
            if length > Int.MAX - count or ((spec.kind == 8 or spec.kind == 13) and length > Int(Int32.MAX) - count):
                raise Error("scanner payload list offsets overflow")
            count += length
            lengths.append(length)
        traversal.reserve(count)
        var selected = List[_Cell](capacity=count)
        var offsets = 0
        if spec.kind != 10:
            offsets = data.allocate(_checked_bytes(rows + 1, 8 if spec.kind == 9 else 4), budget)
            data.buffers.append(Int64(offsets))
        for row in range(rows):
            control.checkpoint(row)
            ref cell = cells[row]
            if cell.kind(batch) == 5:
                for element in range(lengths[row]):
                    control.checkpoint(element)
                    selected.append(_Cell(cell.row, -1, -1, True))
            else:
                ref value = batch.entry(cell.row).fields()[cell.slot].value
                var parent = max(0, cell.node)
                var i = parent + 1
                while i < value._nodes[parent].end:
                    control.checkpoint(i)
                    selected.append(_Cell(cell.row, cell.slot, i, False))
                    i = value._nodes[i].end
            if offsets:
                _offset(offsets, row + 1, len(selected), spec.kind == 9)
        children.append(_export(batch, schema, spec.children[0], selected, budget, traversal, control))
    control.checkpoint(0)
    return ArrowArrayExport(rows, nulls, data^, children^)


def export_payload_column(
    batch: ScanBatch, name: String, schema: ArrowPayloadSchema,
    mut budget: _BufferBudget, control: QueryControl,
) raises -> ArrowArrayExport:
    var traversal = _TraversalBudget(budget.limit)
    traversal.reserve(batch.row_count())
    var cells = List[_Cell](capacity=batch.row_count())
    for row in range(batch.row_count()):
        control.checkpoint(row)
        ref fields = batch.entry(row).fields()
        var slot = -1
        for i in range(len(fields)):
            if fields[i].name == name:
                slot = i
                break
        cells.append(_Cell(row, slot, -1, False))
    return _export(batch, schema, 0, cells, budget, traversal, control)
