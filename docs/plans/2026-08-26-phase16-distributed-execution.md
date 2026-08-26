# Phase 16: Distributed Replication and Query Execution

**Goal:** Add a fault-tolerant multi-process cluster that shards point IDs,
replicates acknowledged mutations through quorum consensus, fails over leaders,
and deterministically merges distributed vector/document queries while each
replica keeps authoritative storage/query semantics in the Mojo kernel.

## Process and storage model

Each `ReplicaServer` is an independent OS process with its own collection
directory, Akasha WAL/segments/manifest, and checksummed replicated-log journal.
RPC uses authenticated local sockets for the reference deployment; the protocol
is message-framed and transport-independent.

Cluster metadata is a versioned, checksummed, atomically replaced JSON envelope:
cluster ID, metadata epoch, shard count, hash/routing version, members, per-shard
term, leader, replicas, and placement epoch. Point IDs route by a stable unsigned
modulo function. Every request carries shard, term, placement epoch, and log
index. A replica rejects stale epochs/terms and writes for a shard it does not
own.

## Replicated mutation protocol

The elected leader assigns the next per-shard log index. `prepare` appends and
fsyncs one checksummed mutation entry on each reachable replica. After a quorum
prepares the identical `(term, index, mutation checksum)`, the coordinator sends
`commit`; replicas idempotently apply the mutation through their Mojo collection
and fsync a commit marker before acknowledgement. The client is acknowledged
only after a commit quorum. Duplicate prepare/commit delivery is idempotent;
conflicting content for an existing index is rejected.

If the leader is unavailable, the coordinator probes replicas, chooses the
eligible replica with the highest committed index (stable node-ID tie break),
increments the shard term and placement epoch, atomically publishes metadata,
and retries. Minority partitions cannot acknowledge. On restart, a replica
replays committed journal entries not yet reflected by its applied index and
then receives missing committed entries from the leader.

## Distributed query execution

The coordinator captures one metadata epoch, fans dense, approximate, sparse,
and metadata-filtered requests to one current replica per shard, retries only on
transport/stale-epoch errors, and rejects an epoch change during execution.
Metric-aware global Top-K sorts dot/cosine scores descending or squared-L2
ascending, then ascending point ID for ties.

Hybrid requests fan out dense and sparse candidate retrieval separately,
perform deterministic global rank lists, and run coordinator RRF with the same
rank constant and ascending-ID tie rule as Mojo. Result IDs can be resolved from
the owning shard.

## Catch-up and rebalancing

A replica catch-up copies a leader logical snapshot tagged with committed index,
then replays the committed log tail. Rebalancing installs that snapshot and tail
on the destination before atomically increasing the placement epoch and adding
it to the replica set. Removal occurs only after the new placement has quorum.
During the reference implementation's transfer critical section, writes for the
shard are serialized, making the captured tail boundary explicit.

## Fault tests

Tests spawn real replica OS processes and independent on-disk collections. They
cover:

- quorum acknowledgement and deterministic routing;
- duplicate delivery and replica restart recovery;
- leader process loss and term-incrementing failover;
- minority network partition and quorum rejection;
- stale term/placement rejection;
- lagging replica catch-up;
- snapshot-plus-log-tail rebalancing before ownership publication;
- dense/L2/cosine, sparse, hybrid, and metadata-filtered global merge;
- coordinator retry without double-applying a mutation.

## Completion gates

- No acknowledged mutation is lost after any single replica process failure in
  a three-replica shard.
- A minority partition cannot acknowledge writes.
- All replicas converge to identical logical point state and committed index.
- Distributed exact/filter/sparse results match a single-node oracle; hybrid
  matches coordinator global RRF.
- Stale epochs, conflicting duplicates, and corrupt replicated journals fail
  closed.
- The fault suite is genuinely multi-process; a mock-only test cannot satisfy
  completion.
