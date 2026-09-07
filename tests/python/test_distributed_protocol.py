import json

import pytest

from akashadb.distributed.protocol import (
    ClusterMetadata,
    ProtocolError,
    ReplicaJournal,
    ReplicatedEntry,
    ShardPlacement,
)
from akashadb import CollectionConfig


def _metadata() -> ClusterMetadata:
    config = CollectionConfig.defaults(
        3, ann_metric="cosine", level_seed=77
    ).to_kernel()
    config["level_seed"] = 77
    config["fingerprint"] = 123
    return ClusterMetadata(
        cluster_id="test",
        dimension=3,
        shard_count=1,
        replication_factor=3,
        epoch=1,
        members={
            "n0": ("127.0.0.1", 1),
            "n1": ("127.0.0.1", 2),
            "n2": ("127.0.0.1", 3),
        },
        shards={0: ShardPlacement(0, 1, 1, "n0", ["n0", "n1", "n2"])},
        collection_config=config,
    )


def test_cluster_metadata_round_trip_and_checksum_failure(tmp_path) -> None:
    path = tmp_path / "cluster.json"
    expected = _metadata()
    expected.publish(path)
    actual = ClusterMetadata.load(path)
    assert actual.to_payload() == expected.to_payload()
    assert actual.collection_config == expected.collection_config

    value = json.loads(path.read_text())
    value["payload"]["epoch"] = 7
    path.write_text(json.dumps(value))
    with pytest.raises(ProtocolError, match="checksum"):
        ClusterMetadata.load(path)


def test_replica_journal_is_idempotent_strict_and_repairs_torn_tail(tmp_path) -> None:
    path = tmp_path / "replica.log"
    journal = ReplicaJournal(path)
    entry = ReplicatedEntry.create(
        0,
        1,
        1,
        1,
        "request-1",
        {"operation": "upsert", "id": 1, "vector": [1.0]},
    )
    journal.prepare(entry)
    journal.prepare(entry)
    journal.commit(1)
    journal.commit(1)
    assert [item.index for item in journal.committed_after(0)] == [1]

    conflicting = ReplicatedEntry.create(
        0,
        1,
        1,
        1,
        "request-2",
        {"operation": "delete", "id": 1},
    )
    with pytest.raises(ProtocolError, match="conflicting"):
        journal.prepare(conflicting)

    with path.open("ab") as output:
        output.write(b'{"version":1')
    reopened = ReplicaJournal(path)
    assert [item.index for item in reopened.committed_after(0)] == [1]
    assert path.read_bytes().endswith(b"\n")

    data = path.read_bytes()
    value = bytearray(data)
    value[20] ^= 1
    path.write_bytes(value)
    with pytest.raises(ProtocolError, match="corruption"):
        ReplicaJournal(path)


def test_metadata_without_collection_identity_is_explicitly_unsupported() -> None:
    payload = _metadata().to_payload()
    del payload["collection_config"]
    with pytest.raises(ProtocolError, match="collection config"):
        ClusterMetadata.from_payload(payload)


@pytest.mark.parametrize("field", ["ann_metric", "m", "level_seed", "fingerprint"])
def test_metadata_rejects_incomplete_collection_identity(field) -> None:
    payload = _metadata().to_payload()
    del payload["collection_config"][field]
    with pytest.raises(ProtocolError, match="collection config fields"):
        ClusterMetadata.from_payload(payload)
