"""Typed Arrow payload traversal adapted from Arrow 58.4 / pinned Lance.

See docs/plans/2026-10-30-rich-arrow-source-port.md. Python supplies only type
descriptors and borrowed buffers. Native code validates the schema, bounds and
active values before the entire point batch is published. Parent nulls mask
children, including arbitrary bytes in their physical storage.
"""

from akasha.document.value import PayloadValue
from akasha.document.record import DocumentField, validate_field_name
from bindings.point_arrow import _valid_bit
from std.python import Python, PythonObject
from std.python.numpy import from_numpy_array


@fieldwise_init
struct ArrowPayloadNode(Copyable, Movable):
    # null, bool, signed, unsigned, floating, utf8, large_utf8, struct,
    # list, large_list, fixed_size_list.
    var kind: Int
    var bits: Int
    var size: Int
    var name: String
    var nullable: Bool
    var children: List[Int]
    var metadata: PythonObject


struct ArrowPayloadSchema(Copyable, Movable):
    var nodes: List[ArrowPayloadNode]
    var name_bytes: Int

    def __init__(out self, raw: PythonObject) raises:
        self.nodes = List[ArrowPayloadNode]()
        self.name_bytes = 0
        _ = self._append(raw, 0)

    def _append(mut self, raw: PythonObject, depth: Int) raises -> Int:
        if depth > PayloadValue.MAX_DEPTH or len(self.nodes) >= PayloadValue.MAX_NODES:
            raise Error("Arrow payload schema depth or node limit exceeded")
        var kind = Int(py=raw["kind"])
        var bits = Int(py=raw["bits"])
        var size = Int(py=raw["size"])
        var name = String(py=raw["name"])
        if name.byte_length() > PayloadValue.MAX_BYTES - self.name_bytes:
            raise Error("Arrow payload field name exceeds byte limit")
        self.name_bytes += name.byte_length()
        for byte in name.bytes():
            if byte == 0:
                raise Error("Arrow C Data field names cannot contain NUL")
        var raw_children = raw["children"]
        var count = len(raw_children)
        if kind < 0 or kind > 10 or count > PayloadValue.MAX_NODES:
            raise Error("unsupported Arrow payload schema")
        if kind == 2 or kind == 3:
            if bits != 8 and bits != 16 and bits != 32 and bits != 64:
                raise Error("invalid Arrow integer width")
        elif kind == 4:
            if bits != 16 and bits != 32 and bits != 64:
                raise Error("invalid Arrow floating width")
        elif bits != 0:
            raise Error("unexpected Arrow payload bit width")
        if kind == 10:
            if size < 0 or size >= PayloadValue.MAX_NODES:
                raise Error("Arrow fixed-size payload list exceeds node limit")
        elif size != 0:
            raise Error("unexpected Arrow payload list size")
        if (kind < 7 and count != 0) or (kind > 7 and count != 1):
            raise Error("Arrow payload schema child count mismatch")
        var position = len(self.nodes)
        self.nodes.append(ArrowPayloadNode(kind, bits, size, name^, Bool(py=raw["nullable"]), List[Int](), raw.get("metadata", Python.none())))
        var children = List[Int](capacity=count)
        var names = Dict[String, Bool]()
        for child in raw_children:
            var index = self._append(child, depth + 1)
            if kind == 7:
                ref key = self.nodes[index].name
                if key in names:
                    raise Error("Arrow struct field names must be unique")
                names[key] = True
            children.append(index)
        self.nodes[position].children = children^
        return position


def payload_arrow_type(schema: ArrowPayloadSchema, index: Int = 0) raises -> PythonObject:
    """Build only Arrow schema objects; no payload values cross into Python."""
    var pa = Python.import_module("pyarrow")
    ref node = schema.nodes[index]
    if node.kind == 0:
        return pa.null()
    if node.kind == 1:
        return pa.bool_()
    if node.kind >= 2 and node.kind <= 4:
        var prefix = "int" if node.kind == 2 else ("uint" if node.kind == 3 else "float")
        var factory = Python.import_module("builtins").getattr(pa, PythonObject(prefix + String(node.bits)))
        return factory()
    if node.kind == 5:
        return pa.string()
    if node.kind == 6:
        return pa.large_string()
    var fields = Python.list()
    for child in node.children:
        ref member = schema.nodes[child]
        fields.append(pa.field(PythonObject(member.name), payload_arrow_type(schema, child),
                               nullable=member.nullable, metadata=member.metadata))
    if node.kind == 7:
        return pa.struct(fields)
    if node.kind == 8:
        return pa.list_(fields[0])
    if node.kind == 9:
        return pa.large_list(fields[0])
    return pa.list_(fields[0], node.size)


struct _ValueBudget:
    var nodes: Int
    var bytes: Int

    def __init__(out self):
        self.nodes = 0
        self.bytes = 0

    def add(mut self, nodes: Int = 0, bytes: Int = 0) raises:
        if nodes < 0 or nodes > PayloadValue.MAX_NODES - self.nodes or bytes < 0 or bytes > PayloadValue.MAX_BYTES - self.bytes:
            raise Error("Arrow payload node or byte resource limit exceeded")
        self.nodes += nodes
        self.bytes += bytes


def _number[dtype: DType](raw: PythonObject, row: Int) raises -> PayloadValue:
    var values = from_numpy_array[dtype](raw["values"])
    if row < 0 or row >= len(values):
        raise Error("Arrow payload numeric buffer is too short")
    comptime if dtype.is_floating_point():
        return PayloadValue.floating(Float64(values[row]))
    elif dtype.is_signed():
        return PayloadValue.integer(Int64(values[row]))
    else:
        return PayloadValue.unsigned(UInt64(values[row]))


def _bounds[dtype: DType](raw: PythonObject, row: Int) raises -> Tuple[Int, Int]:
    var offsets = from_numpy_array[dtype](raw["offsets"])
    if row < 0 or row >= len(offsets) - 1:
        raise Error("Arrow payload offset buffer is too short")
    var begin = Int(offsets[row])
    var end = Int(offsets[row + 1])
    if begin < 0 or end < begin:
        raise Error("Arrow payload offsets must be nonnegative and ascending")
    return (begin, end)


def _read_value(
    schema: ArrowPayloadSchema, node: Int, raw: PythonObject, row: Int,
    mut budget: _ValueBudget,
) raises -> PayloadValue:
    ref spec = schema.nodes[node]
    var rows = Int(py=raw["row_count"])
    if rows < 0 or row < 0 or row >= rows:
        raise Error("Arrow payload row is out of bounds")
    budget.add(nodes=1)
    if spec.kind == 0 or not _valid_bit(raw, row):
        if not spec.nullable:
            raise Error("null in required Arrow payload field")
        return PayloadValue.null()
    if spec.kind >= 1 and spec.kind <= 4:
        budget.add(bytes=8)
    if spec.kind == 1:
        var values = from_numpy_array[DType.uint8](raw["values"])
        var offset = Int(py=raw["validity_offset"])
        # _valid_bit has already checked the offset arithmetic.
        var bit = offset + row
        if bit // 8 >= len(values):
            raise Error("Arrow boolean buffer is too short")
        return PayloadValue.boolean((values[bit // 8] & (UInt8(1) << UInt8(bit % 8))) != 0)
    if spec.kind == 2:
        if spec.bits == 8:
            return _number[DType.int8](raw, row)
        if spec.bits == 16:
            return _number[DType.int16](raw, row)
        if spec.bits == 32:
            return _number[DType.int32](raw, row)
        return _number[DType.int64](raw, row)
    if spec.kind == 3:
        if spec.bits == 8:
            return _number[DType.uint8](raw, row)
        if spec.bits == 16:
            return _number[DType.uint16](raw, row)
        if spec.bits == 32:
            return _number[DType.uint32](raw, row)
        return _number[DType.uint64](raw, row)
    if spec.kind == 4:
        if spec.bits == 16:
            return _number[DType.float16](raw, row)
        if spec.bits == 32:
            return _number[DType.float32](raw, row)
        return _number[DType.float64](raw, row)
    if spec.kind == 7:
        var keys = List[String](capacity=len(spec.children))
        var values = List[PayloadValue](capacity=len(spec.children))
        var children = raw["children"]
        if len(children) != len(spec.children):
            raise Error("Arrow struct child count mismatch")
        for i in range(len(spec.children)):
            var child = spec.children[i]
            budget.add(bytes=schema.nodes[child].name.byte_length())
            keys.append(schema.nodes[child].name.copy())
            values.append(_read_value(schema, child, children[i], row, budget))
        return PayloadValue.object(keys^, values^)
    var begin: Int
    var end: Int
    if spec.kind == 10:
        if spec.size != 0 and row >= Int.MAX // spec.size:
            raise Error("Arrow fixed-list offsets overflow")
        begin = row * spec.size
        end = begin + spec.size
    else:
        var bounds = _bounds[DType.int64](raw, row) if spec.kind == 6 or spec.kind == 9 else _bounds[DType.int32](raw, row)
        begin = bounds[0]
        end = bounds[1]
    if spec.kind == 5 or spec.kind == 6:
        var bytes = from_numpy_array[DType.uint8](raw["values"])
        if end > len(bytes):
            raise Error("Arrow string buffer is too short")
        budget.add(bytes=end - begin)
        return PayloadValue.string(String(from_utf8=bytes[begin:end]))
    var children = raw["children"]
    if len(children) != 1:
        raise Error("Arrow list child count mismatch")
    var child = children[0]
    if end > Int(py=child["row_count"]):
        raise Error("Arrow list child range is out of bounds")
    if end - begin > PayloadValue.MAX_NODES - budget.nodes:
        raise Error("Arrow payload node resource limit exceeded")
    var values = List[PayloadValue](capacity=end - begin)
    for index in range(begin, end):
        values.append(_read_value(schema, spec.children[0], child, index, budget))
    return PayloadValue.array(values^)


def arrow_payload_schemas(columns: PythonObject, rows: Int) raises -> List[ArrowPayloadSchema]:
    if len(columns) > 1024:
        raise Error("Arrow payload field count exceeds limit")
    var result = List[ArrowPayloadSchema](capacity=len(columns))
    var names = Dict[String, Bool]()
    var schema_budget = _ValueBudget()
    for column in columns:
        var name = String(py=column["name"])
        validate_field_name(name)
        if name.byte_length() > Int(UInt16.MAX):
            raise Error("Arrow payload field name exceeds encoded limit")
        if name in names:
            raise Error("duplicate Arrow payload column")
        names[name] = True
        var raw = column["array"]
        if Int(py=raw["row_count"]) != rows:
            raise Error("Arrow payload column length mismatch")
        var schema = ArrowPayloadSchema(raw)
        schema_budget.add(nodes=len(schema.nodes), bytes=schema.name_bytes)
        result.append(schema^)
    return result^


def arrow_payload_fields(
    schemas: List[ArrowPayloadSchema], columns: PythonObject, row: Int,
) raises -> List[DocumentField]:
    var fields = List[DocumentField](capacity=len(schemas))
    var budget = _ValueBudget()
    for i in range(len(schemas)):
        var name = String(py=columns[i]["name"])
        budget.add(bytes=name.byte_length())
        fields.append(DocumentField(name, _read_value(schemas[i], 0, columns[i]["array"], row, budget)))
    return fields^
