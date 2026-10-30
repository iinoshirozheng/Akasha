"""Prepare source-derived payload operations under the collection writer lock.

Qdrant shard/update/payload.rs and update/mod.rs at
74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0.
Akasha uses one atomic replacement batch instead of Qdrant's segment chunks.
"""
from akasha.document.payload_update import PayloadUpdate
from akasha.document.point_state import PointMutation, FieldUpdate
from akasha.query.filter_ast import FilterExpression
from akasha.query.evaluator import matches_expression
from akasha.storage.point_table import PointTable


def prepare_payload_mutations(table: PointTable, update: PayloadUpdate,
                              points: Optional[List[Int]], expression: Optional[FilterExpression],
                              max_points: Int) raises -> List[PointMutation]:
    if max_points <= 0 or max_points > 65_536:
        raise Error("payload update point limit must be in 1..65536")
    if not points and not expression:
        raise Error("payload update requires points or filter")
    if expression:
        expression.value().validate()
    var ids = List[Int]()
    if points:
        if len(points.value()) > max_points:
            raise Error("payload update point count exceeds resource limit")
        var seen = Dict[Int, Bool]()
        for id in points.value():
            if id not in seen:
                seen[id] = True
                ids.append(id)
    else:
        var entries = table.entry_view()
        for i in range(len(entries)):
            if not entries[i].tombstone and matches_expression(entries[i].payload(), expression.value()):
                if len(ids) == max_points:
                    raise Error("payload update point count exceeds resource limit")
                ids.append(entries[i].id)
        sort(Span(ids))
    var changes = List[PointMutation](capacity=len(ids))
    for id in ids:
        var point = table.get(id)
        if not point:
            raise Error("payload target point does not exist: " + String(id))
        var fields = update.apply(point.value().payload())
        changes.append(PointMutation(id, 3, List[FieldUpdate](), Optional(fields^)))
    return changes^
