"""Bounded JSON predicate trees with ordered, nullable residual evaluation."""
from std.memory import bitcast
from akasha.query.jsonb_projection import JsonbProjection
from akasha.query.json_truth import scalar_predicate, and_truth, or_truth, negate_truth
from akasha.query.control import QueryControl
from akasha.document.record import DocumentField
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_bitmap import LanceBitmapQuery
from akasha.index.nullable_rows import NullableRowMask


def _bind_literal(literal: LanceScalarKey, target: UInt8) raises -> LanceScalarKey:
    # Lance safe_coerce_scalar: within the five native target types the only
    # cross-type conversion is nonnull Int64 -> Float64 (possibly rounded).
    if literal.target == target:
        return literal.copy()
    if literal.target == 2 and target == 3 and not literal.is_null:
        return LanceScalarKey.float_bits(bitcast[DType.uint64](Float64(literal._integer)))
    raise Error("JSON expression literal type does not match function result")


@fieldwise_init
struct JsonExpressionNode(Copyable, Movable):
    var kind: UInt8  # leaf, all, any, not
    var projection: Optional[JsonbProjection]
    var query: LanceBitmapQuery
    var target: UInt8
    var children: List[Int]


struct JsonExpression(Copyable, Movable):
    var _nodes: List[JsonExpressionNode]
    var _depth: Int

    def __init__(out self, var projection: JsonbProjection, var query: LanceBitmapQuery) raises:
        var op = projection.operation()
        if op == 2:
            raise Error("typed struct JSON result is not a scalar predicate")
        var target = UInt8(4 if op == 0 or op == 1 or op == 5 else 5 if op == 4 else 2 if op == 6 or op == 10 else 3 if op == 7 else 1)
        if query.kind > 3:
            raise Error("unsupported JSON expression predicate")
        if query.kind == 0 and len(query.values) != 1:
            raise Error("JSON equality requires one literal")
        if len(query.values) > 65536:
            raise Error("JSON expression literal limit exceeded")
        var literal_bytes = 0
        for i in range(len(query.values)):
            literal_bytes += len(query.values[i]._bytes)
            if literal_bytes > 64 * 1024 * 1024:
                raise Error("JSON expression literal byte limit exceeded")
            query.values[i] = _bind_literal(query.values[i], target)
        if query.lower.key:
            query.lower.key = Optional(_bind_literal(query.lower.key.value(), target))
        if query.upper.key:
            query.upper.key = Optional(_bind_literal(query.upper.key.value(), target))
        self._nodes = [JsonExpressionNode(0, Optional(projection^), query^, target, [])]
        self._depth = 1

    @staticmethod
    def all(children: List[Self]) raises -> Self:
        return Self.combine(1, children)

    @staticmethod
    def any(children: List[Self]) raises -> Self:
        return Self.combine(2, children)

    @staticmethod
    def negate(var child: Self) raises -> Self:
        return Self.combine(3, [child^])

    @staticmethod
    def combine(kind: UInt8, children: List[Self]) raises -> Self:
        if kind < 1 or kind > 3 or (kind == 3 and len(children) != 1):
            raise Error("invalid JSON logical expression")
        var nodes = List[JsonExpressionNode]()
        var roots = List[Int]()
        var depth = 1
        for child in children:
            depth = max(depth, child._depth + 1)
            if depth > 16 or len(nodes) + len(child._nodes) + 1 > 256:
                raise Error("JSON expression depth/node limit exceeded")
            var offset = len(nodes)
            for source in child._nodes:
                var node = source.copy()
                for i in range(len(node.children)):
                    node.children[i] += offset
                nodes.append(node^)
            roots.append(len(nodes) - 1)
        nodes.append(JsonExpressionNode(kind, None, LanceBitmapQuery(), 0, roots^))
        return Self(nodes^, depth)

    def __init__(out self, var nodes: List[JsonExpressionNode], depth: Int) raises:
        self._nodes = nodes^
        self._depth = depth
        self.validate()

    def validate(self) raises:
        if len(self._nodes) == 0 or len(self._nodes) > 256:
            raise Error("JSON expression node limit exceeded")
        var depths = List[Int]()
        var parents = List[Int]()
        var bytes = 0
        for _ in self._nodes:
            parents.append(0)
        for i in range(len(self._nodes)):
            ref node = self._nodes[i]
            var depth = 1
            if node.kind == 0:
                if not node.projection or len(node.children) != 0 or node.query.kind > 3:
                    raise Error("invalid JSON expression leaf")
                var op = node.projection.value().operation()
                if op < 0 or op > 10 or op == 2:
                    raise Error("invalid JSON expression function")
                var target = UInt8(4 if op == 0 or op == 1 or op == 5 else 5 if op == 4 else 2 if op == 6 or op == 10 else 3 if op == 7 else 1)
                if node.target != target or len(node.query.values) > 65536:
                    raise Error("invalid JSON expression type or literal count")
                if node.query.kind == 0 and len(node.query.values) != 1:
                    raise Error("JSON equality requires one literal")
                for literal in node.query.values:
                    if literal.target != target:
                        raise Error("unbound JSON literal")
                    bytes += len(literal._bytes)
                for bound in [node.query.lower.copy(), node.query.upper.copy()]:
                    if bound.key:
                        if bound.key.value().target != target:
                            raise Error("unbound JSON range literal")
                        bytes += len(bound.key.value()._bytes)
            else:
                if node.kind > 3 or node.projection or (node.kind == 3 and len(node.children) != 1):
                    raise Error("invalid JSON logical node")
                for child in node.children:
                    if child < 0 or child >= i:
                        raise Error("JSON expression must be an acyclic tree")
                    parents[child] += 1
                    depth = max(depth, depths[child] + 1)
            if depth > 16 or bytes > 64 * 1024 * 1024:
                raise Error("JSON expression depth/byte limit exceeded")
            depths.append(depth)
        for i in range(len(parents)-1):
            if parents[i] != 1:
                raise Error("JSON expression contains detached or shared nodes")
        if self._depth != depths[len(depths)-1]:
            raise Error("JSON expression depth metadata mismatch")

    def evaluate(self, fields: List[DocumentField], control: Optional[QueryControl] = None) raises -> Optional[Bool]:
        self.validate()
        return self._evaluate(len(self._nodes)-1, fields, [], 0, control)

    def _evaluate(self, slot: Int, fields: List[DocumentField],
                  masks: List[Optional[NullableRowMask]], row: UInt64,
                  control: Optional[QueryControl]) raises -> Optional[Bool]:
        if control:
            control.value().checkpoint(0)
        ref node = self._nodes[slot]
        if node.kind == 0:
            if len(masks) != 0 and Bool(masks[slot]):
                ref mask = masks[slot].value()
                if mask.rows.nulls.contains(row):
                    return None
                return Optional(mask.selected(row))
            var value = node.projection.value().evaluate(fields, control.copy())
            var key = LanceScalarKey.from_json_result(value, node.target)
            return scalar_predicate(key, node.query)
        if node.kind == 3:
            return negate_truth(self._evaluate(node.children[0], fields, masks, row, control))
        var result = Optional(node.kind == 1)
        for child in node.children:
            var value = self._evaluate(child, fields, masks, row, control)
            result = and_truth(result, value) if node.kind == 1 else or_truth(result, value)
            if result:
                if (node.kind == 1 and not result.value()) or (node.kind == 2 and result.value()):
                    break
        return result
