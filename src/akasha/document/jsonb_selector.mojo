"""jsonb 0.5.6 JSONPath Selector port (Datafuse Labs, Apache-2.0).

Owned stage lists replace VecDeque/swap, preserving path and expression order.
Source array ranges are bounded before materializing an enormous index set.
The native codec supplies independently owned results and resource validation.
"""
from std.memory import bitcast
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_number import JsonbNumber
from akasha.document.jsonb_path import JsonbPath, JsonbPathNode, _validate_path
from akasha.query.control import QueryControl


def _invalid() -> Error:
    return Error("InvalidJsonPath")


@fieldwise_init
struct _ExpressionValue(Copyable, Movable):
    # PathValue: null=0, boolean=1, number=2, string=3, raw container=4.
    var kind: Int
    var flag: Bool
    var number: JsonbNumber
    var text: String

    @staticmethod
    def literal(node: JsonbPathNode) raises -> Self:
        var number = JsonbNumber()
        if node.a == 2:
            number = JsonbNumber.integer(bitcast[DType.int64](node.bits))
        elif node.a == 3:
            number = JsonbNumber.unsigned(node.bits)
        elif node.a == 4:
            number = JsonbNumber.floating(bitcast[DType.float64](node.bits))
        var kind = 2 if node.a >= 2 and node.a <= 4 else (3 if node.a == 5 else node.a)
        return Self(kind, node.bits != 0, number, node.text.copy())

    @staticmethod
    def from_value(value: JsonbValue) raises -> Optional[Self]:
        var kind = value.kind()
        if kind == 5:
            return Self(0, False, JsonbNumber(), String())
        if kind == 4:
            return Self(1, value.as_bool(), JsonbNumber(), String())
        if kind == 2 or kind == 3 or kind == 8 or kind == 9:
            return Self(2, False, JsonbNumber.from_value(value), String())
        if kind == 1:
            return Self(3, False, JsonbNumber(), value.as_string())
        if kind == 6 or kind == 7:
            return Self(4, False, JsonbNumber(), String())
        # Source convert_expr_val deliberately skips Extension/Owned items.
        return None

    def to_value(self) raises -> JsonbValue:
        if self.kind == 0:
            return JsonbValue.null()
        if self.kind == 1:
            return JsonbValue.boolean(self.flag)
        if self.kind == 2:
            return _serialize_number(self.number)
        if self.kind == 3:
            return JsonbValue.string(self.text)
        raise _invalid()


def _serialize_number(number: JsonbNumber) raises -> JsonbValue:
    # Selector uses to_owned_jsonb(&Number), not the binary Number codec.
    # With arbitrary_precision disabled, serde converts decimals to F64 even
    # for unary plus. Nonfinite F64 remains a binary JSONB number here.
    if number.kind >= 3:
        return JsonbValue.floating(number.as_f64())
    return number.to_value()


struct _Selection(Movable):
    var work: Int
    var bytes: Int
    var max_work: Int
    var max_results: Int
    var max_bytes: Int
    var control: Optional[QueryControl]

    def __init__(out self, max_work: Int, max_results: Int, max_bytes: Int, var control: Optional[QueryControl]) raises:
        if max_work <= 0 or max_results <= 0 or max_bytes <= 0:
            raise Error("JSONB selector resource limits must be positive")
        self.work = 0
        self.bytes = 0
        self.max_work = max_work
        self.max_results = max_results
        self.max_bytes = max_bytes
        self.control = control^
        self.tick(0)

    def tick(mut self, amount: Int = 1) raises:
        if amount < 0 or amount > self.max_work - self.work:
            raise Error("JSONB selector work resource limit exceeded")
        self.work += amount
        if self.control:
            self.control.value().validate_candidate_count(self.work)
            self.control.value().checkpoint(0)

    def charge(mut self, amount: Int) raises:
        if amount < 0 or amount > self.max_bytes - self.bytes:
            raise Error("JSONB selector byte resource limit exceeded")
        self.bytes += amount

    def count(self, size: Int) raises:
        if size >= self.max_results:
            raise Error("JSONB selector result resource limit exceeded")

    def push(mut self, mut items: List[JsonbValue], item: JsonbValue) raises:
        self.count(len(items))
        self.charge(len(item._data))
        items.append(item.clone())

    def children(mut self, value: JsonbValue) raises -> List[JsonbValue]:
        var count = value._count()
        self.tick(count)
        # Conservative bound checked before allocating owned scalar wrappers.
        self.charge(len(value._data) + 8 * count)
        return value.children()

    def expression_push(mut self, mut values: List[_ExpressionValue], value: JsonbValue) raises:
        self.tick()
        if value.kind() >= 10:
            return
        self.count(len(values))
        self.charge(len(value._data))
        var converted = _ExpressionValue.from_value(value)
        if converted:
            values.append(converted.take())

    def execute(mut self, root: JsonbValue, path: JsonbPath) raises -> List[JsonbValue]:
        _validate_path(path)
        self.tick(len(path.nodes))
        if path.is_predicate():
            return self.eval_expr(root, path, root, path.nodes[path.roots[0]].children[0], 0)
        if len(path.roots) != 0 and path.nodes[path.roots[0]].kind == 1:
            raise _invalid()
        var items = List[JsonbValue]()
        self.push(items, root)
        return self.select(root, path, path.roots, items^, 0)

    def depth(self, value: Int) raises:
        if value > 128:
            raise Error("JSONB selector evaluation depth exceeded")

    def select(mut self, root: JsonbValue, path: JsonbPath, paths: List[Int], var items: List[JsonbValue], depth: Int) raises -> List[JsonbValue]:
        self.depth(depth)
        for index in paths:
            self.tick()
            ref node = path.nodes[index]
            if node.kind == 0 or node.kind == 1:
                continue
            var selected = List[JsonbValue]()
            for item in items:
                self.tick()
                if node.kind == 9 or node.kind == 10:
                    var result = self.filter(root, path, item, node.children[0], depth + 1)
                    if Bool(result) and result.value():
                        self.push(selected, item)
                else:
                    self.select_one(path, node, item, selected)
            items = selected^
        return items^

    def select_one(mut self, path: JsonbPath, node: JsonbPathNode, item: JsonbValue, mut output: List[JsonbValue]) raises:
        var kind = item.kind()
        if node.kind == 3:
            self.recursive(node, item, 0, output)
        elif node.kind == 4 and kind != 6:
            self.push(output, item)
        elif (node.kind == 2 and kind == 7) or (node.kind == 4 and kind == 6):
            var children = self.children(item)
            for child in children:
                self.push(output, child)
        elif node.kind >= 5 and node.kind <= 7 and kind == 7:
            self.charge(len(item._data))
            var keys = item.keys()
            self.tick(len(keys))
            for i in range(len(keys)):
                if keys[i] == node.text:
                    var children = self.children(item)
                    self.push(output, children[i])
                    break
        elif node.kind == 8 and kind == 6:
            var length = item._count()
            for group in node.children:
                ref index = path.nodes[group]
                var start: Int
                var end: Int
                if index.kind == 16:
                    start = _index(index, length)
                    end = start
                    if start < 0 or start >= length:
                        continue
                else:
                    start = max(0, _index(path.nodes[index.children[0]], length))
                    end = _index(path.nodes[index.children[1]], length)
                    if end >= length:
                        end = length - 1
                    # Original source casts a negative end to usize before
                    # materializing its HashSet; reject that unbounded work.
                    if end < 0:
                        raise Error("JSONB selector index range resource limit exceeded")
                    if start > end:
                        continue
                self.tick(end - start + 1)
                var children = self.children(item)
                for i in range(len(children)):
                    if i >= start and i <= end:
                        self.push(output, children[i])

    def recursive(mut self, node: JsonbPathNode, item: JsonbValue, level: Int, mut output: List[JsonbValue]) raises:
        self.tick()
        var matches = True
        var descend = True
        if node.a >= 0:
            if node.b == -1:
                matches = level == node.a
                descend = level < node.a
            elif node.b == 256:
                matches = level >= node.a
            else:
                matches = level >= node.a and level <= node.b
                descend = matches or (level < node.a and node.a <= node.b)
        if matches:
            self.push(output, item)
        if descend and (item.kind() == 6 or item.kind() == 7):
            var children = self.children(item)
            for child in children:
                self.recursive(node, child, level + 1, output)

    def filter_paths(mut self, root: JsonbValue, path: JsonbPath, item: JsonbValue, paths: List[Int], depth: Int) raises -> List[JsonbValue]:
        var items = List[JsonbValue]()
        if len(paths) > 0 and path.nodes[paths[0]].kind == 1:
            self.push(items, item)
        else:
            self.push(items, root)
        return self.select(root, path, paths, items^, depth + 1)

    def convert(mut self, root: JsonbValue, path: JsonbPath, item: JsonbValue, index: Int, depth: Int) raises -> List[_ExpressionValue]:
        self.depth(depth)
        self.tick()
        ref node = path.nodes[index]
        var values = List[_ExpressionValue]()
        if node.kind == 12:
            self.charge(node.text.byte_length())
            values.append(_ExpressionValue.literal(node))
        elif node.kind == 11:
            var items = self.filter_paths(root, path, item, node.children, depth + 1)
            for value in items:
                if value.kind() == 6:
                    var children = self.children(value)
                    for child in children:
                        self.expression_push(values, child)
                else:
                    self.expression_push(values, value)
        else:
            # Upstream unreachable! for manually nested arithmetic operands.
            raise _invalid()
        return values^

    def filter(mut self, root: JsonbValue, path: JsonbPath, item: JsonbValue, index: Int, depth: Int) raises -> Optional[Bool]:
        self.depth(depth)
        self.tick()
        ref node = path.nodes[index]
        if node.kind == 15:
            var items = self.filter_paths(root, path, item, node.children, depth + 1)
            return len(items) != 0
        if node.kind != 13:
            raise _invalid()
        var op = node.a
        if op == 0 or op == 1:
            # Source evaluates both sides, then propagates unknown.
            var lhs = self.filter(root, path, item, node.children[0], depth + 1)
            var rhs = self.filter(root, path, item, node.children[1], depth + 1)
            if not lhs or not rhs:
                return None
            return (lhs.value() and rhs.value()) if op == 0 else (lhs.value() or rhs.value())
        if op > 8:
            return None
        var lhs = self.convert(root, path, item, node.children[0], depth + 1)
        var rhs = self.convert(root, path, item, node.children[1], depth + 1)
        for left in lhs:
            for right in rhs:
                self.tick()
                var result = _compare(op, left, right)
                if not result:
                    return None
                if result.value():
                    return True
        return False

    def eval_expr(mut self, root: JsonbValue, path: JsonbPath, item: JsonbValue, index: Int, depth: Int) raises -> List[JsonbValue]:
        self.depth(depth)
        self.tick()
        ref node = path.nodes[index]
        var output = List[JsonbValue]()
        if node.kind == 14:
            var values = self.convert(root, path, item, node.children[0], depth + 1)
            # Validate the entire sequence before applying numeric operations.
            for value in values:
                if value.kind != 2:
                    raise _invalid()
            for value in values:
                self.tick()
                var number = value.number if node.a == 0 else value.number.neg()
                self.push(output, _serialize_number(number))
        elif node.kind == 13 and node.a >= 9:
            var left = self.convert(root, path, item, node.children[0], depth + 1)
            var right = self.convert(root, path, item, node.children[1], depth + 1)
            if len(left) != 1 or len(right) != 1:
                raise _invalid()
            if left[0].kind != 2 or right[0].kind != 2:
                raise _invalid()
            var a = left[0].number
            var b = right[0].number
            var number: JsonbNumber
            if node.a == 9:
                number = a.add(b)
            elif node.a == 10:
                number = a.sub(b)
            elif node.a == 11:
                number = a.mul(b)
            elif node.a == 12:
                number = a.div(b)
            else:
                number = a.rem(b)
            self.push(output, _serialize_number(number))
        elif node.kind == 13 or node.kind == 15:
            var result = self.filter(root, path, item, index, depth + 1)
            self.push(output, JsonbValue.boolean(result.value()) if result else JsonbValue.null())
        elif node.kind == 12:
            var literal = _ExpressionValue.literal(node)
            var values: List[JsonbValue] = [literal.to_value()]
            self.push(output, JsonbValue.array(values))
        else:
            raise _invalid()
        return output^


def _index(node: JsonbPathNode, length: Int) -> Int:
    if node.a == 0:
        return node.b
    # Source i32 release addition wraps, including extreme last offsets.
    return Int(bitcast[DType.int32](UInt32(length) + UInt32(node.b) - UInt32(1)))


def _compare(op: Int, left: _ExpressionValue, right: _ExpressionValue) raises -> Optional[Bool]:
    if left.kind == 4 or right.kind == 4:
        return None
    if op == 8:
        if left.kind != 3 or right.kind != 3:
            return None
        return left.text.startswith(right.text)
    if left.kind != right.kind:
        return True if op == 3 else Optional[Bool]()
    var order = 0
    if left.kind == 1:
        order = Int(left.flag) - Int(right.flag)
    elif left.kind == 2:
        order = left.number.cmp(right.number)
    elif left.kind == 3:
        order = -1 if left.text < right.text else (1 if left.text > right.text else 0)
    if op == 2:
        return order == 0
    if op == 3:
        return order != 0
    if op == 4:
        return order < 0
    if op == 5:
        return order <= 0
    if op == 6:
        return order > 0
    if op == 7:
        return order >= 0
    return None


struct JsonbSelector(Copyable, Movable):
    """Owned JSONB root with the six original selector output modes.

    Limits bound cumulative traversal/staging; each call starts fresh, including
    after errors. QueryControl provides cancellation, deadline and work limits.
    """
    var root: JsonbValue
    var max_work: Int
    var max_results: Int
    var max_bytes: Int
    var control: Optional[QueryControl]

    def __init__(out self, var root: JsonbValue, *, max_work: Int = 1_000_000, max_results: Int = 65_536, max_bytes: Int = 64 * 1024 * 1024, var control: Optional[QueryControl] = None) raises:
        if max_work <= 0 or max_results <= 0 or max_bytes <= 0:
            raise Error("JSONB selector resource limits must be positive")
        self.root = root^
        self.max_work = max_work
        self.max_results = max_results
        self.max_bytes = max_bytes
        self.control = control^

    def select_values(self, path: JsonbPath) raises -> List[JsonbValue]:
        var selection = _Selection(self.max_work, self.max_results, self.max_bytes, self.control.copy())
        return selection.execute(self.root, path)

    def _array(self, values: List[JsonbValue]) raises -> JsonbValue:
        var size = 4 + 4 * len(values)
        if size > self.max_bytes:
            raise Error("JSONB selector output byte resource limit exceeded")
        for value in values:
            var body = len(value._data) - (8 if value._data[0] == 0x20 else 0)
            if body > self.max_bytes - size:
                raise Error("JSONB selector output byte resource limit exceeded")
            size += body
        return JsonbValue.array(values)

    def select_array(self, path: JsonbPath) raises -> JsonbValue:
        var values = self.select_values(path)
        return self._array(values)

    def select_first(self, path: JsonbPath) raises -> Optional[JsonbValue]:
        var values = self.select_values(path)
        if len(values) == 0:
            return None
        return values[0].clone()

    def select_value(self, path: JsonbPath) raises -> Optional[JsonbValue]:
        var values = self.select_values(path)
        if len(values) == 0:
            return None
        if len(values) == 1:
            return values[0].clone()
        return self._array(values)

    def exists(self, path: JsonbPath) raises -> Bool:
        return len(self.select_values(path)) != 0

    def predicate_match(self, path: JsonbPath) raises -> Optional[Bool]:
        _validate_path(path)
        if not path.is_predicate():
            return None
        var values = self.select_values(path)
        if len(values) != 0 and values[0].kind() == 4:
            return values[0].as_bool()
        return None
