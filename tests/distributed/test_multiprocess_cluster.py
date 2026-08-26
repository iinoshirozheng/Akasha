import pytest

import akashadb
from akashadb.distributed import DistributedCluster, ProtocolError, QuorumUnavailable
from akashadb.distributed.protocol import ReplicatedEntry


def test_multi_process_replication_queries_and_duplicate_delivery(tmp_path) -> None:
    oracle = akashadb.Collection(tmp_path / "oracle", 2)
    with DistributedCluster(
        tmp_path / "cluster", 2, shard_count=2, replication_factor=3, node_count=3
    ) as cluster:
        points = [
            (0, [1.0, 0.0], "keep", [(7, 2.0)]),
            (1, [0.5, 0.5], "drop", [(7, 1.0)]),
            (2, [0.0, 1.0], "keep", [(9, 3.0)]),
            (3, [-1.0, 0.0], "keep", [(7, 0.5)]),
        ]
        for point_id, vector, group, sparse in points:
            fields = [akashadb.PayloadField("group", "string", group)]
            elements = [akashadb.SparseElement(term, weight) for term, weight in sparse]
            cluster.upsert(
                point_id,
                vector,
                fields,
                elements,
            )
            oracle.upsert(point_id, vector, fields)
            oracle.upsert_sparse(point_id, elements)

        exact_request = akashadb.SearchRequest("dot", 4, vector=[1.0, 0.0])
        exact = cluster.search(exact_request)
        assert [item.id for item in exact] == [0, 1, 2, 3]
        assert exact == oracle.search(exact_request)
        l2_request = akashadb.SearchRequest("l2", 3, vector=[0.0, 1.0])
        l2 = cluster.search(l2_request)
        assert [item.id for item in l2] == [2, 1, 0]
        assert l2 == oracle.search(l2_request)
        cosine_request = akashadb.SearchRequest("cosine", 3, vector=[1.0, 0.0])
        cosine = cluster.search(cosine_request)
        assert [item.id for item in cosine] == [0, 1, 2]
        assert cosine == oracle.search(cosine_request)
        filtered_request = akashadb.SearchRequest(
            "dot",
            4,
            vector=[1.0, 0.0],
            filter={
                "kind": "condition",
                "name": "group",
                "operator": "eq",
                "type": "string",
                "value": "keep",
            },
        )
        filtered = cluster.search(filtered_request)
        assert [item.id for item in filtered] == [0, 2, 3]
        assert filtered == oracle.search(filtered_request)
        sparse_request = akashadb.SearchRequest(
            "dot", 3, sparse=[akashadb.SparseElement(7, 1.0)], mode="sparse"
        )
        sparse = cluster.search(sparse_request)
        assert [item.id for item in sparse] == [0, 1, 3]
        assert sparse == oracle.search(sparse_request)
        hybrid_request = akashadb.SearchRequest(
            "dot",
            3,
            vector=[1.0, 0.0],
            sparse=[akashadb.SparseElement(7, 1.0)],
            mode="hybrid",
            fetch_k=4,
        )
        hybrid = cluster.search(hybrid_request)
        assert hybrid[0].id == 0
        oracle_hybrid = oracle.search(hybrid_request)
        assert [item.id for item in hybrid] == [item.id for item in oracle_hybrid]
        assert [item.score for item in hybrid] == pytest.approx(
            [item.score for item in oracle_hybrid]
        )

        first = cluster.upsert(8, [2.0, 0.0], request_id="same-request")
        duplicate = cluster.upsert(8, [2.0, 0.0], request_id="same-request")
        assert duplicate.index == first.index
        with pytest.raises(ProtocolError, match="conflicting"):
            cluster.upsert(8, [9.0, 0.0], request_id="same-request")

        for shard_id, placement in cluster.metadata.shards.items():
            logical_states = []
            for node in placement.replicas:
                assert cluster.replica_status(node, shard_id)["applied_index"] >= placement.committed_index
                logical_states.append(
                    cluster.debug_rpc(node, {"operation": "export", "shard_id": shard_id})[
                        "rows"
                    ]
                )
            assert all(state == logical_states[0] for state in logical_states)
    oracle.close()


def test_leader_loss_partition_stale_epoch_and_replica_catchup(tmp_path) -> None:
    with DistributedCluster(
        tmp_path / "faults", 1, shard_count=1, replication_factor=3, node_count=3
    ) as cluster:
        cluster.upsert(1, [1.0], request_id="initial")
        placement = cluster.metadata.shards[0]
        old_leader = placement.leader
        old_term = placement.term
        cluster.stop_node(old_leader)

        committed = cluster.upsert(2, [2.0], request_id="after-leader-loss")
        placement = cluster.metadata.shards[0]
        assert committed.term > old_term
        assert placement.leader != old_leader
        assert cluster.get(1)["vector"] == [1.0]
        assert cluster.get(2)["vector"] == [2.0]

        cluster.restart_node(old_leader)
        assert cluster.replica_status(old_leader, 0)["applied_index"] >= placement.committed_index

        victims = placement.replicas[:2]
        for node in victims:
            cluster.partition_node(node, True)
        with pytest.raises(QuorumUnavailable):
            cluster.upsert(3, [3.0], request_id="minority")
        cluster.partition_node(victims[0], False)
        cluster.upsert(3, [3.0], request_id="healed")
        cluster.partition_node(victims[1], False)

        placement = cluster.metadata.shards[0]
        target = placement.replicas[0]
        stale = ReplicatedEntry.create(
            0,
            placement.term,
            placement.placement_epoch - 1,
            placement.last_log_index + 10,
            "stale",
            {"operation": "delete", "id": 1},
        )
        with pytest.raises(ProtocolError, match="stale"):
            cluster.debug_rpc(
                target,
                {"operation": "prepare", "shard_id": 0, "entry": stale.to_dict()},
            )


def test_snapshot_tail_rebalancing_precedes_new_replica_ownership(tmp_path) -> None:
    with DistributedCluster(
        tmp_path / "rebalance", 2, shard_count=1, replication_factor=3, node_count=4
    ) as cluster:
        for point_id in range(12):
            cluster.upsert(point_id, [float(point_id), 1.0])
        assert "n3" not in cluster.metadata.shards[0].replicas
        before_epoch = cluster.metadata.shards[0].placement_epoch

        cluster.rebalance_add_replica(0, "n3")

        placement = cluster.metadata.shards[0]
        assert "n3" in placement.replicas
        assert placement.placement_epoch == before_epoch + 1
        assert cluster.replica_status("n3", 0)["applied_index"] >= placement.committed_index
        assert cluster.debug_rpc(
            "n3", {"operation": "get", "shard_id": 0, "id": 11}
        )["vector"] == [11.0, 1.0]

        leader = placement.leader
        cluster.stop_node(leader)
        results = cluster.search(
            akashadb.SearchRequest("dot", 3, vector=[1.0, 0.0])
        )
        assert [item.id for item in results] == [11, 10, 9]


def test_coordinator_retry_after_lost_commit_responses_is_idempotent(tmp_path) -> None:
    with DistributedCluster(
        tmp_path / "retry", 1, shard_count=1, replication_factor=3, node_count=3
    ) as cluster:
        placement = cluster.metadata.shards[0]
        for node in placement.replicas[:2]:
            cluster.inject_drop_commit_response(node)

        with pytest.raises(QuorumUnavailable, match="commit quorum"):
            cluster.upsert(5, [5.0], request_id="retry-me")
        prepared_index = cluster.metadata.request_table["retry-me"]["index"]
        sequences_before = {
            node: cluster.debug_rpc(
                node, {"operation": "get", "shard_id": 0, "id": 5}
            )["sequence"]
            for node in placement.replicas
        }

        committed = cluster.upsert(5, [5.0], request_id="retry-me")

        assert committed.index == prepared_index
        sequences_after = {
            node: cluster.debug_rpc(
                node, {"operation": "get", "shard_id": 0, "id": 5}
            )["sequence"]
            for node in placement.replicas
        }
        assert sequences_after == sequences_before


def test_cluster_metadata_and_acknowledged_state_survive_full_restart(tmp_path) -> None:
    root = tmp_path / "restart"
    cluster = DistributedCluster(
        root, 2, shard_count=2, replication_factor=3, node_count=3
    )
    committed = cluster.upsert(7, [7.0, 1.0], request_id="durable-request")
    epoch = cluster.metadata.epoch
    cluster.close()

    reopened = DistributedCluster(
        root, 2, shard_count=2, replication_factor=3, node_count=3
    )
    try:
        assert reopened.metadata.epoch > epoch
        assert reopened.get(7)["vector"] == [7.0, 1.0]
        duplicate = reopened.upsert(7, [7.0, 1.0], request_id="durable-request")
        assert duplicate.index == committed.index
    finally:
        reopened.close()
