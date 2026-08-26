# Distributed metadata and replicated journal formats

Both formats are UTF-8 canonical JSON envelopes:

```json
{"checksum": 0, "payload": {}, "version": 1}
```

`checksum` is CRC32 over the canonical payload bytes (sorted keys, compact
separators). Unknown versions, malformed payloads, and checksum mismatches fail
closed.

## Cluster metadata v1

The atomically replaced and fsynced metadata payload contains:

- cluster ID, vector dimension, metadata epoch, routing version;
- shard and replication counts;
- member node IDs and current authenticated-RPC addresses;
- each shard's ID, term, placement epoch, leader, replica set, last allocated
  log index, and committed index;
- durable request-ID deduplication entries with mutation checksum and status.

The metadata validator requires complete shard coverage, known unique replicas,
a leader in the replica set, positive epochs, and `committed <= allocated`.

## Replica journal v1

The journal is append-only JSON Lines. Every line is independently enveloped and
fsynced. Records are:

- `prepare`: full replicated entry with shard, term, placement epoch, index,
  request ID, typed mutation, and mutation CRC32;
- `commit`: index of a prior prepared entry;
- `snapshot`: highest index represented by an installed logical snapshot.

An incomplete final line is treated as a torn tail, truncated, and fsynced.
Every complete bad line is corruption. Duplicate prepares/commits are
idempotent; a different mutation checksum at an existing index is rejected.
