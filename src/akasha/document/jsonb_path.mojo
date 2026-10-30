# Port of jsonb 0.5.6 jsonpath/{parser,path}.rs and nom 8.0.0 combinators.
# Copyright 2023 Datafuse Labs, Apache-2.0; nom MIT. See docs/upstream/licenses.
# This grammar is intentionally separate from Qdrant's document JsonPath.
from akasha.document.jsonb_reader import _decode_string
from akasha.document.fast_float import parse_fast_float
from std.memory import bitcast


@fieldwise_init
struct JsonbPathNode(Copyable, Movable):
    # Paths 0..10 follow the source enum. Expressions: 11 paths, 12 literal,
    # 13 binary, 14 unary, 15 exists. Index=16, range=17.
    # Literal a: null=0, bool=1, i64=2, u64=3, f64=4, string=5; bits
    # preserves the integer/IEEE representation (including signed zero/NaN).
    # Index a: absolute=0, last-relative=1; b is the signed i32 index/offset.
    # Recursive a=-1 means no level clause; b=-1 is single, 256 means last.
    # Binary/unary a follows the source operator enum order.
    var kind: Int
    var a: Int
    var b: Int
    var text: String
    var bits: UInt64
    var children: List[Int]
    var height: Int


@fieldwise_init
struct JsonbPath(Copyable, Movable):
    var nodes: List[JsonbPathNode]
    var roots: List[Int]

    comptime MAX_BYTES = 65_536
    comptime MAX_NODES = 65_536
    comptime MAX_DEPTH = 64
    comptime MAX_WORK = 1_000_000

    @staticmethod
    def parse(text: String) raises -> JsonbPath:
        return JsonbPath.parse_bytes(text.as_bytes())

    @staticmethod
    def parse_bytes(bytes: Span[UInt8, _]) raises -> JsonbPath:
        var parser = _PathParser(bytes)
        parser.space()
        var roots = List[Int]()
        var start = parser.position
        try:
            var expr = parser.expr_or(True)
            roots.append(parser.node(10, children=[expr]))
        except:
            parser.restore(start, 0)
            roots = parser.paths()
        parser.space()
        if parser.position != len(bytes):
            raise Error("invalid JSONB path suffix")
        var nodes = parser.nodes^
        parser.nodes = List[JsonbPathNode]()
        return JsonbPath(nodes^, roots^)

    def is_predicate(self) -> Bool:
        return len(self.roots) == 1 and self.nodes[self.roots[0]].kind == 10


struct _PathParser[origin: ImmOrigin](Movable):
    var bytes: Span[UInt8, Self.origin]
    var position: Int
    var nodes: List[JsonbPathNode]
    var depth: Int
    var work: Int
    var fatal: Bool

    def __init__(out self, bytes: Span[UInt8, Self.origin]) raises:
        if len(bytes) > JsonbPath.MAX_BYTES:
            raise Error("JSONB path byte resource limit exceeded")
        self.bytes = bytes
        self.position = 0
        self.nodes = List[JsonbPathNode]()
        self.depth = 0
        self.work = 0
        self.fatal = False

    def step(mut self) raises:
        self.work += 1
        if self.work > JsonbPath.MAX_WORK:
            self.fatal = True
            raise Error("JSONB path parse work resource limit exceeded")

    def restore(mut self, position: Int, nodes: Int) raises:
        if self.fatal:
            raise Error("invalid or resource-limited JSONB path")
        self.position = position
        while len(self.nodes) > nodes:
            _ = self.nodes.pop()

    def peek(self) -> Int:
        return Int(self.bytes[self.position]) if self.position < len(self.bytes) else -1

    def space(mut self):
        # nom multispace0 for byte slices: SP/TAB/CR/LF, not form feed.
        while self.peek() == 32 or self.peek() == 9 or self.peek() == 10 or self.peek() == 13:
            self.position += 1

    def take(mut self, token: String, insensitive: Bool = False) -> Bool:
        var bytes = token.as_bytes()
        if len(bytes) > len(self.bytes) - self.position:
            return False
        for i in range(len(bytes)):
            var a = self.bytes[self.position + i]
            var b = bytes[i]
            if insensitive:
                if a >= 65 and a <= 90:
                    a += 32
                if b >= 65 and b <= 90:
                    b += 32
            if a != b:
                return False
        self.position += len(bytes)
        return True

    def expect(mut self, token: String) raises:
        if not self.take(token):
            raise Error("invalid JSONB path token")

    def node(mut self, kind: Int, a: Int = 0, b: Int = 0, var text: String = String(), bits: UInt64 = 0, var children: List[Int] = List[Int]()) raises -> Int:
        self.step()
        var height = 1
        for child in children:
            height = max(height, self.nodes[child].height + 1)
        if len(self.nodes) >= JsonbPath.MAX_NODES or height > JsonbPath.MAX_DEPTH:
            self.fatal = True
            raise Error("JSONB path AST node or depth resource limit exceeded")
        var index = len(self.nodes)
        self.nodes.append(JsonbPathNode(kind, a, b, text^, bits, children^, height))
        return index

    def string(mut self, quoted: Bool) raises -> String:
        self.step()
        if quoted:
            self.expect("\"")
        var start = self.position
        var delimiters = " ,.:{}[]()?@$|<>!=+-*/%\"'"
        while self.position < len(self.bytes):
            var c = self.bytes[self.position]
            if c == 92:
                # The source scan skips the entire escape before parse_string.
                var i = self.position
                if len(self.bytes) - i < 2:
                    raise Error("incomplete JSONB path escape")
                var size = 2
                if self.bytes[i + 1] == 117:
                    if len(self.bytes) - i < 6:
                        raise Error("incomplete JSONB path Unicode escape")
                    size = 8 if self.bytes[i + 2] == 123 else 6
                if size > len(self.bytes) - i:
                    raise Error("incomplete JSONB path Unicode escape")
                self.position += size
                continue
            if quoted:
                if c == 34:
                    break
            else:
                var stop = False
                for delimiter in delimiters.as_bytes():
                    if c == delimiter:
                        stop = True
                        break
                if stop:
                    break
            self.position += 1
        var end = self.position
        if end == start:
            raise Error("empty JSONB path field or string")
        if quoted:
            # Upstream slices beyond EOF here; map that panic to an error.
            self.expect("\"")
        return _decode_string(self.bytes[start:end])

    def integer(mut self, signed: Bool, width: Int) raises -> UInt64:
        var negative = False
        if signed:
            negative = self.take("-")
            if not negative:
                _ = self.take("+")
        var limit = UInt64.MAX
        if width < 64:
            limit = (UInt64(1) << UInt64(width - (1 if signed else 0))) - 1
        elif signed:
            limit = UInt64(Int64.MAX)
        if negative:
            limit += 1
        var value = UInt64(0)
        var digits = 0
        while self.peek() >= 48 and self.peek() <= 57:
            var digit = UInt64(self.peek() - 48)
            if value > (limit - digit) // 10:
                raise Error("JSONB path integer overflow")
            value = value * 10 + digit
            self.position += 1
            digits += 1
        if digits == 0:
            raise Error("missing JSONB path integer")
        return UInt64(0) - value if negative else value

    def floating(mut self) raises -> UInt64:
        var start = self.position
        var numeric = False
        _ = self.take("+") or self.take("-")
        while self.peek() >= 48 and self.peek() <= 57:
            numeric = True
            self.position += 1
        if self.take("."):
            while self.peek() >= 48 and self.peek() <= 57:
                numeric = True
                self.position += 1
        if numeric:
            if self.take("e", True):
                _ = self.take("+") or self.take("-")
                var first = self.position
                while self.peek() >= 48 and self.peek() <= 57:
                    self.position += 1
                if first == self.position:
                    # nom cut(digit1): failure must not backtrack into a path.
                    self.fatal = True
                    raise Error("invalid JSONB path floating exponent")
        else:
            self.position = start
            if not (self.take("nan", True) or self.take("infinity", True) or self.take("inf", True)):
                raise Error("invalid JSONB path floating literal")
        return bitcast[DType.uint64](parse_fast_float(self.bytes[start:self.position]))

    def index(mut self) raises -> Int:
        var start = self.position
        var count = len(self.nodes)
        try:
            var value = self.integer(True, 32)
            return self.node(16, b=Int(bitcast[DType.int64](value)))
        except:
            self.restore(start, count)
        if not self.take("last", True):
            raise Error("invalid JSONB array index")
        var after_last = self.position
        self.space()
        var negative = self.take("-")
        var positive = False
        if not negative:
            positive = self.take("+")
        if negative or positive:
            self.space()
            try:
                var value = Int(bitcast[DType.int64](self.integer(True, 32)))
                if negative:
                    value = Int(Int32.MAX) if value == Int(Int32.MIN) else -value
                return self.node(16, a=1, b=value)
            except:
                self.restore(after_last, count)
        else:
            self.position = after_last
        return self.node(16, a=1)

    def array_index(mut self) raises -> Int:
        var first = self.index()
        var start = self.position
        var count = len(self.nodes)
        self.space()
        if self.take("to", True):
            self.space()
            try:
                var last = self.index()
                return self.node(17, children=[first, last])
            except:
                self.restore(start, count)
        else:
            self.position = start
        return first

    def recursive_level(mut self) raises -> Tuple[Int, Int]:
        self.expect("{")
        self.space()
        var start = Int(self.integer(False, 8))
        self.space()
        var end = -1
        if self.take("to", True):
            self.space()
            if self.take("last", True):
                end = 256
            else:
                end = Int(self.integer(False, 8))
            self.space()
        self.expect("}")
        return start, end

    def inner_path(mut self) raises -> Int:
        self.step()
        var start = self.position
        var count = len(self.nodes)
        for branch in range(7):
            try:
                if branch == 0:
                    self.expect(".**")
                    var level_start = self.position
                    try:
                        var level = self.recursive_level()
                        return self.node(3, a=level[0], b=level[1])
                    except:
                        self.restore(level_start, count)
                    return self.node(3, a=-1, b=-1)
                if branch == 1:
                    self.expect(".*")
                    return self.node(2)
                if branch == 2:
                    self.expect("[")
                    self.space()
                    self.expect("*")
                    self.space()
                    self.expect("]")
                    return self.node(4)
                if branch == 3 or branch == 4:
                    self.expect(":" if branch == 3 else ".")
                    var field_start = self.position
                    var text: String
                    try:
                        text = self.string(True)
                    except:
                        self.restore(field_start, count)
                        text = self.string(False)
                    return self.node(6 if branch == 3 else 5, text=text^)
                if branch == 5:
                    self.expect("[")
                    var children = List[Int]()
                    while True:
                        self.space()
                        children.append(self.array_index())
                        self.space()
                        if not self.take(","):
                            break
                    self.expect("]")
                    return self.node(8, children=children^)
                self.expect("[")
                self.space()
                var text = self.string(True)
                self.space()
                self.expect("]")
                return self.node(7, text=text^)
            except:
                self.restore(start, count)
        raise Error("invalid JSONB inner path")

    def filter(mut self) raises -> Int:
        self.expect("?")
        self.space()
        self.expect("(")
        self.space()
        var expr = self.expr_or(False)
        self.space()
        self.expect(")")
        return self.node(9, children=[expr])

    def path(mut self) raises -> Int:
        var start = self.position
        var count = len(self.nodes)
        self.space()
        try:
            var result = self.inner_path()
            self.space()
            return result
        except:
            self.restore(start, count)
        self.space()
        var result = self.filter()
        self.space()
        return result

    def tail(mut self, filters: Bool) raises -> List[Int]:
        var result = List[Int]()
        while True:
            var start = self.position
            var count = len(self.nodes)
            try:
                var item: Int
                if filters:
                    item = self.path()
                else:
                    self.space()
                    item = self.inner_path()
                    self.space()
                result.append(item)
            except:
                self.restore(start, count)
                return result^

    def paths(mut self) raises -> List[Int]:
        var result = List[Int]()
        var start = self.position
        var count = len(self.nodes)
        if self.take("$"):
            result.append(self.node(0))
        else:
            try:
                self.space()
                var text = self.string(False)
                self.space()
                result.append(self.node(5, text=text^))
            except:
                self.restore(start, count)
        var tail = self.tail(True)
        for item in tail:
            result.append(item)
        return result^

    def expr_paths(mut self, root: Bool, filters: Bool = False) raises -> List[Int]:
        var first: Int
        if self.take("$"):
            first = self.node(0)
        elif not root and self.take("@"):
            first = self.node(1)
        else:
            raise Error("expression path requires root or current marker")
        var result: List[Int] = [first]
        var tail = self.tail(filters)
        for item in tail:
            result.append(item)
        return result^

    def literal(mut self) raises -> Int:
        var start = self.position
        var count = len(self.nodes)
        for branch in range(7):
            try:
                if branch == 0:
                    self.expect("null")
                    return self.node(12)
                if branch == 1 or branch == 2:
                    self.expect("true" if branch == 1 else "false")
                    return self.node(12, a=1, bits=UInt64(1) if branch == 1 else UInt64(0))
                if branch == 3 or branch == 4:
                    var bits = self.integer(branch == 4, 64)
                    return self.node(12, a=2 if branch == 4 else 3, bits=bits)
                if branch == 5:
                    var bits = self.floating()
                    return self.node(12, a=4, bits=bits)
                var text = self.string(True)
                return self.node(12, a=5, text=text^)
            except:
                self.restore(start, count)
        raise Error("invalid JSONB path literal")

    def inner_expr(mut self, root: Bool) raises -> Int:
        var start = self.position
        var count = len(self.nodes)
        try:
            return self.node(11, children=self.expr_paths(root))
        except:
            self.restore(start, count)
        return self.literal()

    def op(mut self) raises -> Int:
        # Source enum order (And/Or are constructed by expression chains).
        var tokens = ["==", "!=", "<>", "<=", "<", ">=", ">", "starts with", "+", "-", "*", "/", "%"]
        var codes = [2, 3, 3, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13]
        for i in range(len(tokens)):
            if self.take(tokens[i]):
                return codes[i]
        raise Error("invalid JSONB expression operator")

    def expr_atom(mut self, root: Bool) raises -> Int:
        self.step()
        var start = self.position
        var count = len(self.nodes)
        for branch in range(4):
            try:
                if branch == 0:
                    var op: Int
                    if self.take("+"):
                        op = 0
                    elif self.take("-"):
                        op = 1
                    else:
                        raise Error("missing JSONB unary operator")
                    self.space()
                    var child = self.inner_expr(root)
                    self.space()
                    return self.node(14, a=op, children=[child])
                if branch == 1:
                    self.space()
                    var left = self.inner_expr(root)
                    self.space()
                    var op = self.op()
                    self.space()
                    var right = self.inner_expr(root)
                    self.space()
                    return self.node(13, a=op, children=[left, right])
                if branch == 2:
                    self.expect("(")
                    self.space()
                    var expr = self.expr_or(root)
                    self.space()
                    self.expect(")")
                    return expr
                self.expect("exists")
                self.space()
                self.expect("(")
                self.space()
                var paths = self.expr_paths(False, filters=True)
                self.space()
                self.expect(")")
                return self.node(15, children=paths^)
            except:
                self.restore(start, count)
        raise Error("invalid JSONB expression atom")

    def expr_and(mut self, root: Bool) raises -> Int:
        var left = self.expr_atom(root)
        while True:
            var start = self.position
            var count = len(self.nodes)
            self.space()
            if not self.take("&&"):
                self.position = start
                return left
            self.space()
            try:
                var right = self.expr_atom(root)
                left = self.node(13, a=0, children=[left, right])
            except:
                self.restore(start, count)
                return left

    def expr_or(mut self, root: Bool) raises -> Int:
        if self.depth >= JsonbPath.MAX_DEPTH:
            self.fatal = True
            raise Error("JSONB path parse nesting resource limit exceeded")
        self.depth += 1
        try:
            var left = self.expr_and(root)
            while True:
                var start = self.position
                var count = len(self.nodes)
                self.space()
                if not self.take("||"):
                    self.position = start
                    self.depth -= 1
                    return left
                self.space()
                try:
                    var right = self.expr_and(root)
                    left = self.node(13, a=1, children=[left, right])
                except:
                    self.restore(start, count)
                    self.depth -= 1
                    return left
        except err:
            self.depth -= 1
            raise err


def _validate_path(path: JsonbPath) raises:
    # The parser emits a postorder arena. Check public mutable ASTs before
    # indexing: child ordering also rejects cycles without recursive validation.
    if len(path.nodes) > JsonbPath.MAX_NODES or len(path.roots) > JsonbPath.MAX_NODES:
        raise Error("JSONB selector AST resource limit exceeded")
    var heights = List[Int](length=len(path.nodes), fill=0)
    var work = len(path.roots)
    var text_bytes = 0
    for i in range(len(path.nodes)):
        ref node = path.nodes[i]
        var kind = node.kind
        var count = len(node.children)
        work += count + 1
        text_bytes += node.text.byte_length()
        if work > JsonbPath.MAX_WORK or text_bytes > JsonbPath.MAX_BYTES:
            raise Error("JSONB selector AST resource limit exceeded")
        if kind < 0 or kind > 17:
            raise Error("InvalidJsonPath")
        var height = 1
        for child in node.children:
            if child < 0 or child >= i:
                raise Error("InvalidJsonPath")
            height = max(height, heights[child] + 1)
            var child_kind = path.nodes[child].kind
            if kind == 8:
                if child_kind != 16 and child_kind != 17:
                    raise Error("InvalidJsonPath")
            elif kind == 11 or kind == 15:
                if child_kind > 9:
                    raise Error("InvalidJsonPath")
            elif kind == 17:
                if child_kind != 16:
                    raise Error("InvalidJsonPath")
            elif child_kind < 11 or child_kind > 15:
                raise Error("InvalidJsonPath")
        if height > JsonbPath.MAX_DEPTH:
            raise Error("JSONB selector AST depth exceeded")
        heights[i] = height
        if (kind <= 7 or kind == 12 or kind == 16) and count != 0:
            raise Error("InvalidJsonPath")
        if (kind == 9 or kind == 10 or kind == 14) and count != 1:
            raise Error("InvalidJsonPath")
        if (kind == 13 or kind == 17) and count != 2:
            raise Error("InvalidJsonPath")
        if kind == 3 and (node.a < -1 or node.a > 255 or node.b < -1 or node.b > 256):
            raise Error("InvalidJsonPath")
        if kind == 12 and (node.a < 0 or node.a > 5 or (node.a == 1 and node.bits > 1)):
            raise Error("InvalidJsonPath")
        if kind == 13 and (node.a < 0 or node.a > 13):
            raise Error("InvalidJsonPath")
        if kind == 14 and (node.a < 0 or node.a > 1):
            raise Error("InvalidJsonPath")
        if kind == 16 and (node.a < 0 or node.a > 1 or node.b < Int(Int32.MIN) or node.b > Int(Int32.MAX)):
            raise Error("InvalidJsonPath")
    for root in path.roots:
        if root < 0 or root >= len(path.nodes) or path.nodes[root].kind > 10:
            raise Error("InvalidJsonPath")
