# Distributed Akasha reference cluster

Phase 16 provides a real multi-process reference cluster. Every replica process
owns independent Akasha WAL/segments/manifests; cluster orchestration does not
replace Mojo storage or query semantics.

```python
from akashadb import DistributedCluster, PayloadField, SearchRequest

with DistributedCluster(
    "./cluster",
    dimension=384,
    shard_count=4,
    replication_factor=3,
    node_count=3,
) as cluster:
    cluster.upsert(
        42,
        embedding,
        [PayloadField("chunk", "string", "owned text")],
        request_id="document-42-version-1",
    )
    results = cluster.search(SearchRequest("cosine", 10, vector=query))
```

## Routing and replication

Routing version 1 treats the signed point ID as unsigned 64-bit and applies
modulo `shard_count`. Cluster metadata records every shard's term, placement
epoch, leader, replicas, allocated log index, and committed index.

The leader proposes a mutation at one per-shard index. Each replica validates
term/placement, appends and fsyncs a checksummed prepare record, then applies the
committed mutation through its local Mojo collection and fsyncs a commit marker.
The coordinator acknowledges only after prepare and commit quorums. Request IDs
are persisted in cluster metadata: identical retries return the original commit;
conflicting reuse fails closed.

An unavailable leader triggers a quorum probe. The caught-up candidate with the
highest applied index wins, with ascending node ID as deterministic tie break.
The shard term and placement epoch increment before retries. A minority network
partition cannot elect or acknowledge.

## Query execution

The coordinator selects a caught-up replica for each shard and fans out the same
typed `SearchRequest`. Exact, approximate, sparse, and metadata-filtered results
use metric-aware global Top-K: L2 ascending, other scores descending, and point
ID ascending for ties.

Hybrid search globally merges dense and sparse rank lists before applying RRF,
so local shard ranks do not leak into the final order. The metadata epoch is
checked across execution; a concurrent placement change fails the query rather
than mixing epochs.

## Catch-up, failover, and rebalancing

Restarted replicas reopen their local collection, repair a torn replicated-log
tail, replay durable commits not reflected by the applied-index marker, and fetch
missing committed entries from the leader.

`rebalance_add_replica(shard, node)` exports a leader logical snapshot tagged by
its applied index, installs it on the destination, replays the committed tail,
and only then publishes the higher placement epoch and new ownership. The
reference transfer holds the coordinator shard-write lock, so the tail is an
explicit (normally empty) boundary rather than an implicit race.

## Deployment boundary

The included transport uses authenticated `multiprocessing.connection` sockets
on loopback and is designed for correctness exercises, local fault injection,
and development. An internet-facing deployment still needs TLS/mTLS, external
identity, admission control, independent coordinator processes, and a production
membership service. These transport concerns do not change the journal,
consensus, routing, or deterministic merge contracts tested here.

Run the real process fault suite with:

```bash
pixi run test-distributed
```
