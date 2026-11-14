"""Optional JSON bitmap cache; snapshots read, collection writers publish."""
from akasha.storage.read_generation import ReadGeneration
from akasha.storage.checksum import BinaryWriter, CRC32_INITIAL
from akasha.storage.index_cache import CACHE_JSON_BITMAP_KIND, load_matching_cache_artifact, publish_mapped_cache
from akasha.storage.json_bitmap_codec import map_json_bitmap, map_shared_json_bitmap, _write_text
from akasha.document.codec import encode_payload
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.query.control import QueryControl
from akasha.storage.filesystem import remove_file_if_exists
from std.memory import ArcPointer
from akasha.storage.index_cache import MappedCacheArtifact
from akasha.storage.json_bitmap_shards import stage_json_bitmap, shard_name, JSON_MAX_SHARDS


def json_bitmap_cache_name(column: String, path: String, target: UInt8) -> String:
    var writer = BinaryWriter()
    _write_text(writer, column)
    _write_text(writer, path)
    writer.write_u8(target)
    return "json-bitmap-" + String(~writer.update_crc32_and_clear(CRC32_INITIAL)) + ".cache"


def _source_checksum(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                     column: String, path: String, target: UInt8,
                     control: Optional[QueryControl]) raises -> UInt32:
    var writer = BinaryWriter()
    _write_text(writer, column)
    _write_text(writer, path)
    writer.write_u8(target)
    writer.write_u64(UInt64(len(locations)))
    var register = writer.update_crc32_and_clear(CRC32_INITIAL)
    for row in range(len(locations)):
        if control:
            control.value().checkpoint(row)
        var location = locations[row]
        ref entry = root.run(location[0]).memtable.entry_ref_at(location[1])
        writer.write_i64(Int64(entry.id))
        var payload = encode_payload(entry.fields())
        writer.write_u32(UInt32(len(payload)))
        writer.write_bytes(payload)
        register = writer.update_crc32_and_clear(register)
    return ~register


def load_json_bitmap_cache(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                           column: String, path: String, target: UInt8,
                           control: Optional[QueryControl] = None) raises -> Optional[LanceJsonBitmapIndex]:
    if root.json_cache_directory.byte_length() == 0:
        return None
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(len(locations))
    var checksum = _source_checksum(root, locations, column, path, target, control)
    var artifact = load_matching_cache_artifact(
        root.json_cache_directory + "/" + json_bitmap_cache_name(column, path, target),
        CACHE_JSON_BITMAP_KIND, root.config.dimension, 0, root.sequence, checksum)
    if not artifact:
        return None
    try:
        if artifact.value().payload_length > 128 * 1024 * 1024:
            return None
        return Optional(map_json_bitmap(artifact.take(), column, path, target, len(locations), control))
    except:
        if control:
            control.value().checkpoint(0)
        return None



def load_json_bitmap_shard(root: ReadGeneration, column: String, path: String, target: UInt8,
                          slot: Int, rows: Int, checksum: UInt32,
                          control: Optional[QueryControl]) raises -> Optional[ArcPointer[MappedCacheArtifact]]:
    if root.json_cache_directory.byte_length() == 0:
        return None
    var artifact = load_matching_cache_artifact(root.json_cache_directory + "/" +
        shard_name(json_bitmap_cache_name(column, path, target), slot),
        CACHE_JSON_BITMAP_KIND, root.config.dimension, UInt64(slot + 1), 0, checksum)
    if not artifact:
        return None
    try:
        var shared = ArcPointer(artifact.take())
        shared[]._mapping.release_descriptor()
        _ = map_shared_json_bitmap(shared, column, path, target, rows, control,
            cache_bytes=0, cache_entries=0)
        return Optional(shared^)
    except:
        if control:
            control.value().checkpoint(0)
        return None


def publish_json_bitmap_cache_best_effort(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                                         column: String, index: LanceJsonBitmapIndex):
    """Caller holds writer/file exclusion; each optional file is atomic."""
    if root.json_cache_directory.byte_length() == 0:
        return
    try:
        var name = json_bitmap_cache_name(column, index.path, index.target())
        for slot in range(len(index._bitmap._shards)):
            ref shard = index._bitmap._shards[slot][]
            var existing = load_json_bitmap_shard(root, column, index.path, index.target(), slot,
                min(4096, len(locations) - slot * 4096), shard.source_checksum, None)
            if not existing:
                publish_mapped_cache(root.json_cache_directory, shard_name(name, slot), shard)
        if index._bitmap._mapped:
            publish_mapped_cache(root.json_cache_directory, name,
                index._bitmap._mapped.value()[].artifact[])
        else:
            var checksum = _source_checksum(root, locations, column, index.path, index.target(), None)
            var staged = stage_json_bitmap(column, index, root.config.dimension, 0, root.sequence, checksum)
            publish_mapped_cache(root.json_cache_directory, name, staged[])
        for slot in range(len(index._bitmap._shards), JSON_MAX_SHARDS):
            remove_file_if_exists(root.json_cache_directory + "/" + shard_name(name, slot))
            remove_file_if_exists(root.json_cache_directory + "/" + shard_name(name, slot) + ".tmp")
    except:
        pass


def remove_json_bitmap_cache_best_effort(directory: String, column: String, path: String, target: UInt8):
    var file = directory + "/" + json_bitmap_cache_name(column, path, target)
    for slot in range(-1, JSON_MAX_SHARDS):
        try:
            var name = file.copy() if slot == -1 else shard_name(file, slot)
            remove_file_if_exists(name)
            remove_file_if_exists(name + ".tmp")
        except:
            pass
