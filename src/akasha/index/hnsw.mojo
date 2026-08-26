from akasha.compute.simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult
from akasha.storage.checksum import BinaryReader, BinaryWriter
from std.math import isfinite


comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


def deterministic_level(id: Int, maximum: Int) -> Int:
    """Generate a stable geometric-like level from the point ID."""
    if maximum <= 0:
        return 0
    var value = id
    if value < 0:
        value = -(value + 1)
    var level = 0
    while level < maximum and value % 2 == 0:
        level += 1
        value = value // 2
        if value == 0:
            break
    return level


struct _NeighborLevel(Movable):
    var indices: List[Int]

    def __init__(out self):
        self.indices = List[Int]()


struct _HnswNode(Movable):
    var id: Int
    var vector: List[Float32]
    var level: Int
    var neighbors: List[_NeighborLevel]

    def __init__(out self, id: Int, var vector: List[Float32], level: Int):
        self.id = id
        self.vector = vector^
        self.level = level
        self.neighbors = List[_NeighborLevel](capacity=level + 1)
        for _ in range(level + 1):
            self.neighbors.append(_NeighborLevel())


struct _Candidate(TrivialRegisterPassable, Writable):
    var node_index: Int
    var score: Float32
    var expanded: Bool

    def __init__(out self, node_index: Int, score: Float32):
        self.node_index = node_index
        self.score = score
        self.expanded = False


struct HnswIndex:
    """Deterministic in-memory hierarchical navigable small-world graph."""

    var dimension: Int
    var m: Int
    var max_level: Int
    var _nodes: List[_HnswNode]
    var _entry_index: Int
    var _entry_level: Int

    def __init__(
        out self, dimension: Int, *, m: Int = 8, max_level: Int = 12
    ) raises:
        if dimension <= 0:
            raise Error("HNSW dimension must be positive")
        if m <= 0:
            raise Error("HNSW neighbor bound must be positive")
        if max_level < 0:
            raise Error("HNSW maximum level cannot be negative")
        self.dimension = dimension
        self.m = m
        self.max_level = max_level
        self._nodes = List[_HnswNode]()
        self._entry_index = -1
        self._entry_level = -1

    def point_count(self) -> Int:
        return len(self._nodes)

    def maximum_neighbor_count(self) -> Int:
        var maximum = 0
        for node_index in range(len(self._nodes)):
            for level in range(len(self._nodes[node_index].neighbors)):
                var count = len(
                    self._nodes[node_index].neighbors[level].indices
                )
                if count > maximum:
                    maximum = count
        return maximum

    def encode_cache_payload(self) raises -> List[UInt8]:
        """Serialize this derived graph; the outer cache owns integrity."""
        if self.m > Int(UInt16.MAX) or self.max_level > Int(UInt16.MAX):
            raise Error("HNSW configuration exceeds cache format")
        if len(self._nodes) > Int(UInt32.MAX):
            raise Error("HNSW graph exceeds cache format")
        var writer = BinaryWriter()
        writer.write_u16(UInt16(self.m))
        writer.write_u16(UInt16(self.max_level))
        writer.write_u32(UInt32(len(self._nodes)))
        writer.write_i64(Int64(self._entry_index))
        writer.write_i64(Int64(self._entry_level))
        for node_index in range(len(self._nodes)):
            writer.write_i64(Int64(self._nodes[node_index].id))
            writer.write_u16(UInt16(self._nodes[node_index].level))
            writer.write_u16(UInt16(0))
            for value in self._nodes[node_index].vector:
                writer.write_f32(value)
            for level in range(self._nodes[node_index].level + 1):
                var count = len(
                    self._nodes[node_index].neighbors[level].indices
                )
                if count > Int(UInt16.MAX):
                    raise Error("HNSW neighbor list exceeds cache format")
                writer.write_u16(UInt16(count))
                writer.write_u16(UInt16(0))
                for neighbor in self._nodes[
                    node_index
                ].neighbors[level].indices:
                    if neighbor < 0 or neighbor > Int(UInt32.MAX):
                        raise Error("HNSW neighbor ordinal exceeds cache format")
                    writer.write_u32(UInt32(neighbor))
        return writer.take_bytes()

    @staticmethod
    def decode_cache_payload(
        dimension: Int, var payload: List[UInt8]
    ) raises -> HnswIndex:
        var reader = BinaryReader(payload^)
        var m = Int(reader.read_u16())
        var max_level = Int(reader.read_u16())
        var point_count = Int(reader.read_u32())
        if point_count > 10_000_000:
            raise Error("HNSW cache point count exceeds limit")
        var entry_index = Int(reader.read_i64())
        var entry_level = Int(reader.read_i64())
        var index = HnswIndex(dimension, m=m, max_level=max_level)
        for node_index in range(point_count):
            var id = Int(reader.read_i64())
            for previous in range(node_index):
                if index._nodes[previous].id == id:
                    raise Error("HNSW cache contains duplicate point IDs")
            var level = Int(reader.read_u16())
            if reader.read_u16() != UInt16(0) or level > max_level:
                raise Error("HNSW cache node header is invalid")
            var vector = List[Float32](capacity=dimension)
            for _ in range(dimension):
                var value = reader.read_f32()
                if not isfinite(value):
                    raise Error("HNSW cache vector must be finite")
                vector.append(value)
            var node = _HnswNode(id, vector^, level)
            for graph_level in range(level + 1):
                var neighbor_count = Int(reader.read_u16())
                if (
                    reader.read_u16() != UInt16(0)
                    or neighbor_count > m
                ):
                    raise Error("HNSW cache neighbor header is invalid")
                for _ in range(neighbor_count):
                    var neighbor = Int(reader.read_u32())
                    if neighbor < 0 or neighbor >= point_count:
                        raise Error("HNSW cache neighbor ordinal is invalid")
                    node.neighbors[graph_level].indices.append(neighbor)
            index._nodes.append(node^)
        if reader.remaining() != 0:
            raise Error("HNSW cache has trailing bytes")
        if point_count == 0:
            if entry_index != -1 or entry_level != -1:
                raise Error("empty HNSW cache entry point is invalid")
        elif (
            entry_index < 0
            or entry_index >= point_count
            or entry_level < 0
            or entry_level > index._nodes[entry_index].level
        ):
            raise Error("HNSW cache entry point is invalid")
        index._entry_index = entry_index
        index._entry_level = entry_level
        return index^

    def add(mut self, id: Int, values: List[Float32]) raises:
        if len(values) != self.dimension:
            raise Error("vector dimension does not match HNSW index")
        for value in values:
            if not isfinite(value):
                raise Error("HNSW vectors must contain only finite values")
        if self._find_index(id) >= 0:
            raise Error("HNSW point IDs must be unique")

        var owned = _clone_vector(values)
        var level = deterministic_level(id, self.max_level)
        var new_index = len(self._nodes)
        self._nodes.append(_HnswNode(id, owned^, level))

        for graph_level in range(level + 1):
            var candidate_count = 0
            for existing in range(new_index):
                if self._nodes[existing].level >= graph_level:
                    candidate_count += 1
            if candidate_count == 0:
                continue
            var capacity = self.m
            if capacity > candidate_count:
                capacity = candidate_count
            var nearest = BoundedTopK(capacity, smaller_is_better=True)
            for existing in range(new_index):
                if self._nodes[existing].level < graph_level:
                    continue
                nearest.offer(
                    existing,
                    simd_l2_squared_distance(
                        self._nodes[new_index].vector,
                        self._nodes[existing].vector,
                    ),
                )
            var selected = nearest.sorted_entries()
            for candidate in selected:
                var existing = candidate.id
                self._nodes[new_index].neighbors[graph_level].indices.append(
                    existing
                )
                self._nodes[existing].neighbors[graph_level].indices.append(
                    new_index
                )
                self._prune_neighbors(existing, graph_level)

        if self._entry_index < 0 or level > self._entry_level:
            self._entry_index = new_index
            self._entry_level = level

    def search_dot(
        self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, ef_search, _DOT_METRIC)

    def search_l2(
        self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, ef_search, _L2_METRIC)

    def search_cosine(
        self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, ef_search, _COSINE_METRIC)

    def _search(
        self, query: List[Float32], k: Int, ef_search: Int, metric: Int
    ) raises -> List[SearchResult]:
        if len(query) != self.dimension:
            raise Error("query dimension does not match HNSW index")
        if k <= 0:
            raise Error("k must be positive")
        if ef_search <= 0:
            raise Error("ef_search must be positive")
        if len(self._nodes) == 0:
            return List[SearchResult]()

        var current = self._entry_index
        var current_score = self._score(metric, query, current)
        var level = self._entry_level
        while level > 0:
            var changed = True
            while changed:
                changed = False
                if self._nodes[current].level < level:
                    break
                var links = self._nodes[current].neighbors[level].indices.copy()
                for neighbor in links:
                    var score = self._score(metric, query, neighbor)
                    if self._better(
                        metric, score, neighbor, current_score, current
                    ):
                        current = neighbor
                        current_score = score
                        changed = True
            level -= 1

        var visited = List[Bool](length=len(self._nodes), fill=False)
        var candidates = List[_Candidate]()
        visited[current] = True
        candidates.append(_Candidate(current, current_score))
        var breadth = ef_search
        if breadth < k:
            breadth = k
        var expansions = 0
        while expansions < breadth:
            var best = -1
            for index in range(len(candidates)):
                if candidates[index].expanded:
                    continue
                if best < 0 or self._better(
                    metric,
                    candidates[index].score,
                    candidates[index].node_index,
                    candidates[best].score,
                    candidates[best].node_index,
                ):
                    best = index
            if best < 0:
                break
            candidates[best].expanded = True
            expansions += 1
            var node_index = candidates[best].node_index
            for neighbor in self._nodes[node_index].neighbors[0].indices:
                if visited[neighbor]:
                    continue
                visited[neighbor] = True
                candidates.append(
                    _Candidate(neighbor, self._score(metric, query, neighbor))
                )

        var result_count = k
        if result_count > len(candidates):
            result_count = len(candidates)
        var topk = BoundedTopK(
            result_count, smaller_is_better=metric == _L2_METRIC
        )
        for candidate in candidates:
            topk.offer(self._nodes[candidate.node_index].id, candidate.score)
        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def _prune_neighbors(mut self, node_index: Int, level: Int) raises:
        var links = self._nodes[node_index].neighbors[level].indices.copy()
        if len(links) <= self.m:
            return
        var nearest = BoundedTopK(self.m, smaller_is_better=True)
        for neighbor in links:
            nearest.offer(
                neighbor,
                simd_l2_squared_distance(
                    self._nodes[node_index].vector,
                    self._nodes[neighbor].vector,
                ),
            )
        var retained = nearest.sorted_entries()
        var pruned = List[Int](capacity=len(retained))
        for entry in retained:
            pruned.append(entry.id)
        self._nodes[node_index].neighbors[level].indices = pruned^

    def _score(
        self, metric: Int, query: List[Float32], node_index: Int
    ) raises -> Float32:
        if metric == _DOT_METRIC:
            return simd_dot_product(query, self._nodes[node_index].vector)
        if metric == _L2_METRIC:
            return simd_l2_squared_distance(
                query, self._nodes[node_index].vector
            )
        return simd_cosine_similarity(query, self._nodes[node_index].vector)

    def _better(
        self,
        metric: Int,
        lhs_score: Float32,
        lhs_index: Int,
        rhs_score: Float32,
        rhs_index: Int,
    ) -> Bool:
        if lhs_score == rhs_score:
            return self._nodes[lhs_index].id < self._nodes[rhs_index].id
        if metric == _L2_METRIC:
            return lhs_score < rhs_score
        return lhs_score > rhs_score

    def _find_index(self, id: Int) -> Int:
        for index in range(len(self._nodes)):
            if self._nodes[index].id == id:
                return index
        return -1


def _clone_vector(values: List[Float32]) -> List[Float32]:
    var result = List[Float32](capacity=len(values))
    for value in values:
        result.append(value)
    return result^
