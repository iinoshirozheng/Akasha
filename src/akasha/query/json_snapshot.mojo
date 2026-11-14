"""Prepared JSON queries whose indexes and residuals share one immutable root."""
from std.memory import ArcPointer
from std.utils import BlockingScopedLock
from akasha.storage.read_generation import ReadGeneration
from akasha.storage.json_bitmap_cache import load_json_bitmap_shard, _source_checksum
from akasha.storage.json_bitmap_shards import stage_json_bitmap, merge_json_bitmap_shards, JSON_SHARD_ROWS
from akasha.storage.index_cache import MappedCacheArtifact
from akasha.index.json_scalar_index import JsonScalarIndex
from akasha.index.lance_json_btree import LanceJsonBTreeTrainer
from akasha.storage.json_scalar_cache import load_json_scalar_cache
from akasha.index.lance_json_input import extract_json_index_batch, infer_json_index_type
from akasha.query.json_expression import JsonExpression
from akasha.query.control import QueryControl
from akasha.index.lance_json_stream import LanceJsonBitmapTrainer, LanceJsonBitmapIndex
from akasha.index.nullable_rows import NullableRowMask
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_path import JsonbPath
from akasha.document.record import validate_field_name
from akasha.query.json_btree_update import JsonBTreeUpdateBase, update_snapshot_json_btree


struct JsonIndexRequest(Copyable, Movable):
    var column: String
    var path: String
    var learned_type: Optional[UInt8]
    var kind: UInt8

    def __init__(out self, var column: String, var path: String, learned_type: Optional[UInt8] = None, kind: UInt8 = 1):
        self.column = column^
        self.path = path^
        self.learned_type = learned_type
        self.kind = kind


def _build_snapshot_json_chunk(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                              request: JsonIndexRequest, control: Optional[QueryControl] = None) raises -> LanceJsonBitmapIndex:
    validate_field_name(request.column)
    _ = JsonbPath.parse(request.path)
    var trainer = LanceJsonBitmapTrainer(request.path.copy(), learned_type=request.learned_type, control=control.copy(),
        sort_memory_bytes=Optional(8 * 1024 * 1024))
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



def _build_snapshot_json_bitmap(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                              request: JsonIndexRequest, control: Optional[QueryControl] = None) raises -> LanceJsonBitmapIndex:
    validate_field_name(request.column)
    _ = JsonbPath.parse(request.path)
    if len(locations) > 1_000_000:
        raise Error("JSON bitmap trainer row limit exceeded")
    if control:
        control.value().validate_candidate_count(len(locations))
        control.value().checkpoint(0)
    var target = request.learned_type
    if not target:
        # Infer once globally before building shards; an all-null first shard
        # must not prematurely fix Utf8 when later shards contain numbers.
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
            var batch = extract_json_index_batch([value^], request.path, control=control.copy())
            target = infer_json_index_type(batch, request.path, control=control.copy())
            if target:
                break
    if not target:
        target = Optional(UInt8(4))
    var fixed = JsonIndexRequest(request.column.copy(), request.path.copy(), target)
    var shards = List[ArcPointer[MappedCacheArtifact]]()
    var slot = 0
    var staged_bytes = 0
    while slot == 0 or slot * JSON_SHARD_ROWS < len(locations):
        var chunk = List[Tuple[Int, Int]]()
        var start = slot * JSON_SHARD_ROWS
        var end = min(start + JSON_SHARD_ROWS, len(locations))
        for row in range(start, end):
            chunk.append(locations[row])
        var checksum = _source_checksum(root, chunk, request.column, request.path, target.value(), control)
        var shard = load_json_bitmap_shard(root, request.column, request.path, target.value(),
            slot, len(chunk), checksum, control)
        if not shard:
            var index = _build_snapshot_json_chunk(root, chunk, fixed, control)
            shard = Optional(stage_json_bitmap(request.column, index, root.config.dimension,
                UInt64(slot + 1), 0, checksum, control))
        staged_bytes += shard.value()[]._mapping.byte_length()
        if staged_bytes > 512 * 1024 * 1024:
            raise Error("JSON bitmap shard staging byte limit exceeded")
        shards.append(shard.take())
        slot += 1
    var checksum = _source_checksum(root, locations, request.column, request.path, target.value(), control)
    return merge_json_bitmap_shards(shards, request.column, request.path, target.value(),
        root.config.dimension, root.sequence, checksum, control)


def build_snapshot_json_index(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                              request: JsonIndexRequest, control: Optional[QueryControl] = None) raises -> JsonScalarIndex:
    if request.kind == 1:
        return JsonScalarIndex(_build_snapshot_json_bitmap(root, locations, request, control))
    if request.kind != 2:
        raise Error("unsupported JSON index kind")
    validate_field_name(request.column)
    _ = JsonbPath.parse(request.path)
    if len(locations) > 1_000_000:
        raise Error("JSON B-tree trainer row limit exceeded")
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(len(locations))
    var trainer = LanceJsonBTreeTrainer(request.path.copy(), learned_type=request.learned_type, control=control.copy())
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
    var target = trainer.learned_type().value() if trainer.learned_type() else UInt8(4)
    var checksum = _source_checksum(root, locations, request.column, request.path, target, control)
    return JsonScalarIndex(trainer.finish(request.column, root.config.dimension, root.sequence, checksum))


def snapshot_json_artifact(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                           request: JsonIndexRequest, control: Optional[QueryControl] = None,
                           rebuild: Bool = False,
                           base: Optional[JsonBTreeUpdateBase] = None) raises -> ArcPointer[JsonScalarIndex]:
    var target = Int(request.learned_type.value()) if request.learned_type else 0
    var state = root.json_indexes[].get(request.column, request.path, target, request.kind)
    with BlockingScopedLock(state[].lock):
        if control:
            control.value().checkpoint(0)
            control.value().validate_candidate_count(len(locations))
        if state[].ready and not rebuild:
            return state[].ready.value().copy()
        if not rebuild and request.learned_type:
            var cached = load_json_scalar_cache(root, locations, request.column, request.path,
                request.learned_type.value(), request.kind, control)
            if cached:
                var loaded = ArcPointer(cached.take())
                state[].publish(loaded.copy())
                return loaded^
        try:
            state[].begin()
            var built: ArcPointer[JsonScalarIndex]
            if rebuild and request.kind == 2 and request.learned_type and base and base.value().matches(request.column, request.path, request.learned_type.value()):
                built = ArcPointer(update_snapshot_json_btree(base.value(), root, locations, request.column, control))
            else:
                built = ArcPointer(build_snapshot_json_index(root, locations, request, control))
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
                if request.kind == 1 and node.query.kind == 2 and len(node.query.values) == 0:
                    continue
                var op = projection.operation()
                var name = "json_get_int" if op == 6 else "json_get_float" if op == 7 else "json_get_bool" if op == 8 else "json_get_string" if op == 5 else ""
                if name == "":
                    continue
                var mask = index[].try_search(name, projection.calls[0].argument,
                    node.query, control=control.copy())
                if mask:
                    self._masks[slot] = mask^

    def indexed_leaf_count(self) -> Int:
        var count = 0
        for mask in self._masks:
            if mask:
                count += 1
        return count

    def matches_row(self, row: Int, control: Optional[QueryControl] = None) raises -> Bool:
        if row < 0 or row >= len(self._locations):
            raise Error("JSON query row is outside snapshot")
        var location = self._locations[row]
        ref entry = self._root[].run(location[0]).memtable.entry_ref_at(location[1])
        var truth = self._expression._evaluate(len(self._expression._nodes)-1,
            entry.fields(), self._masks, UInt64(row), control)
        return truth.value() if truth else False

    def matches_id(self, id: Int, control: Optional[QueryControl] = None) raises -> Bool:
        """Resolve a visible physical row to this root's bitmap ordinal."""
        var low = 0
        var high = len(self._locations)
        while low < high:
            var middle = low + (high-low)//2
            var location = self._locations[middle]
            var candidate = self._root[].run(location[0]).memtable.entry_ref_at(location[1]).id
            if candidate < id:
                low = middle + 1
            else:
                high = middle
        if low == len(self._locations):
            raise Error("JSON query ID is outside snapshot")
        var location = self._locations[low]
        if self._root[].run(location[0]).memtable.entry_ref_at(location[1]).id != id:
            raise Error("JSON query ID is outside snapshot")
        return self.matches_row(low, control)

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
            if self.matches_row(row, control):
                result.append(entry.id)
        return result^
