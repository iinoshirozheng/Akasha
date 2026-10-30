"""Qdrant v1.19.0 JSON value traversal/mutation port (Apache-2.0).

Source: lib/segment/src/json_path/mod.rs value_get/value_set/value_set_map/
value_remove and common/utils.rs merge_map at 74f3e85b9473c62560006c043e13737ce6b48412.
Representation adapter: owned bounded Mojo arenas replace serde_json trees.
Qdrant enables serde_json preserve_order, including swap-remove semantics.
"""

from akasha.document.json_path import JsonPath, JsonPathItem
from akasha.document.value import PayloadValue


def payload_value_get(root: PayloadValue, path: JsonPath) raises -> List[PayloadValue]:
    var result = List[PayloadValue]()
    var first = root.get_key(path.first_key)
    if first:
        _value_get(path.rest, 0, first.value(), result)
    return result^


def _value_get(path: List[JsonPathItem], offset: Int, value: PayloadValue,
               mut result: List[PayloadValue]) raises:
    if offset == len(path):
        result.append(value.clone())
        return
    ref head = path[offset]
    var next = Optional[PayloadValue]()
    if head.kind == 1:
        next = value.get_key(head.key)
    elif head.kind == 2:
        next = value.get_index(head.index)
    elif value.is_array():
        var children = value.children()
        for i in range(len(children)):
            _value_get(path, offset + 1, children[i], result)
    if next:
        _value_get(path, offset + 1, next.value(), result)


def _slot(keys: List[String], key: String) -> Int:
    for i in range(len(keys)):
        if keys[i] == key:
            return i
    return -1


def _remove_slot(mut keys: List[String], mut values: List[PayloadValue], index: Int):
    # serde_json::Map::remove delegates to IndexMap::swap_remove.
    var last_key = keys.pop()
    var last_value = values.pop()
    if index < len(keys):
        keys[index] = last_key^
        values[index] = last_value^


def _merge_map(dest: PayloadValue, src: PayloadValue) raises -> PayloadValue:
    var keys = dest.keys()
    var values = dest.children()
    var source_keys = src.keys()
    var source_values = src.children()
    for i in range(len(source_keys)):
        var slot = _slot(keys, source_keys[i])
        if source_values[i].is_null():
            if slot >= 0:
                _remove_slot(keys, values, slot)
        elif slot >= 0:
            values[slot] = source_values[i].clone()
        else:
            keys.append(String(copy=source_keys[i]))
            values.append(source_values[i].clone())
    return PayloadValue.object(keys^, values^)


def payload_value_set(mut root: PayloadValue, path: Optional[JsonPath], src: PayloadValue) raises:
    """Publish an owned replacement only after the complete bounded edit succeeds."""
    if not root.is_object() or not src.is_object():
        raise Error("payload set requires root and source objects")
    var replacement: PayloadValue
    if path:
        replacement = _value_set_map(path.value().first_key, path.value().rest, 0, root, src)
    else:
        replacement = _merge_map(root, src)
    root = replacement^


def _value_set_map(key: String, path: List[JsonPathItem], offset: Int,
                   dest: PayloadValue, src: PayloadValue) raises -> PayloadValue:
    var keys = dest.keys()
    var values = dest.children()
    var index = _slot(keys, key)
    if index >= 0:
        values[index] = _value_set(path, offset, values[index], src)
    else:
        keys.append(String(copy=key))
        values.append(_value_set(path, offset, PayloadValue.null(), src))
    return PayloadValue.object(keys^, values^)


def _value_set(path: List[JsonPathItem], offset: Int, dest: PayloadValue,
               src: PayloadValue) raises -> PayloadValue:
    if offset < len(path):
        ref head = path[offset]
        if head.kind == 1:
            var object = dest.clone() if dest.is_object() else PayloadValue.object(List[String](), List[PayloadValue]())
            return _value_set_map(head.key, path, offset + 1, object, src)
        var children = dest.children() if dest.is_array() else List[PayloadValue]()
        if head.kind == 2:
            if head.index < UInt64(len(children)):
                var index = Int(head.index)
                children[index] = _value_set(path, offset + 1, children[index], src)
        else:
            for i in range(len(children)):
                children[i] = _value_set(path, offset + 1, children[i], src)
        return PayloadValue.array(children^)
    var object = dest.clone() if dest.is_object() else PayloadValue.object(List[String](), List[PayloadValue]())
    return _merge_map(object, src)


def payload_value_remove(mut root: PayloadValue, path: JsonPath) raises -> List[PayloadValue]:
    if not root.is_object():
        raise Error("payload remove requires an object root")
    var parts = List[JsonPathItem]()
    parts.append(JsonPathItem(1, String(copy=path.first_key), 0))
    for item in path.rest:
        parts.append(item.copy())
    var removed = List[PayloadValue]()
    var replacement = _value_remove(parts, 0, root, removed)
    root = replacement^
    return removed^


def _value_remove(path: List[JsonPathItem], offset: Int, value: PayloadValue,
                  mut result: List[PayloadValue]) raises -> PayloadValue:
    ref head = path[offset]
    var terminal = offset + 1 == len(path)
    if head.kind == 1 and value.is_object():
        var keys = value.keys()
        var children = value.children()
        var slot = _slot(keys, head.key)
        if slot >= 0:
            if terminal:
                result.append(children[slot].clone())
                _remove_slot(keys, children, slot)
            else:
                children[slot] = _value_remove(path, offset + 1, children[slot], result)
        return PayloadValue.object(keys^, children^)
    if value.is_array():
        var children = value.children()
        if head.kind == 2:
            # Source deliberately forbids deleting an array slot: non-idempotent.
            if not terminal and head.index < UInt64(len(children)):
                var index = Int(head.index)
                children[index] = _value_remove(path, offset + 1, children[index], result)
        elif head.kind == 3:
            if terminal:
                result.append(value.clone())
                return PayloadValue.array(List[PayloadValue]())
            for i in range(len(children)):
                children[i] = _value_remove(path, offset + 1, children[i], result)
        return PayloadValue.array(children^)
    return value.clone()
