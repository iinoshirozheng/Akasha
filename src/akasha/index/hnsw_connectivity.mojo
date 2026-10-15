"""Qdrant GraphLayersBuilder::subgraph_connectivity (21db2f3, Apache-2.0).

The traversal/retry budget is upstream's. A deterministic SplitMix64 stream
replaces rand's platform-specific generator, as in Akasha's level sampling.
Rows are the build's current link union, including earlier payload blocks.
"""

from akasha.index.hnsw_entries import HnswEntryPoints
from akasha.index.hnsw_level import splitmix64
from akasha.index.hnsw_storage import HnswStorage
from akasha.query.control import QueryControl


struct HnswBuildRandom:
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_u64(mut self) -> UInt64:
        var value = splitmix64(self.state)
        self.state += UInt64(0x9E3779B97F4A7C15)
        return value

    def index(mut self, count: Int) -> Int:
        var bound = UInt64(count)
        var limit = UInt64.MAX - UInt64.MAX % bound
        var value = self.next_u64()
        while value >= limit:
            value = self.next_u64()
        return Int(value % bound)

    def coin(mut self) -> Float32:
        return Float32(self.next_u64() >> UInt64(40)) / Float32(16777216)


def subgraph_connectivity(
    graph: HnswStorage, entries: HnswEntryPoints,
    rows: List[List[UInt32]], points: List[UInt32], q: Float32,
    mut rng: HnswBuildRandom, control: Optional[QueryControl] = None,
) raises -> Float32:
    if len(points) == 0:
        return 1.0
    var selected = List[Bool](length=graph.slot_count(), fill=False)
    for slot in points:
        selected[Int(slot)] = True
    var eligible = List[UInt32]()
    for entry in entries.primary:
        if selected[Int(entry.slot)]:
            eligible.append(entry.slot)
    if len(eligible) == 0:
        for item in entries.extra._heap:
            if selected[Int(item.slot)]:
                eligible.append(item.slot)
    var entry = points[0]
    if len(eligible) > 0:
        entry = eligible[rng.index(len(eligible))]
    else:
        for slot in points:
            if graph.level(slot) >= graph.level(entry):
                entry = slot
    # Upstream connectivity uses the point's highest layer, independently of
    # the entry's search level (payload entries themselves are level zero).
    var entry_layer = graph.level(entry)
    var visited = List[Bool](length=graph.slot_count(), fill=False)
    var queue = List[UInt32]()
    var reached = 1
    var spent = 0
    while True:
        if control:
            control.value().checkpoint(0)
        var before = spent
        visited[Int(entry)] = True
        var previous: List[UInt32] = [entry]
        for layer in range(entry_layer, -1, -1):
            for slot in previous:
                queue.append(slot)
            while len(queue) > 0:
                if control:
                    control.value().checkpoint(0)
                var current = queue.pop()
                for link in rows[graph.neighbor_count_bases[Int(current)] + layer]:
                    spent += 1
                    if rng.coin() < q:
                        continue
                    if not visited[Int(link)] and selected[Int(link)]:
                        visited[Int(link)] = True
                        reached += 1
                        queue.append(link)
                        previous.append(link)
        if spent > 64 or spent == before:
            break
        queue.clear()
        reached = 1
        for ordinal in range(len(visited)):
            visited[ordinal] = False
    return Float32(reached) / Float32(len(points))
