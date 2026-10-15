"""Durable acknowledgement and atomic point application at replica boundaries."""
import os
import stat

import pytest

from akashadb import CollectionConfig
from akashadb.database import _kernel_module
from akashadb.distributed.protocol import ProtocolError, ReplicaJournal, ReplicatedEntry
from akashadb.distributed.replica import ReplicaShard, _publish_checked


def _entry(index=1):
    return ReplicatedEntry.create(0, 1, 1, index, f"request-{index}", {
        "operation": "upsert", "id": 7, "vector": [1.0, 0.0],
        "fields": [], "sparse": [{"term_id": 4, "weight": 0.0}],
    })


def test_replica_applies_dense_sparse_in_one_durable_point(tmp_path):
    config = dict(_kernel_module().validate_collection_config(2, CollectionConfig.defaults(2).to_kernel()))
    shard = ReplicaShard(tmp_path / "shard", 0, 2, config)
    try:
        shard.configure(1, 1)
        shard.commit(_entry())
        assert shard.collection.last_sequence == 1
        point = shard.collection.get_point(7)
        assert point.sparse[0].weight == 0.0
        shard.commit(_entry())
        assert shard.collection.last_sequence == 1
    finally:
        shard.close()
    reopened = ReplicaShard(tmp_path / "shard", 0, 2, config)
    try:
        assert reopened.applied_index == 1
        assert reopened.collection.last_sequence == 1
        assert reopened.collection.get_point(7).sparse[0].weight == 0.0
    finally:
        reopened.close()


def test_checked_publication_syncs_file_then_directory(tmp_path, monkeypatch):
    kinds = []
    original = os.fsync
    def sync(fd):
        kinds.append("directory" if stat.S_ISDIR(os.fstat(fd).st_mode) else "file")
        original(fd)
    monkeypatch.setattr(os, "fsync", sync)
    _publish_checked(tmp_path / "state.json", {"term": 1})
    assert kinds == ["file", "directory"]


@pytest.mark.parametrize("failed_sync", ["file", "directory"])
def test_uncertain_journal_append_blocks_acknowledgement_until_reopen(tmp_path, monkeypatch, failed_sync):
    journal = ReplicaJournal(tmp_path / "replica.log")
    original = os.fsync
    def fail(fd):
        kind = "directory" if stat.S_ISDIR(os.fstat(fd).st_mode) else "file"
        if kind == failed_sync:
            raise OSError("injected sync failure")
        original(fd)
    with monkeypatch.context() as patch:
        patch.setattr(os, "fsync", fail)
        with pytest.raises(OSError, match="injected"):
            journal.prepare(_entry())
    for operation in (lambda: journal.prepare(_entry()), lambda: journal.commit(1),
                      lambda: journal.install_snapshot(1)):
        with pytest.raises(ProtocolError, match="requires recovery"):
            operation()
    recovered = ReplicaJournal(journal.path)
    recovered.prepare(_entry())
    recovered.commit(1)
    assert [entry.index for entry in recovered.committed_after(0)] == [1]
