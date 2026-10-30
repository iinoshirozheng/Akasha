"""Bounded JSONB column expressions using source Lance scalar functions."""
from akasha.document.record import DocumentField, validate_field_name
from akasha.document.value import PayloadValue
from akasha.document.jsonb_path import JsonbPath
from akasha.document.lance_json import LanceJson
from akasha.document.lance_json_result import LanceJsonResult, evaluate_lance_json, lance_json_operation
from akasha.query.payload_condition import _required, _known_keys, _i64
from akasha.query.control import QueryControl


def _argument(value: PayloadValue) raises -> Optional[String]:
    if value.is_null():
        return None
    var text = value.as_string()
    if text.byte_length() > JsonbPath.MAX_BYTES:
        raise Error("JSONB projection argument byte resource limit exceeded")
    return Optional(text^)


def _limit(spec: PayloadValue, name: String, default: Int) raises -> Int:
    var item = spec.get_key(name)
    if not item:
        return default
    var value = _i64(item.value())
    if not value or value.value() <= 0:
        raise Error("JSONB projection limits require positive Int64 integers")
    return Int(value.value())


@fieldwise_init
struct _JsonbCall(Copyable, Movable):
    var operation: Int
    var argument: Optional[String]
    var needle: Optional[String]


struct JsonbProjection(Copyable, Movable):
    var source: String
    var calls: List[_JsonbCall]
    var max_work: Int
    var max_results: Int
    var max_bytes: Int

    def __init__(out self, spec: PayloadValue) raises:
        self.max_work = _limit(spec, "max_work", 1_000_000)
        self.max_results = _limit(spec, "max_results", 65_536)
        self.max_bytes = _limit(spec, "max_bytes", 64 * 1024 * 1024)
        self.source = ""
        self.calls = List[_JsonbCall]()
        var reversed = List[_JsonbCall]()
        var current = spec.clone()
        while True:
            if len(reversed) >= 16:
                raise Error("JSONB projection step resource limit exceeded")
            var allowed: List[String] = ["function", "input", "argument", "needle"]
            if len(reversed) == 0:
                allowed.append("max_work")
                allowed.append("max_results")
                allowed.append("max_bytes")
            _known_keys(current, allowed)
            var op = lance_json_operation(_required(current, "function").as_string())
            # Every intermediate value is the JSONB input of another UDF.
            if len(reversed) != 0 and op != 4:
                raise Error("nested JSONB projection input must return JSONB (json_get)")
            var argument = _argument(_required(current, "argument"))
            var raw_needle = current.get_key("needle")
            if Bool(raw_needle) != (op == 9):
                raise Error("only json_array_contains requires a needle argument")
            var needle = Optional[String]()
            if raw_needle:
                needle = _argument(raw_needle.value())
            if argument and (op <= 3 or op >= 9):
                _ = JsonbPath.parse(argument.value())
            reversed.append(_JsonbCall(op, argument^, needle^))
            var input = _required(current, "input")
            if input.is_string():
                self.source = input.as_string()
                validate_field_name(self.source)
                break
            if not input.is_object():
                raise Error("JSONB projection input requires a field name or JSONB expression")
            current = input^
        for i in range(len(reversed) - 1, -1, -1):
            self.calls.append(reversed[i].copy())

    def operation(self) -> Int:
        return self.calls[len(self.calls) - 1].operation

    def evaluate(self, fields: List[DocumentField], var control: Optional[QueryControl] = None) raises -> LanceJsonResult:
        # Share cancellation/deadline, but keep scanner row and JSON work
        # budgets separate. Each source call retains its own traversal budget.
        if control:
            control.value().checkpoint(0)
            control.value().max_candidates = self.max_work
        for slot in range(len(fields)):
            ref field = fields[slot]
            if field.name != self.source:
                continue
            if field.value.is_null():
                return LanceJsonResult()
            if not field.value.is_jsonb():
                raise Error("JSONB projection requires a JSONB payload value")
            var consumer = LanceJson(field.value.as_jsonb(), max_work=self.max_work,
                max_results=self.max_results, max_bytes=self.max_bytes, control=control.copy())
            for i in range(len(self.calls)):
                ref call = self.calls[i]
                if not call.argument or (call.operation == 9 and not call.needle):
                    return LanceJsonResult()
                var result = evaluate_lance_json(consumer, call.operation, call.argument.value(),
                    call.needle.value() if call.needle else String())
                if i + 1 == len(self.calls):
                    return result^
                if not result.binary:
                    return LanceJsonResult()
                consumer = LanceJson(result.binary.take(), max_work=self.max_work,
                    max_results=self.max_results, max_bytes=self.max_bytes, control=control.copy())
        return LanceJsonResult()
