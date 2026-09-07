"""Quorum replication, failover, sharding, and distributed query merge."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
from threading import RLock
from typing import Any
import uuid

from akashadb.database import _kernel_module
from akashadb.models import (
    CollectionConfig,
    PayloadField,
    SearchRequest,
    SearchResult,
    SparseElement,
)

from .protocol import (
    ClusterMetadata,
    ProtocolError,
    ReplicatedEntry,
    ShardPlacement,
    payload_checksum,
)
from .replica import ReplicaProcess, ReplicaUnavailable, StaleEpochError


class QuorumUnavailable(RuntimeError):
    pass


class ClusterClosedError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class CommitResult:
    shard_id: int
    term: int
    index: int
    request_id: str


class DistributedCluster:
    """Reference multi-process Akasha cluster with replicated shard logs."""

    def __init__(
        self,
        root: str | Path,
        dimension: int,
        *,
        config: CollectionConfig | dict[str, Any] | None = None,
        shard_count: int = 2,
        replication_factor: int = 3,
        node_count: int = 3,
        cluster_id: str | None = None,
    ) -> None:
        if dimension <= 0 or shard_count <= 0:
            raise ValueError("cluster dimension and shard count must be positive")
        if replication_factor <= 0 or node_count < replication_factor:
            raise ValueError("node count must cover replication factor")
        requested = CollectionConfig.from_options(dimension, config)
        canonical_config = dict(
            _kernel_module().validate_collection_config(
                dimension, requested.to_kernel()
            )
        )
        self._config = CollectionConfig.from_kernel(canonical_config)
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.metadata_path = self.root / "cluster-metadata.json"
        self.dimension = dimension
        self._lock = RLock()
        self._closed = False
        self._last_search_stats: dict[str, Any] = {}
        identity = cluster_id or uuid.uuid4().hex
        self.authkey = hashlib.sha256(identity.encode()).digest()
        self.nodes: dict[str, ReplicaProcess] = {
            f"n{index}": ReplicaProcess(
                f"n{index}",
                self.root / "nodes" / f"n{index}",
                dimension,
                canonical_config,
                self.authkey,
            )
            for index in range(node_count)
        }
        members = {node: process.start() for node, process in self.nodes.items()}

        if self.metadata_path.exists():
            metadata = ClusterMetadata.load(self.metadata_path)
            if metadata.dimension != dimension:
                self.close()
                raise ProtocolError("cluster reopen dimension mismatch")
            if metadata.collection_config != canonical_config:
                self.close()
                raise ProtocolError("cluster reopen collection config mismatch")
            if set(metadata.members) != set(members):
                self.close()
                raise ProtocolError("cluster reopen member set mismatch")
            metadata.members = members
            metadata.epoch += 1
            self.metadata = metadata
        else:
            node_ids = sorted(members)
            shards: dict[int, ShardPlacement] = {}
            for shard_id in range(shard_count):
                replicas = [
                    node_ids[(shard_id + offset) % len(node_ids)]
                    for offset in range(replication_factor)
                ]
                shards[shard_id] = ShardPlacement(
                    shard_id, 1, 1, replicas[0], replicas
                )
            self.metadata = ClusterMetadata(
                identity,
                dimension,
                shard_count,
                replication_factor,
                1,
                members,
                shards,
                canonical_config,
            )
        self._publish_metadata()
        try:
            self._configure_all()
            for shard_id, placement in self.metadata.shards.items():
                for node in placement.replicas:
                    self.catch_up(node, shard_id)
        except BaseException:
            self.close()
            raise

    def _ensure_open(self) -> None:
        if self._closed:
            raise ClusterClosedError("distributed cluster is closed")

    def _publish_metadata(self) -> None:
        self.metadata.publish(self.metadata_path)

    def _rpc(self, node: str, request: dict[str, Any]) -> Any:
        return self.nodes[node].rpc(request)

    def _configure(self, node: str, placement: ShardPlacement) -> Any:
        return self._rpc(
            node,
            {
                "operation": "configure",
                "shard_id": placement.shard_id,
                "term": placement.term,
                "placement_epoch": placement.placement_epoch,
            },
        )

    def _configure_all(self) -> None:
        for placement in self.metadata.shards.values():
            for node in placement.replicas:
                self._configure(node, placement)

    def route(self, point_id: int) -> int:
        self._ensure_open()
        unsigned = point_id & 0xFFFFFFFFFFFFFFFF
        return unsigned % self.metadata.shard_count

    def collection_config(self) -> CollectionConfig:
        return CollectionConfig.from_kernel(dict(self.metadata.collection_config))

    def last_search_stats(self) -> dict[str, Any]:
        return dict(self._last_search_stats)

    def upsert(
        self,
        point_id: int,
        vector: list[float],
        fields: list[PayloadField] | None = None,
        sparse: list[SparseElement] | None = None,
        *,
        request_id: str | None = None,
    ) -> CommitResult:
        mutation = {
            "operation": "upsert",
            "id": point_id,
            "vector": [float(value) for value in vector],
            "fields": [field.to_kernel() for field in (fields or [])],
            "sparse": [element.to_kernel() for element in (sparse or [])],
        }
        return self._write(mutation, request_id or uuid.uuid4().hex)

    def delete(self, point_id: int, *, request_id: str | None = None) -> CommitResult:
        return self._write(
            {"operation": "delete", "id": point_id},
            request_id or uuid.uuid4().hex,
        )

    def _write(
        self, mutation: dict[str, Any], request_id: str, *, retry: int = 0
    ) -> CommitResult:
        with self._lock:
            self._ensure_open()
            shard_id = self.route(int(mutation["id"]))
            checksum = payload_checksum(mutation)
            duplicate = self.metadata.request_table.get(request_id)
            if duplicate is not None:
                if int(duplicate["checksum"]) != checksum:
                    raise ProtocolError("request ID reused with conflicting mutation")
                if duplicate.get("status") == "committed":
                    return CommitResult(
                        shard_id,
                        int(duplicate["term"]),
                        int(duplicate["index"]),
                        request_id,
                    )
                placement = self.metadata.shards[shard_id]
                self._ensure_leader(placement)
                placement = self.metadata.shards[shard_id]
                entry = ReplicatedEntry.create(
                    shard_id,
                    placement.term,
                    placement.placement_epoch,
                    int(duplicate["index"]),
                    request_id,
                    mutation,
                )
                return self._commit_prepared(placement, entry, checksum)

            placement = self.metadata.shards[shard_id]
            self._ensure_leader(placement)
            placement = self.metadata.shards[shard_id]
            placement.last_log_index += 1
            index = placement.last_log_index
            self.metadata.epoch += 1
            self._publish_metadata()
            entry = ReplicatedEntry.create(
                shard_id,
                placement.term,
                placement.placement_epoch,
                index,
                request_id,
                mutation,
            )

            prepared: list[str] = []
            for node in placement.replicas:
                try:
                    response = self._rpc(
                        node,
                        {
                            "operation": "prepare",
                            "shard_id": shard_id,
                            "entry": entry.to_dict(),
                        },
                    )
                    if int(response["checksum"]) == entry.mutation_checksum:
                        prepared.append(node)
                except (ReplicaUnavailable, StaleEpochError, ProtocolError):
                    continue
            if placement.leader not in prepared:
                if retry >= 2:
                    raise QuorumUnavailable("leader failed during replication")
                self._elect_leader(placement)
                return self._write(mutation, request_id, retry=retry + 1)
            if len(prepared) < placement.quorum:
                raise QuorumUnavailable("mutation did not reach prepare quorum")

            self.metadata.request_table[request_id] = {
                "shard_id": shard_id,
                "term": entry.term,
                "index": index,
                "checksum": checksum,
                "status": "prepared",
            }
            self.metadata.epoch += 1
            self._publish_metadata()
            return self._commit_prepared(placement, entry, checksum)

    def _commit_prepared(
        self,
        placement: ShardPlacement,
        entry: ReplicatedEntry,
        checksum: int,
    ) -> CommitResult:
        committed: list[str] = []
        for node in placement.replicas:
            try:
                self._rpc(
                    node,
                    {
                        "operation": "commit",
                        "shard_id": entry.shard_id,
                        "entry": entry.to_dict(),
                    },
                )
                committed.append(node)
            except (ReplicaUnavailable, StaleEpochError, ProtocolError):
                continue
        if len(committed) < placement.quorum:
            raise QuorumUnavailable("mutation did not reach commit quorum")

        placement.committed_index = max(placement.committed_index, entry.index)
        self.metadata.request_table[entry.request_id] = {
            "shard_id": entry.shard_id,
            "term": entry.term,
            "index": entry.index,
            "checksum": checksum,
            "status": "committed",
        }
        self.metadata.epoch += 1
        self._publish_metadata()
        return CommitResult(
            entry.shard_id, entry.term, entry.index, entry.request_id
        )

    def _ensure_leader(self, placement: ShardPlacement) -> None:
        try:
            status = self._status(placement.leader, placement.shard_id)
            if status["term"] == placement.term:
                return
        except (ReplicaUnavailable, ProtocolError):
            pass
        self._elect_leader(placement)

    def _status(self, node: str, shard_id: int) -> dict[str, Any]:
        return self._rpc(node, {"operation": "status", "shard_id": shard_id})

    def _elect_leader(self, placement: ShardPlacement) -> str:
        candidates: list[tuple[int, str]] = []
        for node in placement.replicas:
            try:
                status = self._status(node, placement.shard_id)
                candidates.append((int(status["applied_index"]), node))
            except (ReplicaUnavailable, ProtocolError):
                continue
        if len(candidates) < placement.quorum:
            raise QuorumUnavailable("cannot elect leader without replica quorum")
        candidates.sort(key=lambda item: (-item[0], item[1]))
        leader = candidates[0][1]
        placement.term += 1
        placement.placement_epoch += 1
        placement.leader = leader
        self.metadata.epoch += 1
        self._publish_metadata()
        for _, node in candidates:
            self._configure(node, placement)
        return leader

    def catch_up(self, node: str, shard_id: int) -> int:
        with self._lock:
            placement = self.metadata.shards[shard_id]
            if node not in placement.replicas:
                raise ProtocolError("catch-up target is not a shard replica")
            self._configure(node, placement)
            target = self._status(node, shard_id)
            source_node = self._query_replica(placement, require_index=placement.committed_index)
            entries = self._rpc(
                source_node,
                {
                    "operation": "entries",
                    "shard_id": shard_id,
                    "after_index": int(target["applied_index"]),
                },
            )
            applied = int(target["applied_index"])
            for raw in entries:
                old = ReplicatedEntry.from_dict(raw)
                entry = ReplicatedEntry.create(
                    shard_id,
                    placement.term,
                    placement.placement_epoch,
                    old.index,
                    old.request_id,
                    old.mutation,
                )
                self._rpc(
                    node,
                    {"operation": "prepare", "shard_id": shard_id, "entry": entry.to_dict()},
                )
                self._rpc(
                    node,
                    {"operation": "commit", "shard_id": shard_id, "entry": entry.to_dict()},
                )
                applied = entry.index
            return applied

    def _query_replica(
        self, placement: ShardPlacement, *, require_index: int
    ) -> str:
        ordered = [placement.leader] + [
            node for node in placement.replicas if node != placement.leader
        ]
        for node in ordered:
            try:
                status = self._status(node, placement.shard_id)
                if int(status["applied_index"]) >= require_index:
                    return node
            except (ReplicaUnavailable, ProtocolError):
                continue
        raise QuorumUnavailable("no caught-up replica is available for query")

    def search(self, request: SearchRequest) -> list[SearchResult]:
        with self._lock:
            self._ensure_open()
            epoch = self.metadata.epoch
            if request.mode == "hybrid":
                return self._search_hybrid(request, epoch)
            raw = self._fanout(request)
            if self.metadata.epoch != epoch:
                raise ProtocolError("cluster metadata epoch changed during query")
            return self._global_topk(raw, request.k, request.metric, request.mode)

    def _fanout(self, request: SearchRequest) -> list[SearchResult]:
        wire = self._request_to_dict(request)
        results: list[SearchResult] = []
        stats: list[dict[str, Any]] = []
        for shard_id in range(self.metadata.shard_count):
            placement = self.metadata.shards[shard_id]
            raw = self._query_shard(placement, wire)
            results.extend(
                SearchResult(int(item["id"]), float(item["score"]))
                for item in raw["items"]
            )
            stats.append(dict(raw["stats"]))
        self._last_search_stats = self._merge_search_stats(stats)
        return results

    def _query_shard(
        self, placement: ShardPlacement, request: dict[str, Any]
    ) -> dict[str, Any]:
        ordered = [placement.leader] + [
            node for node in placement.replicas if node != placement.leader
        ]
        for node in ordered:
            try:
                status = self._status(node, placement.shard_id)
                if int(status["applied_index"]) < placement.committed_index:
                    continue
                return self._rpc(
                    node,
                    {
                        "operation": "query",
                        "shard_id": placement.shard_id,
                        "request": request,
                    },
                )
            except (ReplicaUnavailable, StaleEpochError, ProtocolError):
                continue
        raise QuorumUnavailable("distributed query has no caught-up replica")

    @staticmethod
    def _merge_search_stats(values: list[dict[str, Any]]) -> dict[str, Any]:
        if not values:
            return {}
        merged = dict(values[0])
        summed = {
            "upper_visited",
            "base_visited",
            "visited",
            "distance_evaluations",
            "retained_candidates",
            "reranked_candidates",
            "filtered_rejections",
            "inactive_rejections",
            "base_candidates",
            "delta_candidates",
        }
        maximum = {"requested_ef", "effective_ef", "widening_rounds"}
        labels = {
            "planner_reason",
            "backend_name",
            "metric_name",
            "scalar_name",
            "storage_name",
            "fallback_reason",
        }
        for name in summed:
            merged[name] = sum(int(value[name]) for value in values)
        for name in maximum:
            merged[name] = max(int(value[name]) for value in values)
        for name in labels:
            distinct = {str(value[name]) for value in values}
            merged[name] = distinct.pop() if len(distinct) == 1 else "mixed"
        return merged

    def _search_hybrid(self, request: SearchRequest, epoch: int) -> list[SearchResult]:
        if request.vector is None or not request.sparse:
            raise ValueError("distributed hybrid search requires dense and sparse queries")
        dense_request = SearchRequest(
            request.metric,
            request.fetch_k,
            vector=request.vector,
            mode="exact",
            filter=request.filter,
        )
        sparse_request = SearchRequest(
            request.metric,
            request.fetch_k,
            sparse=request.sparse,
            mode="sparse",
            filter=request.filter,
        )
        dense = self._global_topk(
            self._fanout(dense_request), request.fetch_k, request.metric, "exact"
        )
        sparse = self._global_topk(
            self._fanout(sparse_request), request.fetch_k, request.metric, "sparse"
        )
        if self.metadata.epoch != epoch:
            raise ProtocolError("cluster metadata epoch changed during hybrid query")
        scores: dict[int, float] = {}
        for rank, result in enumerate(dense, start=1):
            scores[result.id] = scores.get(result.id, 0.0) + 1.0 / (
                request.rank_constant + rank
            )
        for rank, result in enumerate(sparse, start=1):
            scores[result.id] = scores.get(result.id, 0.0) + 1.0 / (
                request.rank_constant + rank
            )
        ordered = sorted(scores.items(), key=lambda item: (-item[1], item[0]))
        return [SearchResult(point_id, score) for point_id, score in ordered[: request.k]]

    @staticmethod
    def _global_topk(
        results: list[SearchResult], k: int, metric: str, mode: str
    ) -> list[SearchResult]:
        unique: dict[int, SearchResult] = {result.id: result for result in results}
        if metric == "l2" and mode not in {"sparse", "hybrid"}:
            ordered = sorted(unique.values(), key=lambda item: (item.score, item.id))
        else:
            ordered = sorted(unique.values(), key=lambda item: (-item.score, item.id))
        return ordered[:k]

    @staticmethod
    def _request_to_dict(request: SearchRequest) -> dict[str, Any]:
        return {
            "metric": request.metric,
            "k": request.k,
            "vector": request.vector,
            "sparse": [item.to_kernel() for item in request.sparse],
            "mode": request.mode,
            "ef_search": request.ef_search,
            "fetch_k": request.fetch_k,
            "rank_constant": request.rank_constant,
            "filter": request.filter,
        }

    def get(self, point_id: int) -> dict[str, Any] | None:
        with self._lock:
            shard_id = self.route(point_id)
            placement = self.metadata.shards[shard_id]
            node = self._query_replica(
                placement, require_index=placement.committed_index
            )
            return self._rpc(
                node, {"operation": "get", "shard_id": shard_id, "id": point_id}
            )

    def stop_node(self, node: str) -> None:
        with self._lock:
            self.nodes[node].crash()

    def restart_node(self, node: str) -> None:
        with self._lock:
            address = self.nodes[node].start()
            self.metadata.members[node] = address
            self.metadata.epoch += 1
            self._publish_metadata()
            for shard_id, placement in self.metadata.shards.items():
                if node in placement.replicas:
                    self._configure(node, placement)
                    self.catch_up(node, shard_id)

    def partition_node(self, node: str, enabled: bool = True) -> None:
        with self._lock:
            self._rpc(node, {"operation": "partition", "enabled": enabled})

    def inject_drop_commit_response(self, node: str, count: int = 1) -> None:
        if count < 0:
            raise ValueError("fault count cannot be negative")
        with self._lock:
            self._rpc(
                node,
                {"operation": "fault", "drop_commit_responses": count},
            )

    def inject_drop_query_response(self, node: str, count: int = 1) -> None:
        if count < 0:
            raise ValueError("fault count cannot be negative")
        with self._lock:
            self._rpc(
                node,
                {"operation": "fault", "drop_query_responses": count},
            )

    def rebalance_add_replica(self, shard_id: int, node: str) -> None:
        """Install leader snapshot+tail before publishing new ownership."""
        with self._lock:
            placement = self.metadata.shards[shard_id]
            if node in placement.replicas:
                return
            if node not in self.nodes or not self.nodes[node].alive:
                raise ReplicaUnavailable("rebalancing target is unavailable")
            source = self._query_replica(
                placement, require_index=placement.committed_index
            )
            exported = self._rpc(source, {"operation": "export", "shard_id": shard_id})
            snapshot_index = int(exported["applied_index"])
            new_epoch = placement.placement_epoch + 1
            self._rpc(
                node,
                {
                    "operation": "configure",
                    "shard_id": shard_id,
                    "term": placement.term,
                    "placement_epoch": new_epoch,
                },
            )
            self._rpc(
                node,
                {
                    "operation": "install_snapshot",
                    "shard_id": shard_id,
                    "rows": exported["rows"],
                    "collection_config": exported["collection_config"],
                    "index": snapshot_index,
                    "term": placement.term,
                    "placement_epoch": new_epoch,
                },
            )
            tail = self._rpc(
                source,
                {"operation": "entries", "shard_id": shard_id, "after_index": snapshot_index},
            )
            for raw in tail:
                old = ReplicatedEntry.from_dict(raw)
                entry = ReplicatedEntry.create(
                    shard_id,
                    placement.term,
                    new_epoch,
                    old.index,
                    old.request_id,
                    old.mutation,
                )
                self._rpc(
                    node,
                    {"operation": "prepare", "shard_id": shard_id, "entry": entry.to_dict()},
                )
                self._rpc(
                    node,
                    {"operation": "commit", "shard_id": shard_id, "entry": entry.to_dict()},
                )
            placement.replicas.append(node)
            placement.placement_epoch = new_epoch
            self.metadata.epoch += 1
            self._publish_metadata()
            for replica in placement.replicas:
                self._configure(replica, placement)

    def replica_status(self, node: str, shard_id: int) -> dict[str, Any]:
        with self._lock:
            return self._status(node, shard_id)

    def debug_rpc(self, node: str, request: dict[str, Any]) -> Any:
        return self._rpc(node, request)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        for process in self.nodes.values():
            try:
                process.stop()
            except BaseException:
                process.crash()

    def __enter__(self) -> "DistributedCluster":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
