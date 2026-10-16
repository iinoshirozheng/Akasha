from akasha.common.config import CollectionConfig
from akasha.index.hnsw import HnswIndex
from akasha.storage.hnsw_store import (
    decode_hnsw_snapshot_owned,
    HnswSnapshotEncoder,
)
from akasha.storage.index_cache import (
    CACHE_HNSW_OVERLAY_KIND,
    encode_cache_header,
    load_cache_artifact,
)
from akasha.storage.byte_sink import FileByteSink, CheckedByteSink, write_checksum
from akasha.storage.filesystem import atomic_replace, sync_directory, sync_file


def load_hnsw_overlay_cache(
    path: String,
    config: CollectionConfig,
    generation: UInt64,
    sequence: UInt64,
    base_checksum: UInt32,
    base_sequence: UInt64,
) -> Optional[HnswIndex]:
    """Decode an optional delta; authority coverage is checked before adoption.
    """
    var loaded = load_cache_artifact(path + "/hnsw-overlay.cache")
    if not loaded:
        return None
    var artifact = loaded.take()
    # Compaction may advance generation/reorder rows without changing any
    # vector. The retained base CRC and exact authority coverage below bind
    # the graph independently of that physical storage layout.
    if (
        artifact.kind != CACHE_HNSW_OVERLAY_KIND
        or artifact.dimension != config.dimension
        or artifact.generation > generation
        or artifact.sequence != sequence
        or artifact.source_checksum != base_checksum
    ):
        return None
    try:
        return Optional(
            decode_hnsw_snapshot_owned(
                artifact.take_payload(), config, base_sequence
            )
        )
    except:
        return None


def publish_hnsw_overlay_cache_best_effort(
    path: String,
    delta: HnswIndex,
    generation: UInt64,
    sequence: UInt64,
    base_checksum: UInt32,
    base_sequence: UInt64,
) -> Bool:
    """Publish only a derived artifact after the authority checkpoint commits.
    """
    try:
        var encoder = HnswSnapshotEncoder(delta, base_sequence)
        var header = encode_cache_header(
            CACHE_HNSW_OVERLAY_KIND,
            delta.config.dimension,
            generation,
            sequence,
            base_checksum,
            Int(encoder.byte_length),
        )
        var final_path = path + "/hnsw-overlay.cache"
        var temporary_path = final_path + ".tmp"
        with open(temporary_path, "w") as file:
            var sink = FileByteSink(file)
            var envelope = CheckedByteSink(sink)
            envelope.write(Span(header))
            # Inner footer belongs to the outer checksum, but neither format
            # includes its own footer. No owned snapshot payload is created.
            _ = encoder.write_to(envelope)
            var checksum = ~envelope.register
            write_checksum(sink, checksum)
            sync_file(file)
        atomic_replace(temporary_path, final_path)
        sync_directory(path)
        return True
    except:
        return False
