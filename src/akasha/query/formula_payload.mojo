"""Qdrant payload-backed formula value retrieval (Apache-2.0).

Source: struct_payload_index/read_view/value_retriever/helpers.rs and
rescore_formula/formula_scorer.rs at 74f3e85b9473c62560006c043e13737ce6b48412.
The DocumentField root adapter reuses the source-derived JSON-path traversal.
"""
from akasha.document.json_path import JsonPath
from akasha.document.payload_path import _value_get
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue


def formula_payload_value(fields: List[DocumentField], path: JsonPath) raises -> Optional[PayloadValue]:
    var values = List[PayloadValue]()
    for i in range(len(fields)):
        if fields[i].name == path.first_key:
            _value_get(path.rest, 0, fields[i].value, values)
            break
    if not path.has_wildcard_suffix():
        var flattened = List[PayloadValue]()
        for i in range(len(values)):
            if values[i].is_array():
                var children = values[i].children()
                for j in range(len(children)):
                    flattened.append(children[j].clone())
            else:
                flattened.append(values[i].clone())
        values = flattened^
    if len(values) == 0:
        return None
    if len(values) == 1:
        return Optional(values.pop())
    return Optional(PayloadValue.array(values^))
