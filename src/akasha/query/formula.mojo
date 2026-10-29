"""Qdrant numeric formula evaluation over native payload and prefetch scores.

Sources: rescore_formula/{formula_scorer,parsed_formula}.rs and shard/query/
formula.rs, 74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
Native bounded arena ownership replaces recursive expression allocation.
"""
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.query.control import QueryControl
from akasha.query.evaluator import matches_expression
from akasha.query.filter_ast import FilterExpression
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


def formula_variable(value: String) raises -> Tuple[Int, String]:
    if value == "$score":
        return (0, "")
    if value.startswith("$score[") and value.endswith("]"):
        var index = 0
        if value.byte_length() == 8:
            raise Error("invalid formula score variable")
        for i in range(7, value.byte_length() - 1):
            var digit = Int(value.as_bytes()[i]) - 48
            if digit < 0 or digit > 9 or index > (Int.MAX - digit) // 10:
                raise Error("invalid formula score variable")
            index = index * 10 + digit
        return (index, "")
    if value == "" or value.startswith("$"):
        raise Error("invalid formula variable")
    # Do not silently interpret JSON paths as literal native field names.
    # Rich path traversal is a separate data-model/source port in D01/D03.
    for part in value.codepoint_slices():
        if part == "." or part == "[" or part == "]" or part == "\"" or part == "\\":
            raise Error("formula JSON paths require the rich payload implementation")
    return (-1, value.copy())


struct FormulaNode(Movable):
    var kind: String
    var children: List[Int]
    var value: Float64
    var key: String
    var score_index: Int
    var condition: Optional[FilterExpression]
    var by_zero_default: Optional[Float64]
    var lambda_value: Float64

    def __init__(
        out self, kind: String, var children: List[Int] = [], *, value: Float32 = 0,
        key: String = "", var condition: Optional[FilterExpression] = None,
        by_zero_default: Optional[Float32] = None, midpoint: Float32 = 0.5,
        scale: Float32 = 1,
    ) raises:
        self.kind = kind.copy()
        self.children = children^
        self.value = Float64(value)
        self.key = key.copy()
        self.score_index = -1
        self.condition = condition^
        self.by_zero_default = None
        self.lambda_value = 0
        if kind == "variable":
            var parsed = formula_variable(key)
            self.score_index = parsed[0]
            self.key = parsed[1].copy()
        if by_zero_default:
            self.by_zero_default = Optional(Float64(by_zero_default.value()))
        if kind == "lin_decay" or kind == "exp_decay" or kind == "gauss_decay":
            self.lambda_value = decay_lambda(kind, midpoint, scale)


struct Formula(Movable):
    var nodes: List[FormulaNode]
    var defaults: List[DocumentField]
    var default_indices: List[Int]
    var default_keys: List[String]

    def __init__(out self, var nodes: List[FormulaNode], var defaults: List[DocumentField] = []) raises:
        self.nodes = nodes^
        self.defaults = defaults^
        self.default_indices = List[Int]()
        self.default_keys = List[String]()
        if len(self.defaults) > 1024:
            raise Error("formula default resource limit exceeded")
        for i in range(len(self.defaults)):
            var variable = formula_variable(self.defaults[i].name)
            for j in range(i):
                if self.default_indices[j] == variable[0] and self.default_keys[j] == variable[1]:
                    raise Error("duplicate formula default variable")
            self.default_indices.append(variable[0])
            self.default_keys.append(variable[1].copy())
        self.validate()

    def validate(self) raises:
        if len(self.nodes) == 0 or len(self.nodes) > 1024:
            raise Error("formula expression resource limit exceeded")
        var parents = List[Int](length=len(self.nodes), fill=-1)
        var depths = List[Int]()
        for i in range(len(self.nodes)):
            ref node = self.nodes[i]
            var count = len(node.children)
            var kind = node.kind
            if kind == "constant" or kind == "variable" or kind == "condition":
                if count:
                    raise Error("formula terminal cannot have children")
                if kind == "constant" and not isfinite(node.value):
                    raise Error("formula constant must be finite")
                if kind == "condition" and not node.condition:
                    raise Error("formula condition is missing")
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
    ) raises -> Float32:
        var precise = self._evaluate(len(self.nodes) - 1, id, fields, scores, control)
        var value = Float32(precise)
        if not isfinite(value):
            raise Error("formula final score is not finite Float32")
        return value

    def _variable(
        self, node: FormulaNode, id: Int, fields: List[DocumentField], scores: List[Dict[Int, Float32]],
    ) raises -> Float64:
        if node.score_index >= 0:
            if node.score_index < len(scores) and id in scores[node.score_index]:
                return Float64(scores[node.score_index][id])
        else:
            for i in range(len(fields)):
                if fields[i].name == node.key:
                    return _formula_number(fields[i].value)
        for i in range(len(self.defaults)):
            if self.default_indices[i] != node.score_index or self.default_keys[i] != node.key:
                continue
            ref value = self.defaults[i].value
            if node.score_index >= 0 and not (value.is_integer() or value.is_floating()):
                return 0
            return _formula_number(value)
        if node.score_index >= 0:
            return 0
        raise Error("formula payload variable is missing and has no default: " + node.key)

    @no_inline
    def _evaluate(
        self, index: Int, id: Int, fields: List[DocumentField], scores: List[Dict[Int, Float32]],
        control: Optional[QueryControl],
    ) raises -> Float64:
        if control:
            control.value().checkpoint(0)
        ref node = self.nodes[index]
        var kind = node.kind
        if kind == "constant":
            return node.value
        if kind == "variable":
            return self._variable(node, id, fields, scores)
        if kind == "condition":
            return Float64(1 if matches_expression(fields, node.condition.value()) else 0)
        if kind == "sum" or kind == "mult":
            var result = Float64(1 if kind == "mult" else 0)
            for child in node.children:
                var value = self._evaluate(child, id, fields, scores, control)
                if kind == "mult":
                    if value == 0:
                        return 0
                    result *= value
                else:
                    result += value
            return result
        var left = self._evaluate(node.children[0], id, fields, scores, control)
        if kind == "neg":
            return -left
        if kind == "abs":
            return abs(left)
        if kind == "div" and left == 0:
            return 0
        var right = Float64(0)
        if len(node.children) > 1:
            right = self._evaluate(node.children[1], id, fields, scores, control)
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
    raise Error("formula payload value is not a number")


@no_inline
def _rounded_product(left: Float64, right: Float64) -> Float64:
    # Match Rust scalar multiplication before the subsequent addition.
    return left * right
