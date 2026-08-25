from akasha.compute.simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult
from akasha.storage.filesystem import (
    atomic_replace,
    ensure_directory,
    path_exists,
    sync_directory,
)
from akasha.storage.manifest import load_manifest, Manifest, publish_manifest
from akasha.storage.memtable import MemTable
from akasha.storage.segment import read_segment, write_segment
from akasha.storage.wal import append_wal, recover_wal, WalRecord
from std.math import isfinite


comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct PersistentCollection:
    """A durable, single-writer exact vector collection."""

    var path: String
    var dimension: Int
    var _wal_path: String
    var _memtable: MemTable
    var _last_sequence: UInt64

    def __init__(
        out self,
        path: String,
        dimension: Int,
        var memtable: MemTable,
        last_sequence: UInt64,
    ):
        self.path = String(copy=path)
        self.dimension = dimension
        self._wal_path = path + "/wal.bin"
        self._memtable = memtable^
        self._last_sequence = last_sequence

    @staticmethod
    def open(path: String, dimension: Int) raises -> PersistentCollection:
        """Create or recover a persistent collection at ``path``."""
        if dimension <= 0:
            raise Error("collection dimension must be positive")
        ensure_directory(path)

        var memtable = MemTable(dimension)
        var snapshot_sequence = UInt64(0)
        var manifest_path = path + "/manifest.bin"
        if path_exists(manifest_path):
            var manifest = load_manifest(path, dimension)
            var snapshot = read_segment(
                path + "/" + manifest.segment_name, dimension
            )
            if snapshot.last_sequence != manifest.last_sequence:
                raise Error("manifest and segment sequence mismatch")
            if snapshot.checksum != manifest.segment_checksum:
                raise Error("manifest and segment checksum mismatch")
            snapshot_sequence = manifest.last_sequence
            for index in range(len(snapshot.entries)):
                var values = _clone_vector(snapshot.entries[index].values)
                memtable.apply_upsert(
                    snapshot.entries[index].id,
                    snapshot.entries[index].sequence,
                    values^,
                )

        var records = recover_wal(path + "/wal.bin", dimension)
        var last_sequence = snapshot_sequence
        for index in range(len(records)):
            if records[index].sequence <= snapshot_sequence:
                continue
            if records[index].is_delete:
                memtable.apply_delete(
                    records[index].id, records[index].sequence
                )
            else:
                var values = _clone_vector(records[index].values)
                memtable.apply_upsert(
                    records[index].id, records[index].sequence, values^
                )
            last_sequence = records[index].sequence

        return PersistentCollection(path, dimension, memtable^, last_sequence)

    def last_sequence(self) -> UInt64:
        return self._last_sequence

    def upsert(mut self, id: Int, var values: List[Float32]) raises:
        self._validate_vector(values)
        var sequence = self._next_sequence()
        var wal_values = _clone_vector(values)
        var record = WalRecord.upsert(sequence, id, wal_values^)
        append_wal(self._wal_path, self.dimension, record)
        self._memtable.apply_upsert(id, sequence, values^)
        self._last_sequence = sequence

    def delete(mut self, id: Int) raises:
        var sequence = self._next_sequence()
        var record = WalRecord.delete(sequence, id)
        append_wal(self._wal_path, self.dimension, record)
        self._memtable.apply_delete(id, sequence)
        self._last_sequence = sequence

    def search_dot(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, _DOT_METRIC)

    def search_l2(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, _L2_METRIC)

    def search_cosine(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, _COSINE_METRIC)

    def flush(mut self) raises:
        """Atomically publish a complete immutable live-state snapshot."""
        var entries = self._memtable.live_entries()
        var segment_name = "segment-" + String(self._last_sequence) + ".bin"
        var temporary_path = self.path + "/" + segment_name + ".tmp"
        var final_path = self.path + "/" + segment_name
        var checksum = write_segment(
            temporary_path,
            self.dimension,
            self._last_sequence,
            entries,
        )
        atomic_replace(temporary_path, final_path)
        sync_directory(self.path)
        var manifest = Manifest(
            self.dimension,
            self._last_sequence,
            checksum,
            segment_name,
        )
        publish_manifest(self.path, manifest)

    def _search(
        self, query: List[Float32], k: Int, metric: Int
    ) raises -> List[SearchResult]:
        self._validate_vector(query)
        if k <= 0:
            raise Error("k must be positive")
        var entries = self._memtable.live_entries()
        if len(entries) == 0:
            return List[SearchResult]()

        var result_count = k
        if result_count > len(entries):
            result_count = len(entries)
        var topk = BoundedTopK(
            result_count, smaller_is_better=metric == _L2_METRIC
        )
        for index in range(len(entries)):
            var score: Float32
            if metric == _DOT_METRIC:
                score = simd_dot_product(query, entries[index].values)
            elif metric == _L2_METRIC:
                score = simd_l2_squared_distance(query, entries[index].values)
            else:
                score = simd_cosine_similarity(query, entries[index].values)
            topk.offer(entries[index].id, score)

        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def _validate_vector(self, values: List[Float32]) raises:
        if len(values) != self.dimension:
            raise Error("vector dimension does not match collection")
        for value in values:
            if not isfinite(value):
                raise Error("vectors must contain only finite values")

    def _next_sequence(self) raises -> UInt64:
        if self._last_sequence == UInt64.MAX:
            raise Error("collection sequence exhausted")
        return self._last_sequence + 1


def _clone_vector(values: List[Float32]) -> List[Float32]:
    var result = List[Float32](capacity=len(values))
    for value in values:
        result.append(value)
    return result^
