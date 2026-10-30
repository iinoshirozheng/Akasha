"""Connect source point predicates to authoritative vector presence and IDs."""
from akasha.document.point_state import PointField, PointState
from akasha.document.vector_schema import FieldCatalog
from akasha.index.bitmap import Bitmap
from akasha.index.metadata import MetadataIndex
from akasha.query.evaluator import matches_expression
from akasha.query.filter_ast import FilterExpression
from akasha.query.index_evaluator import evaluate_expression
from akasha.query.point_condition import PointFilterContext
from akasha.storage.memtable import MemTable, MemTableEntry
from std.memory import ArcPointer


def point_context(id: Int, fields: List[PointField],
                  catalog: Optional[ArcPointer[FieldCatalog]] = None) -> PointFilterContext:
    var ids = List[Int](capacity=len(fields))
    for i in range(len(fields)):
        ids.append(fields[i].id)
    return PointFilterContext(Optional(id), ids^, catalog.copy())


def entry_context(entry: MemTableEntry,
                  catalog: Optional[ArcPointer[FieldCatalog]] = None) -> PointFilterContext:
    return point_context(entry.id, entry._vectors, catalog)


def matches_point(point: PointState, expression: FilterExpression,
                  catalog: Optional[ArcPointer[FieldCatalog]] = None) raises -> Bool:
    return not point.tombstone and matches_expression(point.payload(), expression,
        point_context(point.id, point._fields, catalog))


def matches_entry(entry: MemTableEntry, expression: FilterExpression,
                  catalog: Optional[ArcPointer[FieldCatalog]] = None) raises -> Bool:
    return not entry.tombstone and matches_expression(entry.fields(), expression,
        entry_context(entry, catalog))


def evaluate_table_expression(index: MetadataIndex, table: MemTable,
                              expression: FilterExpression,
                              catalog: Optional[ArcPointer[FieldCatalog]] = None) raises -> Bitmap:
    """Payload/ID indexes and authoritative vector checks share one live view.

    Metadata caches intentionally contain payloads, not vector storage state.
    Qdrant's plain checker likewise takes vector storage separately from indexes.
    """
    expression.validate()
    if not expression.needs_vector_context():
        return evaluate_expression(index, expression)
    if index.slot_count() != table.slot_count():
        raise Error("metadata slots do not align with point filter source")
    var result = Bitmap(index.slot_count())
    for ordinal in range(table.slot_count()):
        ref entry = table.entry_ref_at(ordinal)
        if index.id_at(ordinal) != entry.id:
            raise Error("metadata ID does not align with point filter source")
        if index.is_live_at(ordinal) and matches_entry(entry, expression, catalog):
            result.set(ordinal)
    return result^
