"""Payload-block graphs merged into the main HNSW graph.

Qdrant 21db2f3 hnsw/build.rs and GraphLayersBuilder::merge_from_other,
Apache-2.0. Akasha's exact sorted scalar postings replace Qdrant's histogram
estimates when forming overlapping numeric ranges.
"""

from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_entries import HnswEntry
from akasha.index.hnsw_connectivity import HnswBuildRandom, subgraph_connectivity
from akasha.query.control import QueryControl
from akasha.query.planner import hnsw_full_scan_threshold
from akasha.index.metadata import MetadataIndex
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_storage import HnswStorage
from std.memory import bitcast
from akasha.common.config import ScalarKind


@fieldwise_init
struct HnswPayloadBlock(Movable):
    var field: String
    var ids: List[Int]


def _append_block(
    mut blocks: List[HnswPayloadBlock], field: String, metadata: MetadataIndex,
    ordinals: List[Int], start: Int, end: Int, minimum: Int, maximum: Int,
) raises:
    if end - start < minimum or end - start > maximum:
        return
    var ids = List[Int](capacity=end - start)
    for position in range(start, end):
        var ordinal = ordinals[position]
        if metadata.is_live_at(ordinal):
            ids.append(metadata.id_at(ordinal))
    if len(ids) >= minimum:
        blocks.append(HnswPayloadBlock(field.copy(), ids^))


def payload_blocks(
    metadata: MetadataIndex, threshold: Int, maximum: Int
) raises -> List[HnswPayloadBlock]:
    if threshold <= 0 or maximum < 0:
        raise Error("HNSW payload block bounds are invalid")
    var blocks = List[HnswPayloadBlock]()
    ref keywords = metadata._keywords._entries
    var start = 0
    while start < len(keywords):
        var end = start + 1
        while end < len(keywords):
            if keywords[end].name != keywords[start].name or keywords[end].kind != keywords[start].kind or keywords[end].string_value != keywords[start].string_value or keywords[end].bool_value != keywords[start].bool_value:
                break
            end += 1
        var ordinals = List[Int](capacity=end - start)
        for position in range(start, end):
            ordinals.append(keywords[position].ordinal)
        # Qdrant keyword/bool blocks use strictly greater than threshold.
        _append_block(blocks, keywords[start].name, metadata, ordinals, 0, len(ordinals), threshold + 1, maximum)
        start = end

    # Numeric ranges overlap by one half-block and never split equal values.
    # Integer equality blocks precede range blocks, as their map index does.
    ref integer_values = metadata._numbers._integers
    var equality_start = 0
    while equality_start < len(integer_values):
        var equality_end = equality_start + 1
        while equality_end < len(integer_values) and integer_values[equality_end].name == integer_values[equality_start].name and integer_values[equality_end].value == integer_values[equality_start].value:
            equality_end += 1
        var equality_ordinals = List[Int](capacity=equality_end - equality_start)
        for position in range(equality_start, equality_end):
            equality_ordinals.append(integer_values[position].ordinal)
        _append_block(blocks, integer_values[equality_start].name, metadata, equality_ordinals, 0, len(equality_ordinals), threshold, maximum)
        equality_start = equality_end
    var field_start = 0
    while field_start < len(integer_values):
        var field_end = field_start + 1
        while field_end < len(integer_values) and integer_values[field_end].name == integer_values[field_start].name:
            field_end += 1
        var ordinals = List[Int](capacity=field_end - field_start)
        for position in range(field_start, field_end):
            ordinals.append(integer_values[position].ordinal)
        var previous = field_start
        var lower = field_start
        while lower < field_end:
            var upper = min(field_end, lower + max(1, threshold // 2))
            while upper < field_end and integer_values[upper].value == integer_values[upper - 1].value:
                upper += 1
            if lower != field_start or upper == field_end:
                _append_block(blocks, integer_values[field_start].name, metadata, ordinals, previous - field_start,
                    upper - field_start, threshold // 4 + 1, maximum)
            previous = lower
            lower = upper
        field_start = field_end
    ref float_values = metadata._numbers._floats
    var float_start = 0
    while float_start < len(float_values):
        var field_end = float_start + 1
        while field_end < len(float_values) and float_values[field_end].name == float_values[float_start].name:
            field_end += 1
        var ordinals = List[Int](capacity=field_end - float_start)
        for position in range(float_start, field_end):
            ordinals.append(float_values[position].ordinal)
        var previous = float_start
        var lower = float_start
        while lower < field_end:
            var upper = min(field_end, lower + max(1, threshold // 2))
            while upper < field_end and float_values[upper].value == float_values[upper - 1].value:
                upper += 1
            if lower != float_start or upper == field_end:
                _append_block(blocks, float_values[float_start].name, metadata, ordinals, previous - float_start,
                    upper - float_start, threshold // 4 + 1, maximum)
            previous = lower
            lower = upper
        float_start = field_end
    return blocks^


def _prepared_vector(graph: HnswStorage, slot: UInt32) raises -> List[Float32]:
    var result = List[Float32](capacity=graph.dimension + 1)
    if graph.scalar_kind == ScalarKind.i8():
        var offset = Int(slot) * graph.dimension
        for component in range(graph.dimension):
            result.append(Float32(bitcast[DType.int8](graph.vector_bytes[offset + component])))
        result.append(graph._i8_vector_scale(slot))
    else:
        for component in range(graph.dimension):
            result.append(graph.vector_value(slot, component))
    return result^


def attach_payload_graphs(mut index: HnswIndex, metadata: MetadataIndex, control: Optional[QueryControl] = None) raises:
    """Build independent filtered graphs, then publish one packed link union."""
    var slots = index.point_count()
    if slots == 0:
        return
    var threshold = hnsw_full_scan_threshold(slots)
    var base_edges = 0
    for ordinal in range(slots):
        base_edges += index.graph.neighbor_count(UInt32(ordinal), 0)
    var average = max(1, base_edges // slots)
    var maximum = slots // average * 4
    var blocks = payload_blocks(metadata, threshold, maximum)
    if len(blocks) == 0:
        return
    var rows = List[List[UInt32]](capacity=len(index.graph.neighbor_counts))
    for ordinal in range(slots):
        var slot = UInt32(ordinal)
        for level in range(index.graph.level(slot) + 1):
            var row = List[UInt32]()
            for edge in range(index.graph.neighbor_count(slot, level)):
                row.append(index.graph.neighbor_at(slot, level, edge))
            rows.append(row^)
    var rng = HnswBuildRandom(index.config.level_seed)
    var percolation = Float32(1) - Float32(2) / Float32(average)
    var required = Float32(0)
    if average >= 4:
        var all_points = List[UInt32]()
        for ordinal in range(slots):
            if index.graph.is_current(UInt32(ordinal)):
                all_points.append(UInt32(ordinal))
        for _ in range(3):
            required = max(required, subgraph_connectivity(index.graph, index.entries, rows, all_points, percolation, rng, control))
    # Qdrant iterates indexed fields, including fields without usable blocks.
    # Automatic scalar indexes use stable field-name order in Akasha.
    var field_set = Dict[String, Bool]()
    for item in metadata._keywords._entries:
        field_set[item.name] = True
    for item in metadata._numbers._integers:
        field_set[item.name] = True
    for item in metadata._numbers._floats:
        field_set[item.name] = True
    var fields = List[String]()
    for field in field_set:
        fields.append(field.copy())
    sort(Span(fields))
    for field_ordinal in range(len(fields)):
        for block_ordinal in range(len(blocks)):
            ref block = blocks[block_ordinal]
            if block.field != fields[field_ordinal]:
                continue
            if control:
                control.value().checkpoint(0)
            var points = List[UInt32]()
            for id in block.ids:
                var slot = index.graph.current_slot(id)
                if slot:
                    points.append(slot.value())
            if len(points) <= threshold // 4:
                continue
            if field_ordinal > 0 and average >= 4:
                if subgraph_connectivity(index.graph, index.entries, rows, points, percolation, rng, control) >= required:
                    continue
            var additional = HnswIndex(index.config)
            for id in block.ids:
                if control:
                    control.value().checkpoint(additional.point_count())
                var slot = index.graph.current_slot(id)
                if not slot:
                    continue
                additional._insert_prepared[-1](id, _prepared_vector(index.graph, slot.value()),
                    0, False, additional.point_count() > 0)
            for ordinal in range(additional.point_count()):
                var local = UInt32(ordinal)
                var original = index.graph.current_slot(additional.graph.id_at(local)).value()
                for level in range(additional.graph.level(local) + 1):
                    ref row = rows[index.graph.neighbor_count_bases[Int(original)] + level]
                    var seen = Dict[UInt32, Bool]()
                    for neighbor in row:
                        seen[neighbor] = True
                    for edge in range(additional.graph.neighbor_count(local, level)):
                        var target = additional.graph.neighbor_at(local, level, edge)
                        var mapped = index.graph.current_slot(additional.graph.id_at(target)).value()
                        if mapped not in seen:
                            seen[mapped] = True
                            row.append(mapped)
            for entry in additional.entries.primary:
                var mapped = index.graph.current_slot(additional.graph.id_at(entry.slot)).value()
                var exists = False
                for existing in index.entries.primary:
                    if existing.slot == mapped:
                        exists = True
                if not exists:
                    # A primary must not duplicate an extra entry in the file.
                    var retained = List[HnswHeapItem]()
                    while not index.entries.extra.is_empty():
                        var item = index.entries.extra.pop_worst()
                        if item.slot != mapped:
                            retained.append(item)
                    for item in retained:
                        index.entries.extra.offer(item, index.entries.extra_capacity)
                    index.entries.primary.append(HnswEntry(mapped, 0))
            index.build_stats.distance_evaluations += additional.build_stats.distance_evaluations
    var counts = List[Int](capacity=len(rows))
    var edges = List[UInt32]()
    for row in rows:
        counts.append(len(row))
        for neighbor in row:
            edges.append(neighbor)
    if control:
        control.value().checkpoint(0)
    index.graph.replace_all_links(counts, edges)
    index.build_stats.directed_edges = len(edges)
    index.validate_structure()
