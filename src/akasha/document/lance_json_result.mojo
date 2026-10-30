"""Owned typed results for the source-ported Lance JSON consumers.

This shared dispatcher preserves source scalar types, raw JSONB and nulls;
in particular F64 results do not pass through finite-only persisted payloads.
"""
from akasha.document.jsonb import JsonbValue
from akasha.document.lance_json import LanceJson


def lance_json_operation(name: String) raises -> Int:
    var names: List[String] = ["json_path", "json_extract", "json_extract_with_type",
        "json_exists", "json_get", "json_get_string", "json_get_int", "json_get_float",
        "json_get_bool", "json_array_contains", "json_array_length"]
    for i in range(len(names)):
        if names[i] == name:
            return i
    raise Error("unknown Lance JSON function")


struct LanceJsonResult(Copyable, Movable):
    var text: Optional[String]
    var binary: Optional[JsonbValue]
    var integer: Optional[Int64]
    var floating: Optional[Float64]
    var boolean: Optional[Bool]
    var type_tag: UInt8

    def __init__(out self):
        self.text = None
        self.binary = None
        self.integer = None
        self.floating = None
        self.boolean = None
        self.type_tag = 0

    def valid(self, operation: Int) -> Bool:
        if operation == 2:
            return True
        return Bool(self.text) or Bool(self.binary) or Bool(self.integer) or Bool(self.floating) or Bool(self.boolean)

    def owned_bytes(self) -> Int:
        return (self.text.value().byte_length() if self.text else 0) + (len(self.binary.value()._data) if self.binary else 0)


def evaluate_lance_json(value: LanceJson, operation: Int, argument: String,
                       needle: String = String()) raises -> LanceJsonResult:
    var result = LanceJsonResult()
    if operation == 0:
        result.text = value.json_path(argument)
    elif operation == 1:
        result.text = value.extract(argument)
    elif operation == 2:
        var typed = value.extract_with_type(argument)
        if typed:
            result.binary = Optional(typed.value()[0].clone())
            result.type_tag = typed.value()[1]
    elif operation == 3:
        result.boolean = Optional(value.exists(argument))
    elif operation == 4:
        result.binary = value.get(argument)
    elif operation == 5:
        result.text = value.get_string(argument)
    elif operation == 6:
        result.integer = value.get_int(argument)
    elif operation == 7:
        result.floating = value.get_float(argument)
    elif operation == 8:
        result.boolean = value.get_bool(argument)
    elif operation == 9:
        result.boolean = Optional(value.array_contains(argument, needle))
    elif operation == 10:
        result.integer = value.array_length(argument)
    else:
        raise Error("unknown Lance JSON operation")
    return result^
