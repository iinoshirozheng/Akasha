"""Optional named graph caches; source ordinals are rebound, never persisted."""

from akasha.common.config import ScalarKind
from akasha.document.vector_schema import VectorFieldSpec
from akasha.index.field_artifacts import FieldRow
from akasha.index.field_dense import dense_f32_projection
from akasha.index.field_hnsw import FieldHnswIndex
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswIdOrdinalLookup
from akasha.storage.checksum import BinaryWriter, crc32_update, CRC32_INITIAL
from akasha.storage.collection_config import encode_collection_config
from akasha.storage.hnsw_store import (
    decode_hnsw_snapshot_owned,
    encode_hnsw_snapshot,
)
from akasha.storage.index_cache import (
    CACHE_FIELD_HNSW_KIND,
    CacheArtifact,
    load_cache_payload,
    publish_cache,
)
from akasha.storage.memtable import MemTable
from akasha.storage.filesystem import path_exists
from std.memory import bitcast
from std.sys.info import is_little_endian


def field_hnsw_cache_name(field_id: Int) -> String:
    return String("field-hnsw-", field_id, ".cache")


def _field_rows(table: MemTable, field: VectorFieldSpec) raises -> List[Int]:
    var locations = List[FieldRow]()
    for ordinal in table.live_ordinals():
        ref entry = table.entry_ref_at(ordinal)
        if entry.field_ordinal(field.id) >= 0:
            locations.append(FieldRow(entry.id, 0, ordinal))
    sort(Span(locations))
    var rows = List[Int](capacity=len(locations))
    for location in locations:
        rows.append(location.ordinal)
    return rows^


def _source_checksum(
    table: MemTable, field: VectorFieldSpec, rows: List[Int]
) raises -> UInt32:
    var writer = BinaryWriter()
    writer.write_u32(UInt32(field.id))
    writer.write_u8(field.kind)
    writer.write_u8(field.scalar)
    writer.write_u8(field.metric)
    writer.write_u8(field.index)
    writer.write_u32(UInt32(field.dimension))
    writer.write_u32(UInt32(field.name.byte_length()))
    for byte in field.name.bytes():
        writer.write_u8(byte)
    writer.write_bytes(encode_collection_config(field.hnsw.value()))
    writer.write_u64(UInt64(len(rows)))
    var register = writer.update_crc32_and_clear(CRC32_INITIAL)
    for ordinal in rows:
        ref entry = table.entry_ref_at(ordinal)
        ref value = entry.vector_at(entry.field_ordinal(field.id)).value()
        value.validate(field)
        writer.write_i64(Int64(entry.id))
        register = writer.update_crc32_and_clear(register)
        # Every supported authority scalar projects exactly to F32. Include the
        # native scalar above, so equal values of different types cannot alias.
        if field.scalar == 0:
            register = _values_crc(
                register, value.dense_values[DType.float32]()
            )
        else:
            var values = dense_f32_projection(value)
            register = _values_crc(register, values)
    return ~register


def _values_crc(register: UInt32, values: List[Float32]) -> UInt32:
    comptime if is_little_endian():
        var bytes = Span(
            unsafe_ptr=values.unsafe_ptr().unsafe_bitcast[UInt8](),
            length=len(values) * 4,
        )
        return crc32_update(register, bytes)
    else:
        var writer = BinaryWriter()
        for value in values:
            writer.write_f32(value)
        return writer.update_crc32_and_clear(register)


def _validate_vector(
    index: HnswIndex, slot: UInt32, values: List[Float32]
) raises:
    var prepared = index.metric.prepare_graph_vector(values)
    if index.config.scalar_kind == ScalarKind.i8():
        var base = Int(slot) * index.dimension
        for component in range(index.dimension):
            if (
                Float32(
                    bitcast[DType.int8](
                        index.graph.vector_bytes[base + component]
                    )
                )
                != prepared[component]
            ):
                raise Error("named graph cache vector differs from authority")
        if bitcast[DType.uint32](index.graph._i8_vector_scale(slot)) != bitcast[
            DType.uint32
        ](prepared[index.dimension]):
            raise Error("named graph cache scale differs from authority")
    else:
        for component in range(index.dimension):
            if bitcast[DType.uint32](
                index.graph.vector_value(slot, component)
            ) != bitcast[DType.uint32](prepared[component]):
                raise Error("named graph cache vector differs from authority")


def load_field_hnsw_cache(
    directory: String, table: MemTable, field: VectorFieldSpec
) -> Optional[FieldHnswIndex]:
    if directory.byte_length() == 0:
        return None
    var path = directory + "/" + field_hnsw_cache_name(field.id)
    if not path_exists(path):
        return None
    try:
        var rows = _field_rows(table, field)
        var payload = load_cache_payload(
            path,
            CACHE_FIELD_HNSW_KIND,
            field.dimension,
            UInt64(field.id),
            0,
            _source_checksum(table, field, rows),
        )
        if not payload:
            return None
        var index = decode_hnsw_snapshot_owned(
            payload.take(), field.hnsw.value(), 0
        )
        if index.graph.slot_count() != len(rows):
            return None
        var lookup = Dict[Int, Int]()
        for row in range(len(rows)):
            ref entry = table.entry_ref_at(rows[row])
            var slot = UInt32(row)
            if index.graph.id_at(
                slot
            ) != entry.id or not index.graph.is_current(slot):
                return None
            ref value = entry.vector_at(entry.field_ordinal(field.id)).value()
            if field.scalar == 0:
                _validate_vector(
                    index, slot, value.dense_values[DType.float32]()
                )
            else:
                var values = dense_f32_projection(value)
                _validate_vector(index, slot, values)
            lookup[entry.id] = row
        var domain = HnswIdOrdinalLookup(lookup^, len(rows))
        return Optional(
            FieldHnswIndex(index^, rows^, field.scalar, domain^, cache_hit=True)
        )
    except:
        return None


def publish_field_hnsw_cache_best_effort(
    directory: String,
    table: MemTable,
    field: VectorFieldSpec,
    mut graph: FieldHnswIndex,
):
    """Caller holds collection writer/file lock and the graph query lock."""
    if graph.cache_published:
        return
    try:
        if (
            graph.authority_scalar != field.scalar
            or graph.index.config != field.hnsw.value()
        ):
            return
        var artifact = CacheArtifact(
            CACHE_FIELD_HNSW_KIND,
            field.dimension,
            UInt64(field.id),
            0,
            _source_checksum(table, field, graph.rows),
            encode_hnsw_snapshot(graph.index, 0),
        )
        publish_cache(directory, field_hnsw_cache_name(field.id), artifact)
        graph.cache_published = True
    except:
        pass
