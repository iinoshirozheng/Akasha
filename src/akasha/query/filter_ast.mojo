from akasha.document.record import validate_field_name
from akasha.document.value import PayloadValue


struct FilterCondition(Movable):
    """One validated strict typed field comparison."""

    comptime EQUAL = UInt8(1)
    comptime NOT_EQUAL = UInt8(2)
    comptime LESS_THAN = UInt8(3)
    comptime LESS_OR_EQUAL = UInt8(4)
    comptime GREATER_THAN = UInt8(5)
    comptime GREATER_OR_EQUAL = UInt8(6)

    var name: String
    var _operator_kind: UInt8
    var value: PayloadValue

    def __init__(
        out self,
        name: String,
        operator_kind: UInt8,
        var value: PayloadValue,
    ) raises:
        _validate_condition(name, operator_kind, value)
        self.name = String(copy=name)
        self._operator_kind = operator_kind
        self.value = value^

    @staticmethod
    def equal(name: String, var value: PayloadValue) raises -> FilterCondition:
        return FilterCondition(name, Self.EQUAL, value^)

    @staticmethod
    def not_equal(
        name: String, var value: PayloadValue
    ) raises -> FilterCondition:
        return FilterCondition(name, Self.NOT_EQUAL, value^)

    @staticmethod
    def less_than(
        name: String, var value: PayloadValue
    ) raises -> FilterCondition:
        return FilterCondition(name, Self.LESS_THAN, value^)

    @staticmethod
    def less_or_equal(
        name: String, var value: PayloadValue
    ) raises -> FilterCondition:
        return FilterCondition(name, Self.LESS_OR_EQUAL, value^)

    @staticmethod
    def greater_than(
        name: String, var value: PayloadValue
    ) raises -> FilterCondition:
        return FilterCondition(name, Self.GREATER_THAN, value^)

    @staticmethod
    def greater_or_equal(
        name: String, var value: PayloadValue
    ) raises -> FilterCondition:
        return FilterCondition(name, Self.GREATER_OR_EQUAL, value^)

    def operator_kind(self) -> UInt8:
        return self._operator_kind

    def validate(self) raises:
        _validate_condition(self.name, self._operator_kind, self.value)

    def clone(self) raises -> FilterCondition:
        return FilterCondition(
            self.name,
            self._operator_kind,
            self.value.clone(),
        )


def _validate_condition(
    name: String, operator_kind: UInt8, value: PayloadValue
) raises:
    validate_field_name(name)
    if (
        operator_kind < FilterCondition.EQUAL
        or operator_kind > FilterCondition.GREATER_OR_EQUAL
    ):
        raise Error("unknown filter operator")
    if not (
        value.is_string()
        or value.is_integer()
        or value.is_floating()
        or value.is_boolean()
    ):
        raise Error("unknown filter value kind")
    if operator_kind >= FilterCondition.LESS_THAN and (
        value.is_string() or value.is_boolean()
    ):
        raise Error("range filters require an integer or float value")
