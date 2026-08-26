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


struct _FilterNode(Movable):
    var kind: UInt8
    var condition: Optional[FilterCondition]
    var children: List[Int]

    def __init__(
        out self,
        kind: UInt8,
        var condition: Optional[FilterCondition],
        var children: List[Int],
    ):
        self.kind = kind
        self.condition = condition^
        self.children = children^

    def clone_with_offset(self, offset: Int) raises -> _FilterNode:
        var condition = Optional[FilterCondition]()
        if Bool(self.condition):
            var cloned_condition = self.condition.value().clone()
            condition = Optional(cloned_condition^)
        var children = List[Int](capacity=len(self.children))
        for index in range(len(self.children)):
            children.append(self.children[index] + offset)
        return _FilterNode(self.kind, condition^, children^)


struct FilterExpression(Movable):
    """A bounded owned Boolean expression stored as a flat node arena."""

    comptime CONDITION = UInt8(1)
    comptime ALL = UInt8(2)
    comptime ANY = UInt8(3)
    comptime NEGATE = UInt8(4)
    comptime MAX_DEPTH = 16
    comptime MAX_NODES = 256

    var _nodes: List[_FilterNode]
    var _root: Int

    def __init__(
        out self,
        kind: UInt8,
        var condition: Optional[FilterCondition],
        var children: List[FilterExpression],
    ) raises:
        _validate_requested_shape(kind, condition, children)
        self._nodes = List[_FilterNode]()
        var root_children = List[Int](capacity=len(children))
        for index in range(len(children)):
            var offset = len(self._nodes)
            for node_index in range(len(children[index]._nodes)):
                self._nodes.append(
                    children[index]._nodes[node_index].clone_with_offset(offset)
                )
            root_children.append(children[index]._root + offset)
        self._nodes.append(_FilterNode(kind, condition^, root_children^))
        self._root = len(self._nodes) - 1
        self.validate()

    def __init__(out self, var nodes: List[_FilterNode], root: Int) raises:
        self._nodes = nodes^
        self._root = root
        self.validate()

    @staticmethod
    def condition(var condition: FilterCondition) raises -> FilterExpression:
        var optional = Optional(condition^)
        return FilterExpression(
            Self.CONDITION, optional^, List[FilterExpression]()
        )

    @staticmethod
    def all(var children: List[FilterExpression]) raises -> FilterExpression:
        var condition = Optional[FilterCondition]()
        return FilterExpression(Self.ALL, condition^, children^)

    @staticmethod
    def any(var children: List[FilterExpression]) raises -> FilterExpression:
        var condition = Optional[FilterCondition]()
        return FilterExpression(Self.ANY, condition^, children^)

    @staticmethod
    def negate(var child: FilterExpression) raises -> FilterExpression:
        var children = List[FilterExpression]()
        children.append(child^)
        var condition = Optional[FilterCondition]()
        return FilterExpression(Self.NEGATE, condition^, children^)

    def kind(self) -> UInt8:
        return self._nodes[self._root].kind

    def child_count(self) -> Int:
        return len(self._nodes[self._root].children)

    def get_condition(self) raises -> Optional[FilterCondition]:
        return self._get_node_condition(self._root)

    def get_child_condition(
        self, child_index: Int
    ) raises -> Optional[FilterCondition]:
        if child_index < 0 or child_index >= self.child_count():
            raise Error("filter child index out of bounds")
        return self._get_node_condition(
            self._nodes[self._root].children[child_index]
        )

    def node_count(self) -> Int:
        return len(self._nodes)

    def depth(self) -> Int:
        var depths = List[Int](capacity=len(self._nodes))
        for node_index in range(len(self._nodes)):
            var maximum_child_depth = 0
            for child_index in range(self._node_child_count(node_index)):
                var child_depth = depths[
                    self._node_child(node_index, child_index)
                ]
                if child_depth > maximum_child_depth:
                    maximum_child_depth = child_depth
            depths.append(maximum_child_depth + 1)
        return depths[self._root]

    def validate(self) raises:
        if self._root < 0 or self._root >= len(self._nodes):
            raise Error("filter expression root is out of bounds")
        for node_index in range(len(self._nodes)):
            _validate_expression_node(self, node_index)
        if self.depth() > Self.MAX_DEPTH:
            raise Error("filter expression exceeds maximum depth")
        if self.node_count() > Self.MAX_NODES:
            raise Error("filter expression exceeds maximum node count")

    def clone(self) raises -> FilterExpression:
        var nodes = List[_FilterNode](capacity=len(self._nodes))
        for index in range(len(self._nodes)):
            nodes.append(self._nodes[index].clone_with_offset(0))
        return FilterExpression(nodes^, self._root)

    def _get_node_condition(
        self, node_index: Int
    ) raises -> Optional[FilterCondition]:
        if not Bool(self._nodes[node_index].condition):
            return Optional[FilterCondition]()
        var condition = self._nodes[node_index].condition.value().clone()
        return Optional(condition^)

    def _node_kind(self, node_index: Int) -> UInt8:
        return self._nodes[node_index].kind

    def _node_child_count(self, node_index: Int) -> Int:
        return len(self._nodes[node_index].children)

    def _node_child(self, node_index: Int, child_index: Int) -> Int:
        return self._nodes[node_index].children[child_index]

    def _root_index(self) -> Int:
        return self._root


def _validate_requested_shape(
    kind: UInt8,
    condition: Optional[FilterCondition],
    children: List[FilterExpression],
) raises:
    if kind < FilterExpression.CONDITION or kind > FilterExpression.NEGATE:
        raise Error("unknown filter expression kind")
    if kind == FilterExpression.CONDITION:
        if not Bool(condition) or len(children) != 0:
            raise Error("condition expression has invalid shape")
        condition.value().validate()
        return
    if Bool(condition):
        raise Error("Boolean expression cannot contain a direct condition")
    if kind == FilterExpression.NEGATE and len(children) != 1:
        raise Error("negate expression requires exactly one child")


def _validate_expression_node(
    expression: FilterExpression, node_index: Int
) raises:
    if node_index < 0 or node_index >= expression.node_count():
        raise Error("filter expression child is out of bounds")
    var kind = expression._node_kind(node_index)
    var child_count = expression._node_child_count(node_index)
    var condition = expression._get_node_condition(node_index)
    if kind < FilterExpression.CONDITION or kind > FilterExpression.NEGATE:
        raise Error("unknown filter expression kind")
    if kind == FilterExpression.CONDITION:
        if not Bool(condition) or child_count != 0:
            raise Error("condition expression has invalid shape")
        condition.value().validate()
        return
    if Bool(condition):
        raise Error("Boolean expression cannot contain a direct condition")
    if kind == FilterExpression.NEGATE and child_count != 1:
        raise Error("negate expression requires exactly one child")
    for index in range(child_count):
        var child = expression._node_child(node_index, index)
        if child < 0 or child >= node_index:
            raise Error("filter expression child ordering is invalid")
