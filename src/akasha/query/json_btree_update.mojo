"""Reconcile snapshot ordinals before reusing immutable JSON B-tree values."""
from std.memory import ArcPointer
from akasha.storage.read_generation import ReadGeneration
from akasha.index.json_scalar_index import JsonScalarIndex
from akasha.index.lance_json_btree import LanceJsonBTreeIndex, LanceJsonBTreeTrainer
from akasha.document.jsonb import JsonbValue
from akasha.storage.json_bitmap_cache import _source_checksum
from akasha.query.control import QueryControl


@fieldwise_init
struct JsonBTreeUpdateBase(Copyable, Movable):
    # One collection-owned baseline, not a chain of preceding roots.
    var root: ArcPointer[ReadGeneration]
    var index: ArcPointer[JsonScalarIndex]

    def matches(self, column: String, path: String, target: UInt8) -> Bool:
        ref pages = self.index[]._data[LanceJsonBTreeIndex]._btree.pages
        return pages.column == column and pages.path == path and pages.lookup.target == target


def _value(root: ReadGeneration, location: Tuple[Int, Int], column: String) raises -> Optional[JsonbValue]:
    ref fields = root.run(location[0]).memtable.entry_ref_at(location[1]).fields()
    for slot in range(len(fields)):
        ref field = fields[slot]
        if field.name == column:
            if field.value.is_null():
                return None
            if not field.value.is_jsonb():
                raise Error("JSON index requires a JSONB payload value")
            return Optional(field.value.as_jsonb())
    return None


def update_snapshot_json_btree(base: JsonBTreeUpdateBase, root: ReadGeneration,
                               locations: List[Tuple[Int, Int]], column: String,
                               control: Optional[QueryControl]) raises -> JsonScalarIndex:
    ref old = base.index[]._data[LanceJsonBTreeIndex]
    if len(locations) > 1_000_000:
        raise Error("JSON B-tree trainer row limit exceeded")
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(len(locations))
    var prior = base.root[].id_ordered_locations()
    var mapping = Dict[UInt64, Optional[UInt64]]()
    var trainer = LanceJsonBTreeTrainer(old._btree.pages.path.copy(),
        learned_type=Optional(old.target()), control=control.copy())
    var values = List[Optional[JsonbValue]]()
    var ids = List[UInt64]()
    var previous = 0
    for row in range(len(locations)):
        if control:
            control.value().checkpoint(row)
        var location = locations[row]
        var id = root.run(location[0]).memtable.entry_ref_at(location[1]).id
        while previous < len(prior):
            var location_before = prior[previous]
            var id_before = base.root[].run(location_before[0]).memtable.entry_ref_at(location_before[1]).id
            if id_before >= id:
                break
            mapping[UInt64(previous)] = None
            previous += 1
        var current = _value(root, location, column)
        var reused = False
        if previous < len(prior):
            var location_before = prior[previous]
            if base.root[].run(location_before[0]).memtable.entry_ref_at(location_before[1]).id == id:
                var before = _value(base.root[], location_before, column)
                reused = Bool(before) == Bool(current)
                if reused and current:
                    reused = before.value()._data == current.value()._data
                mapping[UInt64(previous)] = Optional(UInt64(row)) if reused else None
                previous += 1
        if not reused:
            values.append(current^)
            ids.append(UInt64(row))
            if len(values) == 1024:
                trainer.push(values, ids)
                values.clear()
                ids.clear()
    while previous < len(prior):
        if control:
            control.value().checkpoint(previous)
        mapping[UInt64(previous)] = None
        previous += 1
    if len(values):
        trainer.push(values, ids)
    var checksum = _source_checksum(root, locations, column, old._btree.pages.path, old.target(), control)
    var remapped = LanceJsonBTreeIndex(old._btree.remapped(mapping,
        sequence=root.sequence, source_checksum=checksum, control=control.copy()))
    return JsonScalarIndex(trainer.finish_update(remapped, root.sequence, checksum))
