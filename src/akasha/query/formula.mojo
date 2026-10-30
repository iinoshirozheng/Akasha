"""Qdrant numeric formula evaluation over native payload and prefetch scores.

Sources: rescore_formula/{formula_scorer,parsed_formula}.rs and shard/query/
formula.rs, 74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
Native bounded arena ownership replaces recursive expression allocation.
"""
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.json_path import FormulaVariable, JsonPath
from akasha.document.geo import GeoPoint, haversine_distance
from akasha.document.datetime import DateTimeValue
from akasha.query.control import QueryControl
from akasha.query.evaluator import matches_expression
from akasha.query.point_condition import PointFilterContext
from akasha.query.filter_ast import FilterExpression
from akasha.query.formula_payload import formula_payload_value
from std.math import exp, isfinite, log, log10, pow, sqrt


def decay_lambda(kind: String, midpoint: Float32, scale: Float32) raises -> Float64:
    var middle = Float64(midpoint)
    var width = Float64(scale)
    if not isfinite(middle) or not isfinite(width):
        raise Error("formula decay parameters must be finite")
    if kind == "lin_decay":
        if middle < 0 or middle > 1:
            raise Error("linear decay midpoint must be in [0, 1]")
    elif middle <= 0 or middle >= 1:
        raise Error("decay midpoint must be in (0, 1)")
    if width <= 0:
        raise Error("decay scale must be positive")
    if kind == "lin_decay":
        return (Float64(1) - middle) / width
    if kind == "exp_decay":
        return log(middle) / width
    if kind == "gauss_decay":
        return log(middle) / (width * width)
    raise Error("unknown formula decay kind")


struct FormulaNode(Movable):
    var kind: String
    var children: List[Int]
    var value: Float64
    var variable: Optional[FormulaVariable]
    var condition: Optional[FilterExpression]
    var by_zero_default: Optional[Float64]
    var lambda_value: Float64
    var origin: Optional[GeoPoint]
    var datetime: Optional[DateTimeValue]

    def __init__(
        out self, kind: String, var children: List[Int] = [], *, value: Float32 = 0,
        key: String = "", var condition: Optional[FilterExpression] = None,
        by_zero_default: Optional[Float32] = None, midpoint: Float32 = 0.5,
        scale: Float32 = 1, var origin: Optional[GeoPoint] = None,
    ) raises:
        self.kind = kind.copy()
        self.children = children^
        self.value = Float64(value)
        self.variable = None
        self.condition = condition^
        self.by_zero_default = None
        self.lambda_value = 0
        self.origin = origin^
        self.datetime = None
        if kind == "variable":
            var parsed = FormulaVariable.parse(key)
            self.variable = Optional(parsed^)
        if kind == "geo_distance" or kind == "datetime_key":
            self.variable = Optional(FormulaVariable(None, Optional(JsonPath.parse(key))))
        if kind == "datetime":
            self.datetime = Optional(DateTimeValue.parse(key))
        if kind != "geo_distance" and self.origin:
            raise Error("formula origin requires geo_distance")
        if by_zero_default:
            self.by_zero_default = Optional(Float64(by_zero_default.value()))
        if kind == "lin_decay" or kind == "exp_decay" or kind == "gauss_decay":
            self.lambda_value = decay_lambda(kind, midpoint, scale)


struct FormulaDefault(Movable):
    var variable: FormulaVariable
    var value: PayloadValue

    def __init__(out self, name: String, var value: PayloadValue) raises:
        self.variable = FormulaVariable.parse(name)
        self.value = value^


struct Formula(Movable):
    var nodes: List[FormulaNode]
    var defaults: List[FormulaDefault]

    def __init__(out self, var nodes: List[FormulaNode], var defaults: List[FormulaDefault] = []) raises:
        self.nodes = nodes^
        self.defaults = defaults^
        self.validate()

    def validate(self) raises:
        if len(self.nodes) == 0 or len(self.nodes) > 1024:
            raise Error("formula expression resource limit exceeded")
        if len(self.defaults) > 1024:
            raise Error("formula default resource limit exceeded")
        var default_nodes = 0
        var default_bytes = 0
        for i in range(len(self.defaults)):
            default_nodes += self.defaults[i].value.node_count()
            default_bytes += self.defaults[i].value.content_bytes()
            ref variable = self.defaults[i].variable
            if variable.path:
                default_bytes += variable.path.value().display().byte_length()
            else:
                default_bytes += 8 + String(variable.score_index.value()).byte_length()
            if default_nodes > PayloadValue.MAX_NODES or default_bytes > PayloadValue.MAX_BYTES:
                raise Error("formula default payload resource limit exceeded")
            for j in range(i):
                if self.defaults[i].variable.same(self.defaults[j].variable):
                    raise Error("duplicate formula default variable")
        var parents = List[Int](length=len(self.nodes), fill=-1)
        var depths = List[Int]()
        for i in range(len(self.nodes)):
            ref node = self.nodes[i]
            var count = len(node.children)
            var kind = node.kind
            if kind == "constant" or kind == "variable" or kind == "condition" or kind == "geo_distance" or kind == "datetime" or kind == "datetime_key":
                if count:
                    raise Error("formula terminal cannot have children")
                if kind == "constant" and not isfinite(node.value):
                    raise Error("formula constant must be finite")
                if kind == "condition" and not node.condition:
                    raise Error("formula condition is missing")
                if kind == "variable" and not node.variable:
                    raise Error("formula variable is missing")
                if kind == "geo_distance":
                    if not node.variable or not node.variable.value().path or not node.origin:
                        raise Error("geo_distance requires an origin and payload path")
                    node.origin.value().validate()
                if kind == "datetime":
                    if not node.datetime:
                        raise Error("datetime constant is missing")
                    node.datetime.value().validate()
                if kind == "datetime_key" and (not node.variable or not node.variable.value().path):
                    raise Error("datetime_key requires a payload path")
            elif kind == "sum" or kind == "mult":
                pass
            elif kind == "div" or kind == "pow":
                if count != 2:
                    raise Error("binary formula operator requires two children")
            elif kind == "lin_decay" or kind == "exp_decay" or kind == "gauss_decay":
                if count < 1 or count > 2:
                    raise Error("formula decay requires x and optional target")
            elif kind == "neg" or kind == "abs" or kind == "sqrt" or kind == "exp" or kind == "ln" or kind == "log10":
                if count != 1:
                    raise Error("unary formula operator requires one child")
            else:
                raise Error("unsupported formula operator")
            if node.condition:
                node.condition.value().validate()
            if node.origin and kind != "geo_distance":
                raise Error("formula origin requires geo_distance")
            if node.datetime and kind != "datetime":
                raise Error("formula datetime value requires datetime")
            if node.by_zero_default and (kind != "div" or not isfinite(node.by_zero_default.value())):
                raise Error("formula division default must be finite and requires div")
            var depth = 0
            for child in node.children:
                if child < 0 or child >= i or parents[child] != -1:
                    raise Error("formula must be an ordered tree")
                parents[child] = i
                depth = max(depth, depths[child] + 1)
            if depth > 64:
                raise Error("formula expression depth exceeds 64")
            depths.append(depth)
        for i in range(len(self.nodes) - 1):
            if parents[i] == -1:
                raise Error("formula contains an unreachable node")

    def score(
        self, id: Int, fields: List[DocumentField], scores: List[Dict[Int, Float32]],
        control: Optional[QueryControl] = None,
        context: Optional[PointFilterContext] = None,
    ) raises -> Float32:
        var point = context.value().copy() if context else PointFilterContext(Optional(id))
        var precise = self._evaluate(len(self.nodes) - 1, id, fields, scores, control, point)
        var value = Float32(precise)
        if not isfinite(value):
            raise Error("formula final score is not finite Float32")
        return value

    def _variable(
        self, node: FormulaNode, id: Int, fields: List[DocumentField], scores: List[Dict[Int, Float32]],
    ) raises -> Float64:
        ref variable = node.variable.value()
        if variable.score_index:
            var index = variable.score_index.value()
            if index < UInt64(len(scores)) and id in scores[Int(index)]:
                return Float64(scores[Int(index)][id])
        else:
            var payload = self._payload_value(variable, fields)
            return _formula_number(payload)
        for i in range(len(self.defaults)):
            if not self.defaults[i].variable.same(variable):
                continue
            ref value = self.defaults[i].value
            if variable.score_index and not (value.is_integer() or value.is_floating() or value.is_unsigned()):
                return 0
            return _formula_number(value)
        return 0

    def _payload_value(self, variable: FormulaVariable, fields: List[DocumentField]) raises -> PayloadValue:
        var payload = formula_payload_value(fields, variable.path.value())
        if payload:
            return payload.take()
        for i in range(len(self.defaults)):
            if self.defaults[i].variable.same(variable):
                return self.defaults[i].value.clone()
        raise Error("formula payload variable is missing and has no default: " + variable.path.value().display())

    @no_inline
    def _evaluate(
        self, index: Int, id: Int, fields: List[DocumentField], scores: List[Dict[Int, Float32]],
        control: Optional[QueryControl], context: PointFilterContext,
    ) raises -> Float64:
        if control:
            control.value().checkpoint(0)
        ref node = self.nodes[index]
        var kind = node.kind
        if kind == "constant":
            return node.value
        if kind == "variable":
            return self._variable(node, id, fields, scores)
        if kind == "geo_distance":
            var value = self._payload_value(node.variable.value(), fields)
            return haversine_distance(node.origin.value(), GeoPoint.from_payload(value))
        if kind == "datetime":
            return Float64(node.datetime.value().timestamp()) / Float64(1_000_000)
        if kind == "datetime_key":
            var value = self._payload_value(node.variable.value(), fields)
            return Float64(DateTimeValue.from_payload(value).timestamp()) / Float64(1_000_000)
        if kind == "condition":
            return Float64(1 if matches_expression(fields, node.condition.value(), context) else 0)
        if kind == "sum" or kind == "mult":
            var result = Float64(1 if kind == "mult" else 0)
            for child in node.children:
                var value = self._evaluate(child, id, fields, scores, control, context)
                if kind == "mult":
                    if value == 0:
                        return 0
                    result *= value
                else:
                    result += value
            return result
        var left = self._evaluate(node.children[0], id, fields, scores, control, context)
        if kind == "neg":
            return -left
        if kind == "abs":
            return abs(left)
        if kind == "div" and left == 0:
            return 0
        var right = Float64(0)
        if len(node.children) > 1:
            right = self._evaluate(node.children[1], id, fields, scores, control, context)
        var result: Float64
        if kind == "div":
            if right == 0 and node.by_zero_default:
                return node.by_zero_default.value()
            result = left / right
        elif kind == "pow":
            result = pow(left, right)
        elif kind == "sqrt":
            result = sqrt(left)
        elif kind == "exp":
            result = exp(left)
        elif kind == "ln":
            result = log(left)
        elif kind == "log10":
            result = log10(left)
        elif kind == "lin_decay":
            return max(_rounded_product(-node.lambda_value, abs(left - right)) + Float64(1), Float64(0))
        elif kind == "exp_decay":
            return exp(node.lambda_value * abs(left - right))
        else:
            var difference = left - right
            return exp(node.lambda_value * difference * difference)
        if not isfinite(result):
            raise Error("formula " + kind + " produced a nonfinite value")
        return result


def _formula_number(value: PayloadValue) raises -> Float64:
    if value.is_integer():
        return Float64(value.as_int())
    if value.is_floating():
        return value.as_float()
    if value.is_unsigned():
        return Float64(value.as_uint())
    raise Error("formula payload value is not a number")


@no_inline
def _rounded_product(left: Float64, right: Float64) -> Float64:
    # Match Rust scalar multiplication before the subsequent addition.
    return left * right
