"""Versioned checksummed cluster metadata and replicated journal formats."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
import json
import os
from pathlib import Path
from typing import Any
import zlib


PROTOCOL_VERSION = 1
ROUTING_VERSION = 1


class ProtocolError(RuntimeError):
    pass


def canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def payload_checksum(value: object) -> int:
    return zlib.crc32(canonical_bytes(value)) & 0xFFFFFFFF


def checked_envelope(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "version": PROTOCOL_VERSION,
        "payload": payload,
        "checksum": payload_checksum(payload),
    }


def decode_envelope(value: dict[str, Any]) -> dict[str, Any]:
    if value.get("version") != PROTOCOL_VERSION:
        raise ProtocolError("unsupported distributed format version")
    payload = value.get("payload")
    if not isinstance(payload, dict):
        raise ProtocolError("distributed envelope payload must be an object")
    if value.get("checksum") != payload_checksum(payload):
        raise ProtocolError("distributed envelope checksum mismatch")
    return payload


@dataclass(slots=True)
class ShardPlacement:
    shard_id: int
    term: int
    placement_epoch: int
    leader: str
    replicas: list[str]
    last_log_index: int = 0
    committed_index: int = 0

    @property
    def quorum(self) -> int:
        return len(self.replicas) // 2 + 1


@dataclass(slots=True)
class ClusterMetadata:
    cluster_id: str
    dimension: int
    shard_count: int
    replication_factor: int
    epoch: int
    members: dict[str, tuple[str, int]]
    shards: dict[int, ShardPlacement]
    request_table: dict[str, dict[str, Any]] = field(default_factory=dict)
    routing_version: int = ROUTING_VERSION

    def validate(self) -> None:
        if not self.cluster_id or self.dimension <= 0 or self.shard_count <= 0:
            raise ProtocolError("invalid cluster metadata header")
        if self.routing_version != ROUTING_VERSION or self.epoch <= 0:
            raise ProtocolError("unsupported routing metadata")
        if set(self.shards) != set(range(self.shard_count)):
            raise ProtocolError("cluster metadata must cover every shard")
        for shard_id, placement in self.shards.items():
            if placement.shard_id != shard_id or placement.term <= 0:
                raise ProtocolError("invalid shard placement identity")
            if placement.placement_epoch <= 0:
                raise ProtocolError("invalid shard placement epoch")
            if len(set(placement.replicas)) != len(placement.replicas):
                raise ProtocolError("duplicate shard replica")
            if placement.leader not in placement.replicas:
                raise ProtocolError("shard leader must be a replica")
            if len(placement.replicas) < placement.quorum:
                raise ProtocolError("shard cannot form quorum")
            if placement.committed_index > placement.last_log_index:
                raise ProtocolError("committed index exceeds shard log")
            if any(node not in self.members for node in placement.replicas):
                raise ProtocolError("shard references an unknown member")

    def to_payload(self) -> dict[str, Any]:
        self.validate()
        return {
            "cluster_id": self.cluster_id,
            "dimension": self.dimension,
            "shard_count": self.shard_count,
            "replication_factor": self.replication_factor,
            "epoch": self.epoch,
            "routing_version": self.routing_version,
            "members": {
                node: [address[0], address[1]]
                for node, address in sorted(self.members.items())
            },
            "shards": {
                str(shard): asdict(placement)
                for shard, placement in sorted(self.shards.items())
            },
            "request_table": self.request_table,
        }

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "ClusterMetadata":
        metadata = cls(
            cluster_id=str(payload["cluster_id"]),
            dimension=int(payload["dimension"]),
            shard_count=int(payload["shard_count"]),
            replication_factor=int(payload["replication_factor"]),
            epoch=int(payload["epoch"]),
            routing_version=int(payload["routing_version"]),
            members={
                str(node): (str(address[0]), int(address[1]))
                for node, address in payload["members"].items()
            },
            shards={
                int(shard): ShardPlacement(**placement)
                for shard, placement in payload["shards"].items()
            },
            request_table=dict(payload.get("request_table", {})),
        )
        metadata.validate()
        return metadata

    def publish(self, path: str | Path) -> None:
        destination = Path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".tmp")
        data = canonical_bytes(checked_envelope(self.to_payload())) + b"\n"
        with temporary.open("wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
        directory_fd = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

    @classmethod
    def load(cls, path: str | Path) -> "ClusterMetadata":
        try:
            value = json.loads(Path(path).read_bytes())
        except (OSError, json.JSONDecodeError) as error:
            raise ProtocolError("cannot decode cluster metadata") from error
        return cls.from_payload(decode_envelope(value))


@dataclass(frozen=True, slots=True)
class ReplicatedEntry:
    shard_id: int
    term: int
    placement_epoch: int
    index: int
    request_id: str
    mutation: dict[str, Any]
    mutation_checksum: int

    @classmethod
    def create(
        cls,
        shard_id: int,
        term: int,
        placement_epoch: int,
        index: int,
        request_id: str,
        mutation: dict[str, Any],
    ) -> "ReplicatedEntry":
        return cls(
            shard_id,
            term,
            placement_epoch,
            index,
            request_id,
            mutation,
            payload_checksum(mutation),
        )

    def validate(self) -> None:
        if self.shard_id < 0 or self.term <= 0 or self.placement_epoch <= 0:
            raise ProtocolError("invalid replicated entry epoch")
        if self.index <= 0 or not self.request_id:
            raise ProtocolError("invalid replicated entry identity")
        if self.mutation_checksum != payload_checksum(self.mutation):
            raise ProtocolError("replicated mutation checksum mismatch")

    def to_dict(self) -> dict[str, Any]:
        self.validate()
        return asdict(self)

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "ReplicatedEntry":
        entry = cls(
            shard_id=int(value["shard_id"]),
            term=int(value["term"]),
            placement_epoch=int(value["placement_epoch"]),
            index=int(value["index"]),
            request_id=str(value["request_id"]),
            mutation=dict(value["mutation"]),
            mutation_checksum=int(value["mutation_checksum"]),
        )
        entry.validate()
        return entry


class ReplicaJournal:
    """Append+fsync replicated prepare/commit records with torn-tail repair."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.prepared: dict[int, ReplicatedEntry] = {}
        self.committed: set[int] = set()
        self.snapshot_index = 0
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        data = self.path.read_bytes()
        complete_size = len(data)
        if data and not data.endswith(b"\n"):
            complete_size = data.rfind(b"\n") + 1
            data = data[:complete_size]
            with self.path.open("r+b") as file:
                file.truncate(complete_size)
                file.flush()
                os.fsync(file.fileno())
        for line in data.splitlines():
            if not line:
                continue
            try:
                payload = decode_envelope(json.loads(line))
            except (json.JSONDecodeError, ProtocolError) as error:
                raise ProtocolError("replica journal corruption") from error
            kind = payload.get("kind")
            if kind == "prepare":
                entry = ReplicatedEntry.from_dict(payload["entry"])
                existing = self.prepared.get(entry.index)
                if existing and existing.mutation_checksum != entry.mutation_checksum:
                    raise ProtocolError("conflicting replicated journal entry")
                self.prepared[entry.index] = entry
            elif kind == "commit":
                index = int(payload["index"])
                if index not in self.prepared:
                    raise ProtocolError("commit marker has no prepared entry")
                self.committed.add(index)
            elif kind == "snapshot":
                self.snapshot_index = max(self.snapshot_index, int(payload["index"]))
            else:
                raise ProtocolError("unknown replica journal record")

    def _append(self, payload: dict[str, Any]) -> None:
        data = canonical_bytes(checked_envelope(payload)) + b"\n"
        with self.path.open("ab") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())

    def prepare(self, entry: ReplicatedEntry) -> None:
        entry.validate()
        existing = self.prepared.get(entry.index)
        if existing is not None:
            if existing.mutation_checksum != entry.mutation_checksum:
                raise ProtocolError("conflicting duplicate replicated entry")
            return
        self._append({"kind": "prepare", "entry": entry.to_dict()})
        self.prepared[entry.index] = entry

    def commit(self, index: int) -> ReplicatedEntry:
        if index not in self.prepared:
            raise ProtocolError("cannot commit an unprepared entry")
        if index not in self.committed:
            self._append({"kind": "commit", "index": index})
            self.committed.add(index)
        return self.prepared[index]

    def install_snapshot(self, index: int) -> None:
        if index < self.snapshot_index:
            raise ProtocolError("snapshot index regression")
        self._append({"kind": "snapshot", "index": index})
        self.snapshot_index = index

    def committed_after(self, index: int) -> list[ReplicatedEntry]:
        return [
            self.prepared[item]
            for item in sorted(self.committed)
            if item > index
        ]
