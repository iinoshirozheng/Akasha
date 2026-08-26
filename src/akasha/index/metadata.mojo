from akasha.document.record import (
    clone_fields,
    DocumentField,
    validate_fields,
)
from akasha.index.bitmap import Bitmap
from akasha.index.keyword import KeywordIndex
from akasha.index.sorted_block import SortedBlockIndex
from akasha.query.filter_ast import FilterCondition
from std.collections import Dict


struct MetadataIndex:
    """Derived typed metadata index addressed by stable point ordinals."""

    var _ids: List[Int]
    var _ordinals: Dict[Int, Int]
    var _fields: List[List[DocumentField]]
    var _live: Bitmap
    var _keywords: KeywordIndex
    var _numbers: SortedBlockIndex
    var _bulk_loading: Bool

    def __init__(out self) raises:
        self._ids = List[Int]()
        self._ordinals = Dict[Int, Int]()
        self._fields = List[List[DocumentField]]()
        self._live = Bitmap()
        self._keywords = KeywordIndex()
        self._numbers = SortedBlockIndex()
        self._bulk_loading = False

    def slot_count(self) -> Int:
        return len(self._ids)

    def live_count(self) -> Int:
        return self._live.count()

    def id_at(self, ordinal: Int) raises -> Int:
        self._validate_ordinal(ordinal)
        return self._ids[ordinal]

    def ordinal_for(self, id: Int) raises -> Int:
        if id in self._ordinals:
            return self._ordinals[id]
        return -1

    def live_universe(self) raises -> Bitmap:
        return self._live.clone()

    def begin_bulk(mut self) raises:
        if self._bulk_loading or self.slot_count() != 0:
            raise Error("metadata bulk load requires an empty index")
        self._keywords.begin_bulk()
        self._numbers.begin_bulk()
        self._bulk_loading = True

    def finish_bulk(mut self) raises:
        if not self._bulk_loading:
            raise Error("metadata bulk load is not active")
        self._keywords.finish_bulk()
        self._numbers.finish_bulk()
        self._bulk_loading = False

    def upsert(mut self, id: Int, var fields: List[DocumentField]) raises:
        validate_fields(fields)
        var ordinal = self.ordinal_for(id)
        if self._bulk_loading and ordinal >= 0:
            raise Error("metadata bulk load requires unique point IDs")
        if ordinal < 0:
            ordinal = self._append_slot(id)
        else:
            self._remove_fields(ordinal)

        for index in range(len(fields)):
            self._add_field(ordinal, fields[index])
        self._fields[ordinal] = fields^
        self._live.set(ordinal)

    def delete(mut self, id: Int) raises:
        var ordinal = self.ordinal_for(id)
        if ordinal < 0:
            _ = self._append_slot(id)
            return
        self._remove_fields(ordinal)
        self._fields[ordinal] = List[DocumentField]()
        self._live.clear(ordinal)

    def evaluate_condition(self, condition: FilterCondition) raises -> Bitmap:
        condition.validate()
        var candidates: Bitmap
        if condition.value.is_string() or condition.value.is_boolean():
            candidates = self._keywords.evaluate(condition)
        elif condition.value.is_integer() or condition.value.is_floating():
            candidates = self._numbers.evaluate(condition)
        else:
            raise Error("unknown metadata index value kind")
        return self._live.intersection(candidates)

    def contains_id(self, candidates: Bitmap, id: Int) raises -> Bool:
        if candidates.size() != self.slot_count():
            raise Error("candidate bitmap does not match metadata index")
        var ordinal = self.ordinal_for(id)
        if ordinal < 0:
            return False
        return candidates.contains(ordinal)

    def _append_slot(mut self, id: Int) raises -> Int:
        var ordinal = len(self._ids)
        self._ids.append(id)
        self._ordinals[id] = ordinal
        var empty = List[DocumentField]()
        self._fields.append(empty^)
        var size = len(self._ids)
        self._live.resize(size)
        self._keywords.resize(size)
        self._numbers.resize(size)
        return ordinal

    def _add_field(mut self, ordinal: Int, field: DocumentField) raises:
        if field.value.is_string() or field.value.is_boolean():
            self._keywords.add(field.name, field.value, ordinal)
        else:
            self._numbers.add(field.name, field.value, ordinal)

    def _remove_fields(mut self, ordinal: Int) raises:
        for index in range(len(self._fields[ordinal])):
            if (
                self._fields[ordinal][index].value.is_string()
                or self._fields[ordinal][index].value.is_boolean()
            ):
                self._keywords.remove(
                    self._fields[ordinal][index].name,
                    self._fields[ordinal][index].value,
                    ordinal,
                )
            else:
                self._numbers.remove(
                    self._fields[ordinal][index].name,
                    self._fields[ordinal][index].value,
                    ordinal,
                )

    def _validate_ordinal(self, ordinal: Int) raises:
        if ordinal < 0 or ordinal >= len(self._ids):
            raise Error("metadata ordinal out of bounds")


def build_metadata_index(
    ids: List[Int], tombstones: List[Bool], fields: List[List[DocumentField]]
) raises -> MetadataIndex:
    """Build derived metadata state in the supplied stable slot order."""
    if len(ids) != len(tombstones) or len(ids) != len(fields):
        raise Error("metadata recovery columns must have equal lengths")
    var index = MetadataIndex()
    index.begin_bulk()
    for ordinal in range(len(ids)):
        if tombstones[ordinal]:
            index.delete(ids[ordinal])
        else:
            var owned = clone_fields(fields[ordinal])
            index.upsert(ids[ordinal], owned^)
    index.finish_bulk()
    return index^
