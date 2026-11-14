"""Kind-aware optional caches; only collection writers publish artifacts."""
from std.memory import ArcPointer
from akasha.index.json_scalar_index import JsonScalarIndex
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.index.lance_json_btree import LanceJsonBTreeIndex
from akasha.index.lance_btree import LanceBTreeIndex
from akasha.storage.read_generation import ReadGeneration
from akasha.storage.btree_pages import map_btree_pages
from akasha.storage.index_cache import CACHE_JSON_BTREE_KIND, load_matching_cache_artifact, publish_mapped_cache
from akasha.storage.json_bitmap_cache import load_json_bitmap_cache, publish_json_bitmap_cache_best_effort, remove_json_bitmap_cache_best_effort, _source_checksum
from akasha.storage.json_bitmap_codec import _write_text
from akasha.storage.checksum import BinaryWriter, CRC32_INITIAL
from akasha.storage.filesystem import remove_file_if_exists
from akasha.query.control import QueryControl


def json_btree_cache_name(column: String, path: String, target: UInt8) -> String:
    var writer = BinaryWriter()
    _write_text(writer, column)
    _write_text(writer, path)
    writer.write_u8(target)
    return "json-btree-" + String(~writer.update_crc32_and_clear(CRC32_INITIAL)) + ".cache"


def load_json_scalar_cache(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                           column: String, path: String, target: UInt8, kind: UInt8,
                           control: Optional[QueryControl]) raises -> Optional[JsonScalarIndex]:
    if kind == 1:
        var bitmap = load_json_bitmap_cache(root, locations, column, path, target, control)
        return Optional(JsonScalarIndex(bitmap.take())) if bitmap else None
    if kind != 2:
        raise Error("unsupported JSON index kind")
    if root.json_cache_directory.byte_length() == 0:
        return None
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(len(locations))
    var checksum = _source_checksum(root, locations, column, path, target, control)
    var artifact = load_matching_cache_artifact(root.json_cache_directory + "/" + json_btree_cache_name(column, path, target),
        CACHE_JSON_BTREE_KIND, root.config.dimension, 0, root.sequence, checksum)
    if not artifact:
        return None
    try:
        var shared = ArcPointer(artifact.take())
        shared[]._mapping.release_descriptor()
        var pages = map_btree_pages(shared, column, path, target, len(locations), control)
        # Collection indexes use dense ordinals into this captured ID ordering.
        if pages.row_count > 0 and pages.max_id >= UInt64(pages.row_count):
            return None
        return Optional(JsonScalarIndex(LanceJsonBTreeIndex(LanceBTreeIndex(pages^))))
    except:
        if control:
            control.value().checkpoint(0)
        return None


def publish_json_scalar_cache_best_effort(root: ReadGeneration, locations: List[Tuple[Int, Int]],
                                         column: String, index: JsonScalarIndex):
    if index.kind() == 1:
        publish_json_bitmap_cache_best_effort(root, locations, column, index._data[LanceJsonBitmapIndex])
        return
    if root.json_cache_directory.byte_length() == 0:
        return
    try:
        ref pages = index._data[LanceJsonBTreeIndex]._btree.pages
        publish_mapped_cache(root.json_cache_directory, json_btree_cache_name(column, pages.path, index.target()), pages.artifact[])
    except:
        pass


def remove_json_scalar_cache_best_effort(directory: String, column: String, path: String, target: UInt8, kind: UInt8):
    if kind == 1:
        remove_json_bitmap_cache_best_effort(directory, column, path, target)
        return
    try:
        var file = directory + "/" + json_btree_cache_name(column, path, target)
        remove_file_if_exists(file)
        remove_file_if_exists(file + ".tmp")
    except:
        pass
