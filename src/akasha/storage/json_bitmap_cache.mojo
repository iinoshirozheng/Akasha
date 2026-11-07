"""Optional JSON bitmap cache; snapshots read, collection writers publish."""
from akasha.storage.read_generation import ReadGeneration
from akasha.storage.checksum import BinaryWriter, CRC32_INITIAL
from akasha.storage.index_cache import CACHE_JSON_BITMAP_KIND, CacheArtifact, load_matching_cache_artifact, publish_cache
from akasha.storage.json_bitmap_codec import encode_json_bitmap, decode_json_bitmap, _write_text
from akasha.document.codec import encode_payload
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.query.control import QueryControl
from akasha.storage.filesystem import remove_file_if_exists


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
        var bytes = artifact.value()._mapping.copy_scalars[DType.uint8](36, artifact.value().payload_length)
        return Optional(decode_json_bitmap(Span(bytes), column, path, target, len(locations), control))
    except:
        if control:
            control.value().checkpoint(0)
        return None


def publish_json_bitmap_cache_best_effort(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                                         column: String, index: LanceJsonBitmapIndex):
    """Caller holds writer/file exclusion; failure cannot change authority."""
    if root.json_cache_directory.byte_length() == 0:
        return
    try:
        var checksum = _source_checksum(root, locations, column, index.path, index.target(), None)
        var artifact = CacheArtifact(CACHE_JSON_BITMAP_KIND, root.config.dimension, 0,
            root.sequence, checksum, encode_json_bitmap(column, index))
        publish_cache(root.json_cache_directory,
            json_bitmap_cache_name(column, index.path, index.target()), artifact)
    except:
        pass


def remove_json_bitmap_cache_best_effort(directory: String, column: String, path: String, target: UInt8):
    try:
        var file = directory + "/" + json_bitmap_cache_name(column, path, target)
        remove_file_if_exists(file)
        remove_file_if_exists(file + ".tmp")
    except:
        pass
