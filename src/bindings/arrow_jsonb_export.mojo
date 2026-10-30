"""Source Lance JSON outputs as owned native Arrow C Data columns."""
from akasha.api.scanner import ScanBatch
from akasha.document.lance_json_result import LanceJsonResult
from akasha.query.jsonb_projection import JsonbProjection
from akasha.query.control import QueryControl
from bindings.arrow_buffers import ArrowArrayExport, _ArrayData, _BufferBudget, _store, _set_bit, _checked_bytes
from bindings.arrow_payload_export import _copy_string, _copy_bytes
from std.python import Python, PythonObject
from std.sys.info import size_of


def jsonb_projection_type(operation: Int) raises -> PythonObject:
    var pa = Python.import_module("pyarrow")
    if operation == 0 or operation == 1 or operation == 5:
        return pa.string()
    if operation == 2:
        return pa.struct(Python.list(pa.field("value", pa.large_binary()), pa.field("type_tag", pa.uint8(), nullable=False)))
    if operation == 4:
        return pa.large_binary()
    if operation == 6 or operation == 10:
        return pa.int64()
    if operation == 7:
        return pa.float64()
    return pa.bool_()


def _export_results(values: List[LanceJsonResult], operation: Int,
                    mut budget: _BufferBudget, control: QueryControl) raises -> ArrowArrayExport:
    var rows = len(values)
    var data = _ArrayData()
    var children = List[ArrowArrayExport]()
    if operation == 2:
        # Source typed extraction is a non-null struct, including missing/null
        # inputs. Its value child is nullable; its UInt8 tag child never is.
        data.buffers.append(0)
        children.append(_export_results(values, 4, budget, control))
        var tags = _ArrayData()
        tags.buffers.append(0)
        var address = tags.allocate(rows, budget)
        tags.buffers.append(Int64(address))
        for row in range(rows):
            control.checkpoint(row)
            _store(address, row, values[row].type_tag)
        children.append(ArrowArrayExport(rows, 0, tags^, []))
        return ArrowArrayExport(rows, 0, data^, children^)
    var nulls = 0
    for row in range(rows):
        control.checkpoint(row)
        if not values[row].valid(operation):
            nulls += 1
    var validity = 0
    if nulls:
        validity = data.allocate((rows + 7) // 8, budget)
        for row in range(rows):
            control.checkpoint(row)
            if values[row].valid(operation):
                _set_bit(validity, row)
    data.buffers.append(Int64(validity))
    if operation == 0 or operation == 1 or operation == 4 or operation == 5:
        var bytes = 0
        for row in range(rows):
            var size = values[row].owned_bytes()
            if size > budget.limit - bytes:
                raise Error("scanner JSONB output byte resource limit exceeded")
            bytes += size
        if operation != 4 and bytes > Int(Int32.MAX):
            raise Error("scanner JSONB UTF8 offsets overflow")
        var offsets = data.allocate(_checked_bytes(rows + 1, 8 if operation == 4 else 4), budget)
        var address = data.allocate(bytes, budget)
        data.buffers.append(Int64(offsets))
        data.buffers.append(Int64(address))
        var position = 0
        for row in range(rows):
            control.checkpoint(row)
            if operation == 4:
                if values[row].binary:
                    position = _copy_bytes(Span(values[row].binary.value()._data), address, position, control)
                _store(offsets, row + 1, Int64(position))
            else:
                if values[row].text:
                    position = _copy_string(values[row].text.value(), address, position, control)
                _store(offsets, row + 1, Int32(position))
    elif operation == 3 or operation == 8 or operation == 9:
        var address = data.allocate((rows + 7) // 8, budget)
        data.buffers.append(Int64(address))
        for row in range(rows):
            control.checkpoint(row)
            if values[row].boolean and values[row].boolean.value():
                _set_bit(address, row)
    else:
        var address = data.allocate(_checked_bytes(rows, 8), budget)
        data.buffers.append(Int64(address))
        for row in range(rows):
            control.checkpoint(row)
            if operation == 7:
                if values[row].floating:
                    _store(address, row, values[row].floating.value())
            elif values[row].integer:
                _store(address, row, values[row].integer.value())
    return ArrowArrayExport(rows, nulls, data^, children^)


def export_jsonb_column(batch: ScanBatch, expression: JsonbProjection,
                       mut budget: _BufferBudget, control: QueryControl) raises -> ArrowArrayExport:
    var rows = batch.row_count()
    var staging = _checked_bytes(rows, size_of[LanceJsonResult]())
    if staging > budget.limit:
        raise Error("scanner JSONB intermediate resource limit exceeded")
    var results = List[LanceJsonResult](capacity=rows)
    for row in range(rows):
        control.checkpoint(row)
        var value = expression.evaluate(batch.entry(row).fields(), Optional(control.copy()))
        var size = value.owned_bytes()
        if size > budget.limit - staging:
            raise Error("scanner JSONB intermediate resource limit exceeded")
        staging += size
        results.append(value^)
    return _export_results(results, expression.operation(), budget, control)
