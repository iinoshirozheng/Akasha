"""Qdrant identity/vector/slice predicates and explicit point context.

types.rs and payload_storage/query_checker.rs at
74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
"""
from akasha.compute.siphash import slice_numeric_id_hash
from akasha.document.value import PayloadValue
from akasha.document.vector_schema import FieldCatalog
from akasha.query.payload_condition import _required, _known_keys, _uint, _i64
from std.memory import ArcPointer


struct PointFilterContext(Copyable, Movable):
    var id: Optional[Int]
    var vector_ids: List[Int]
    var catalog: Optional[ArcPointer[FieldCatalog]]

    def __init__(out self, id: Optional[Int] = None, var vector_ids: List[Int] = [],
                 var catalog: Optional[ArcPointer[FieldCatalog]] = None):
        self.id = id
        self.vector_ids = vector_ids^
        self.catalog = catalog^


struct PointCondition(Copyable, Movable):
    comptime IDS = UInt8(1)
    comptime VECTOR = UInt8(2)
    comptime SLICE = UInt8(3)
    var kind: UInt8
    var ids: Dict[Int, Bool]
    var vector_name: String
    var vector_id: Optional[Int]
    var total: UInt32
    var index: UInt32

    def __init__(out self, spec: PayloadValue) raises:
        var kind = _required(spec, "kind").as_string()
        self.ids = Dict[Int, Bool]()
        self.vector_name = ""
        self.vector_id = None
        self.total = 1
        self.index = 0
        if kind == "has_id":
            _known_keys(spec, ["kind", "ids"])
            self.kind = Self.IDS
            var values = _required(spec, "ids")
            if not values.is_array():
                raise Error("has_id requires an array of native Int64 point IDs")
            var items = values.children()
            for i in range(len(items)):
                var id = _i64(items[i])
                if not id:
                    raise Error("has_id requires native Int64 point IDs")
                self.ids[Int(id.value())] = True
        elif kind == "has_vector":
            _known_keys(spec, ["kind", "name", "field_id"])
            self.kind = Self.VECTOR
            var name = spec.get_key("name")
            var id = spec.get_key("field_id")
            if Bool(name) == Bool(id):
                raise Error("has_vector requires exactly one name or native field_id")
            if name:
                self.vector_name = name.value().as_string()
            else:
                var value = _uint(id.value())
                if value > UInt64(UInt32.MAX):
                    raise Error("vector field_id must fit UInt32")
                self.vector_id = Optional(Int(value))
        elif kind == "slice":
            _known_keys(spec, ["kind", "total", "index"])
            self.kind = Self.SLICE
            var total = _uint(_required(spec, "total"))
            var index = _uint(_required(spec, "index"))
            if total == 0 or total > UInt64(UInt32.MAX) or index >= total:
                raise Error("slice requires UInt32 total > 0 and index < total")
            self.total = UInt32(total)
            self.index = UInt32(index)
        else:
            raise Error("unknown point condition")

    def validate(self) raises:
        if self.kind < Self.IDS or self.kind > Self.SLICE:
            raise Error("unknown point condition")
        if len(self.ids) > 65_536:
            raise Error("has_id exceeds point ID resource limit")
        if self.kind == Self.SLICE and (self.total == 0 or self.index >= self.total):
            raise Error("slice requires index < nonzero total")
        if self.vector_id and (self.vector_id.value() < 0 or UInt64(self.vector_id.value()) > UInt64(UInt32.MAX)):
            raise Error("vector field_id must fit UInt32")

    def check(self, context: PointFilterContext) raises -> Bool:
        if self.kind != Self.VECTOR and not context.id:
            return False
        if self.kind == Self.IDS:
            return context.id.value() in self.ids
        if self.kind == Self.SLICE:
            return slice_numeric_id_hash(UInt64(context.id.value())) % UInt64(self.total) == UInt64(self.index)
        var id = -1
        if self.vector_id:
            id = self.vector_id.value()
        elif self.vector_name == "":
            id = 0
        elif context.catalog:
            var ordinal = context.catalog.value()[].named_ordinal(self.vector_name)
            if ordinal >= 0:
                id = context.catalog.value()[].field_at(ordinal).id
        if id < 0:
            return False
        for present in context.vector_ids:
            if present == id:
                return True
        return False
