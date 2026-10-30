"""JSONB boolean functions in Akasha's existing collection filter contract.

Composition of the source-ported jsonb selector and Lance JSON consumers;
their source revisions and licenses are recorded in docs/upstream/ports.json.
This leaf is an Akasha API, not a Qdrant wire condition or SQL evaluator.
"""
from akasha.document.json_path import JsonPath
from akasha.document.jsonb_path import JsonbPath
from akasha.document.lance_json import LanceJson
from akasha.document.value import PayloadValue
from akasha.query.payload_condition import _required, _known_keys, _i64


def _limit(spec: PayloadValue, name: String, default: Int) raises -> Int:
    var value = spec.get_key(name)
    if not value:
        return default
    var number = _i64(value.value())
    if not number or number.value() <= 0:
        raise Error("JSONB filter limits require positive Int64 integers")
    return Int(number.value())


struct JsonbCondition(Copyable, Movable):
    var key: JsonPath
    var function: String
    var argument: String
    var needle: Optional[String]
    var max_work: Int
    var max_results: Int
    var max_bytes: Int

    def __init__(out self, key: String, function: String, argument: String, *,
                 var needle: Optional[String] = None, max_work: Int = 1_000_000,
                 max_results: Int = 65_536, max_bytes: Int = 64 * 1024 * 1024) raises:
        self.key = JsonPath.parse(key)
        self.function = function
        self.argument = argument
        self.needle = needle^
        self.max_work = max_work
        self.max_results = max_results
        self.max_bytes = max_bytes
        self.validate()

    def __init__(out self, spec: PayloadValue) raises:
        _known_keys(spec, ["kind", "key", "function", "argument", "needle",
                           "max_work", "max_results", "max_bytes"])
        if _required(spec, "kind").as_string() != "jsonb":
            raise Error("JSONB condition requires kind=jsonb")
        var needle = Optional[String]()
        var supplied = spec.get_key("needle")
        if supplied:
            needle = Optional(supplied.value().as_string())
        self = Self(_required(spec, "key").as_string(),
                    _required(spec, "function").as_string(),
                    _required(spec, "argument").as_string(), needle=needle^,
                    max_work=_limit(spec, "max_work", 1_000_000),
                    max_results=_limit(spec, "max_results", 65_536),
                    max_bytes=_limit(spec, "max_bytes", 64 * 1024 * 1024))

    def validate(self) raises:
        if (self.function != "predicate_match" and self.function != "json_exists"
                and self.function != "json_array_contains" and self.function != "json_get_bool"):
            raise Error("unknown JSONB filter function")
        if Bool(self.needle) != (self.function == "json_array_contains"):
            raise Error("only json_array_contains requires a needle string")
        if self.max_work <= 0 or self.max_results <= 0 or self.max_bytes <= 0:
            raise Error("JSONB filter limits require positive Int64 integers")
        if (self.argument.byte_length() > JsonbPath.MAX_BYTES
                or (self.needle and self.needle.value().byte_length() > JsonbPath.MAX_BYTES)):
            raise Error("JSONB filter argument byte resource limit exceeded")
        # Configuration errors are eager even for empty/null-only collections.
        # get_bool uses an exact key/index, which may be the empty string.
        if self.function != "json_get_bool":
            _ = JsonbPath.parse(self.argument)

    def check(self, stored: PayloadValue) raises -> Bool:
        if stored.is_null():
            return False
        if not stored.is_jsonb():
            raise Error("JSONB filter requires a JSONB payload value")
        var consumer = LanceJson(stored.as_jsonb(), max_work=self.max_work,
                                 max_results=self.max_results, max_bytes=self.max_bytes)
        if self.function == "json_exists":
            return consumer.exists(self.argument)
        if self.function == "json_array_contains":
            return consumer.array_contains(self.argument, self.needle.value())
        var result: Optional[Bool]
        if self.function == "json_get_bool":
            result = consumer.get_bool(self.argument)
        else:
            result = consumer.selector.predicate_match(JsonbPath.parse(self.argument))
        return result.value() if result else False
