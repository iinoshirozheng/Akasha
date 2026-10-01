from akasha.common.config import CollectionConfig
from akasha.index.hnsw import HnswIndex
from akasha.storage.hnsw_store import (
    decode_hnsw_snapshot_owned,
    encode_hnsw_snapshot,
)
from akasha.storage.index_cache import (
    CACHE_HNSW_OVERLAY_KIND,
    CacheArtifact,
    load_cache_artifact,
    publish_cache,
)


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
        var payload = encode_hnsw_snapshot(delta, base_sequence)
        var artifact = CacheArtifact(
            CACHE_HNSW_OVERLAY_KIND,
            delta.config.dimension,
            generation,
            sequence,
            base_checksum,
            payload^,
        )
        publish_cache(path, "hnsw-overlay.cache", artifact)
        return True
    except:
        return False
