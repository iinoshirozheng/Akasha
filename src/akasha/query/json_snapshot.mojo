"""Prepared JSON queries whose indexes and residuals share one immutable root."""
from std.memory import ArcPointer
from std.utils import BlockingScopedLock
from akasha.storage.read_generation import ReadGeneration
from akasha.query.json_expression import JsonExpression
from akasha.query.control import QueryControl
from akasha.index.lance_json_stream import LanceJsonBitmapTrainer, LanceJsonBitmapIndex
from akasha.index.nullable_rows import NullableRowMask
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_path import JsonbPath
from akasha.document.record import validate_field_name


struct JsonIndexRequest(Copyable, Movable):
    var column: String
    var path: String
    var learned_type: Optional[UInt8]

    def __init__(out self, var column: String, var path: String, learned_type: Optional[UInt8] = None):
        self.column = column^
        self.path = path^
        self.learned_type = learned_type


def build_snapshot_json_index(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                              request: JsonIndexRequest, control: Optional[QueryControl] = None) raises -> LanceJsonBitmapIndex:
    validate_field_name(request.column)
    _ = JsonbPath.parse(request.path)
    var trainer = LanceJsonBitmapTrainer(request.path.copy(), learned_type=request.learned_type, control=control.copy())
    var values = List[Optional[JsonbValue]]()
    var ids = List[UInt64]()
    for row in range(len(locations)):
        if control:
            control.value().checkpoint(row)
        var location = locations[row]
        ref fields = root.run(location[0]).memtable.entry_ref_at(location[1]).fields()
        var value = Optional[JsonbValue]()
        for field_slot in range(len(fields)):
            ref field = fields[field_slot]
            if field.name == request.column:
                if not field.value.is_null():
                    if not field.value.is_jsonb():
                        raise Error("JSON index requires a JSONB payload value")
                    value = Optional(field.value.as_jsonb())
                break
        values.append(value^)
        ids.append(UInt64(row))
        if len(values) == 1024:
            trainer.push(values, ids)
            values.clear()
            ids.clear()
    if len(values) != 0:
        trainer.push(values, ids)
    return trainer.finish()



def snapshot_json_artifact(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                           request: JsonIndexRequest, control: Optional[QueryControl] = None,
                           rebuild: Bool = False) raises -> ArcPointer[LanceJsonBitmapIndex]:
    var target = Int(request.learned_type.value()) if request.learned_type else 0
    var state = root.json_indexes[].get(request.column, request.path, target)
    with BlockingScopedLock(state[].lock):
        if control:
            control.value().checkpoint(0)
            control.value().validate_candidate_count(len(locations))
        if state[].ready and not rebuild:
            return state[].ready.value().copy()
        try:
            state[].begin()
            var built = ArcPointer(build_snapshot_json_index(root, locations, request, control))
            if control:
                control.value().checkpoint(0)
            if rebuild and state[].ready:
                state[].ready = Optional(built.copy())
                state[].status = 2
                state[].build_count += 1
            else:
                state[].publish(built.copy())
            return built^
        except error:
            state[].fail(String(error))
            if state[].ready:
                state[].status = 2
            raise error^


struct PreparedJsonQuery(Movable):
    var _root: ArcPointer[ReadGeneration]
    var _expression: JsonExpression
    var _locations: List[Tuple[Int, Int]]
    var _masks: List[Optional[NullableRowMask]]

    def __init__(out self, var root: ArcPointer[ReadGeneration], var expression: JsonExpression,
                 indexes: List[JsonIndexRequest], control: Optional[QueryControl] = None) raises:
        if len(indexes) > 256:
            raise Error("JSON query index count limit exceeded")
        if control:
            control.value().checkpoint(0)
        expression.validate()
        self._root = root^
        self._expression = expression^
        self._locations = self._root[].id_ordered_locations()
        if control:
            control.value().validate_candidate_count(len(self._locations))
        self._masks = List[Optional[NullableRowMask]]()
        for _ in range(len(self._expression._nodes)):
            self._masks.append(None)
        for request in indexes:
            var index = snapshot_json_artifact(self._root[], self._locations, request, control)
            for slot in range(len(self._expression._nodes)):
                ref node = self._expression._nodes[slot]
                if node.kind != 0:
                    continue
                ref projection = node.projection.value()
                if projection.source != request.column or len(projection.calls) != 1:
                    continue
                # A mask must not suppress a caller-requested JSON work error.
                if projection.max_work != 1_000_000 or projection.max_results != 65_536 or projection.max_bytes != 64 * 1024 * 1024:
                    continue
                # Empty SQL IN is false even on null. Raw target masks carry
                # nulls, which would change a surrounding NOT.
                if node.query.kind == 2 and len(node.query.values) == 0:
                    continue
                var op = projection.operation()
                var name = "json_get_int" if op == 6 else "json_get_float" if op == 7 else "json_get_bool" if op == 8 else "json_get_string" if op == 5 else ""
                if name == "":
                    continue
                self._masks[slot] = index[].try_search(name, projection.calls[0].argument,
                    node.query, control=control.copy())

    def indexed_leaf_count(self) -> Int:
        var count = 0
        for mask in self._masks:
            if mask:
                count += 1
        return count

    def execute(self, control: Optional[QueryControl] = None) raises -> List[Int]:
        if control:
            control.value().checkpoint(0)
            control.value().validate_candidate_count(len(self._locations))
        var result = List[Int]()
        for row in range(len(self._locations)):
            if control:
                control.value().checkpoint(row)
            var location = self._locations[row]
            ref entry = self._root[].run(location[0]).memtable.entry_ref_at(location[1])
            var truth = self._expression._evaluate(len(self._expression._nodes)-1,
                entry.fields(), self._masks, UInt64(row), control)
            if truth:
                if truth.value():
                    result.append(entry.id)
        return result^
