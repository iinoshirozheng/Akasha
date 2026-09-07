"""Versioned checksummed cluster metadata and replicated journal formats."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
import json
import math
import os
from pathlib import Path
from typing import Any
import zlib


PROTOCOL_VERSION = 2
ROUTING_VERSION = 2
LEGACY_PROTOCOL_VERSION = 1
LEGACY_ROUTING_VERSION = 1
ENVELOPE_FIELDS = frozenset({"version", "payload", "checksum"})
COLLECTION_CONFIG_FIELDS = frozenset(
    {
        "dimension",
        "ann_metric",
        "scalar_kind",
        "m",
        "m0",
        "ef_construction",
        "default_ef_search",
        "max_ef_search",
        "max_level",
        "rebuild_inactive_percent",
        "delta_max_points",
        "level_seed",
        "fingerprint",
    }
)
CLUSTER_METADATA_FIELDS_V1 = frozenset(
    {
        "cluster_id",
        "dimension",
        "shard_count",
        "replication_factor",
        "epoch",
        "routing_version",
        "members",
        "shards",
        "request_table",
    }
)
CLUSTER_METADATA_FIELDS_V2 = CLUSTER_METADATA_FIELDS_V1 | {"collection_config"}
SHARD_PLACEMENT_FIELDS = frozenset(
    {
        "shard_id",
        "term",
        "placement_epoch",
        "leader",
        "replicas",
        "last_log_index",
        "committed_index",
    }
)
REPLICATED_ENTRY_FIELDS = frozenset(
    {
        "shard_id",
        "term",
        "placement_epoch",
        "index",
        "request_id",
        "mutation",
        "mutation_checksum",
    }
)
PREPARE_RECORD_FIELDS = frozenset({"kind", "entry"})
INDEX_RECORD_FIELDS = frozenset({"kind", "index"})
REQUEST_RECORD_FIELDS = frozenset(
    {"shard_id", "term", "index", "checksum", "status"}
)
DELETE_MUTATION_FIELDS = frozenset({"operation", "id"})
UPSERT_MUTATION_FIELDS = frozenset(
    {"operation", "id", "vector", "fields", "sparse"}
)
MUTATION_PAYLOAD_FIELDS = frozenset({"name", "type", "value"})
MUTATION_SPARSE_FIELDS = frozenset({"term_id", "weight"})


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


def _exact_int(value: Any, name: str) -> int:
    if type(value) is not int:
        raise ProtocolError(f"{name} must be an integer")
    return value


def _finite_number(value: Any) -> bool:
    if type(value) not in {int, float}:
        return False
    try:
        return math.isfinite(float(value))
    except OverflowError:
        return False


def _decode_envelope_versioned(
    value: dict[str, Any],
) -> tuple[int, dict[str, Any]]:
    if type(value) is not dict or set(value) != ENVELOPE_FIELDS:
        raise ProtocolError("distributed envelope fields mismatch")
    version = _exact_int(value["version"], "distributed format version")
    if version not in {LEGACY_PROTOCOL_VERSION, PROTOCOL_VERSION}:
        raise ProtocolError("unsupported distributed format version")
    payload = value["payload"]
    if type(payload) is not dict:
        raise ProtocolError("distributed envelope payload must be an object")
    checksum = _exact_int(value["checksum"], "distributed envelope checksum")
    if checksum != payload_checksum(payload):
        raise ProtocolError("distributed envelope checksum mismatch")
    return version, payload


def decode_envelope(value: dict[str, Any]) -> dict[str, Any]:
    return _decode_envelope_versioned(value)[1]


def canonical_collection_config(
    value: dict[str, Any], dimension: int
) -> dict[str, Any]:
    if type(value) is not dict or set(value) != COLLECTION_CONFIG_FIELDS:
        raise ProtocolError("cluster collection config fields mismatch")
    for field_name in COLLECTION_CONFIG_FIELDS - {"ann_metric", "scalar_kind"}:
        _exact_int(value[field_name], f"collection config {field_name}")
    if type(value["ann_metric"]) is not str:
        raise ProtocolError("collection config ann_metric must be a string")
    if type(value["scalar_kind"]) is not str:
        raise ProtocolError("collection config scalar_kind must be a string")
    if value["dimension"] != dimension:
        raise ProtocolError("cluster collection config dimension mismatch")
    try:
        from akashadb.database import _kernel_module
        from akashadb.models import CollectionConfig

        requested = CollectionConfig.from_kernel(value)
        canonical = dict(
            _kernel_module().validate_collection_config(
                dimension, requested.to_kernel()
            )
        )
    except Exception as error:
        raise ProtocolError("invalid cluster collection config") from error
    if canonical != value:
        raise ProtocolError("cluster collection config is not canonical")
    return canonical


def _legacy_default_collection_config(dimension: int) -> dict[str, Any]:
    try:
        from akashadb.database import _kernel_module

        return dict(_kernel_module().validate_collection_config(dimension, None))
    except Exception as error:
        raise ProtocolError("invalid legacy collection dimension") from error


def validate_replicated_mutation(
    mutation: Any, dimension: int | None = None
) -> None:
    if type(mutation) is not dict or type(mutation.get("operation")) is not str:
        raise ProtocolError("replicated mutation operation is invalid")
    operation = mutation["operation"]
    if operation == "delete":
        if set(mutation) != DELETE_MUTATION_FIELDS:
            raise ProtocolError("replicated delete mutation fields mismatch")
        _exact_int(mutation["id"], "replicated mutation id")
        return
    if operation != "upsert":
        raise ProtocolError("replicated mutation operation is invalid")
    if set(mutation) != UPSERT_MUTATION_FIELDS:
        raise ProtocolError("replicated upsert mutation fields mismatch")
    _exact_int(mutation["id"], "replicated mutation id")

    vector = mutation["vector"]
    if type(vector) is not list or not vector:
        raise ProtocolError("replicated mutation vector must be a nonempty list")
    if dimension is not None and len(vector) != dimension:
        raise ProtocolError("replicated mutation vector dimension mismatch")
    for value in vector:
        if not _finite_number(value):
            raise ProtocolError(
                "replicated mutation vector must contain finite numbers"
            )

    payload = mutation["fields"]
    if type(payload) is not list:
        raise ProtocolError("replicated mutation payload must be a list")
    names: set[str] = set()
    for item in payload:
        if type(item) is not dict or set(item) != MUTATION_PAYLOAD_FIELDS:
            raise ProtocolError("replicated mutation payload fields mismatch")
        name = item["name"]
        kind = item["type"]
        value = item["value"]
        if type(name) is not str or not name or name in names:
            raise ProtocolError("replicated mutation payload names are invalid")
        names.add(name)
        if type(kind) is not str or kind not in {
            "string",
            "int",
            "float",
            "bool",
        }:
            raise ProtocolError("replicated mutation payload type is invalid")
        if kind == "string" and type(value) is not str:
            raise ProtocolError("replicated mutation string payload is invalid")
        if kind == "int" and type(value) is not int:
            raise ProtocolError("replicated mutation integer payload is invalid")
        if kind == "bool" and type(value) is not bool:
            raise ProtocolError("replicated mutation boolean payload is invalid")
        if kind == "float" and not _finite_number(value):
            raise ProtocolError("replicated mutation float payload is invalid")

    sparse = mutation["sparse"]
    if type(sparse) is not list:
        raise ProtocolError("replicated mutation sparse vector must be a list")
    term_ids: set[int] = set()
    for item in sparse:
        if type(item) is not dict or set(item) != MUTATION_SPARSE_FIELDS:
            raise ProtocolError("replicated mutation sparse fields mismatch")
        term_id = _exact_int(item["term_id"], "replicated mutation sparse term")
        weight = item["weight"]
        if term_id < 0 or term_id in term_ids:
            raise ProtocolError("replicated mutation sparse term is invalid")
        if not _finite_number(weight):
            raise ProtocolError("replicated mutation sparse weight is invalid")
        term_ids.add(term_id)


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
    collection_config: dict[str, Any]
    request_table: dict[str, dict[str, Any]] = field(default_factory=dict)
    routing_version: int = ROUTING_VERSION

    def validate(self) -> None:
        if type(self.cluster_id) is not str or not self.cluster_id:
            raise ProtocolError("invalid cluster identifier")
        for name, value in (
            ("dimension", self.dimension),
            ("shard_count", self.shard_count),
            ("replication_factor", self.replication_factor),
            ("epoch", self.epoch),
            ("routing_version", self.routing_version),
        ):
            _exact_int(value, f"cluster {name}")
        if self.dimension <= 0 or self.shard_count <= 0:
            raise ProtocolError("invalid cluster metadata header")
        if (
            self.replication_factor <= 0
            or self.replication_factor > len(self.members)
        ):
            raise ProtocolError("invalid cluster replication factor")
        if self.routing_version != ROUTING_VERSION or self.epoch <= 0:
            raise ProtocolError("unsupported routing metadata")
        self.collection_config = canonical_collection_config(
            self.collection_config, self.dimension
        )
        for node, address in self.members.items():
            if type(node) is not str or not node or type(address) is not tuple:
                raise ProtocolError("invalid cluster member")
            if len(address) != 2 or type(address[0]) is not str:
                raise ProtocolError("invalid cluster member address")
            port = _exact_int(address[1], "cluster member port")
            if not address[0] or port <= 0 or port > 65_535:
                raise ProtocolError("invalid cluster member address")
        if set(self.shards) != set(range(self.shard_count)):
            raise ProtocolError("cluster metadata must cover every shard")
        for shard_id, placement in self.shards.items():
            _exact_int(shard_id, "shard key")
            for name, value in (
                ("shard_id", placement.shard_id),
                ("term", placement.term),
                ("placement_epoch", placement.placement_epoch),
                ("last_log_index", placement.last_log_index),
                ("committed_index", placement.committed_index),
            ):
                _exact_int(value, f"shard placement {name}")
            if (
                type(placement.leader) is not str
                or type(placement.replicas) is not list
            ):
                raise ProtocolError("invalid shard placement members")
            if any(type(node) is not str for node in placement.replicas):
                raise ProtocolError("invalid shard replica")
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
        for request_id, request in self.request_table.items():
            if (
                type(request_id) is not str
                or not request_id
                or type(request) is not dict
            ):
                raise ProtocolError("invalid request table entry")
            if set(request) != REQUEST_RECORD_FIELDS:
                raise ProtocolError("request table entry fields mismatch")
            for name in ("shard_id", "term", "index", "checksum"):
                _exact_int(request[name], f"request table {name}")
            if type(request["status"]) is not str or request["status"] not in {
                "prepared",
                "committed",
            }:
                raise ProtocolError("invalid request table status")

    def to_payload(self) -> dict[str, Any]:
        self.validate()
        return {
            "cluster_id": self.cluster_id,
            "dimension": self.dimension,
            "shard_count": self.shard_count,
            "replication_factor": self.replication_factor,
            "epoch": self.epoch,
            "routing_version": self.routing_version,
            "collection_config": dict(self.collection_config),
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
    def from_payload(
        cls, payload: dict[str, Any], *, protocol_version: int = PROTOCOL_VERSION
    ) -> "ClusterMetadata":
        if type(payload) is not dict:
            raise ProtocolError("cluster metadata payload must be an object")
        expected_fields = (
            CLUSTER_METADATA_FIELDS_V1
            if protocol_version == LEGACY_PROTOCOL_VERSION
            else CLUSTER_METADATA_FIELDS_V2
        )
        if (
            protocol_version == PROTOCOL_VERSION
            and "collection_config" not in payload
        ):
            raise ProtocolError("cluster collection config is missing")
        if set(payload) != expected_fields:
            raise ProtocolError("cluster metadata fields mismatch")
        dimension = _exact_int(payload["dimension"], "cluster dimension")
        if dimension <= 0:
            raise ProtocolError("cluster dimension must be positive")
        if type(payload["cluster_id"]) is not str:
            raise ProtocolError("cluster identifier must be a string")
        routing_version = _exact_int(
            payload["routing_version"], "cluster routing version"
        )
        if protocol_version == LEGACY_PROTOCOL_VERSION:
            if routing_version != LEGACY_ROUTING_VERSION:
                raise ProtocolError("invalid legacy routing version")
            collection_config = _legacy_default_collection_config(dimension)
            routing_version = ROUTING_VERSION
        else:
            if type(payload["collection_config"]) is not dict:
                raise ProtocolError("cluster collection config is missing")
            collection_config = canonical_collection_config(
                payload["collection_config"], dimension
            )
        if (
            type(payload["members"]) is not dict
            or type(payload["shards"]) is not dict
        ):
            raise ProtocolError("cluster members and shards must be objects")
        members: dict[str, tuple[str, int]] = {}
        for node, address in payload["members"].items():
            if (
                type(node) is not str
                or type(address) is not list
                or len(address) != 2
            ):
                raise ProtocolError("invalid cluster member")
            if type(address[0]) is not str:
                raise ProtocolError("cluster member address must be a string")
            members[node] = (
                address[0],
                _exact_int(address[1], "cluster member port"),
            )
        shards: dict[int, ShardPlacement] = {}
        for shard, placement in payload["shards"].items():
            if type(shard) is not str or type(placement) is not dict:
                raise ProtocolError("invalid shard placement")
            if set(placement) != SHARD_PLACEMENT_FIELDS:
                raise ProtocolError("shard placement fields mismatch")
            try:
                shard_id = int(shard)
            except ValueError as error:
                raise ProtocolError("invalid shard key") from error
            if shard != str(shard_id):
                raise ProtocolError("noncanonical shard key")
            for name in (
                "shard_id",
                "term",
                "placement_epoch",
                "last_log_index",
                "committed_index",
            ):
                _exact_int(placement[name], f"shard placement {name}")
            if (
                type(placement["leader"]) is not str
                or type(placement["replicas"]) is not list
            ):
                raise ProtocolError("invalid shard placement members")
            if any(type(item) is not str for item in placement["replicas"]):
                raise ProtocolError("invalid shard replica")
            shards[shard_id] = ShardPlacement(**placement)
        if type(payload["request_table"]) is not dict:
            raise ProtocolError("cluster request table must be an object")
        metadata = cls(
            cluster_id=payload["cluster_id"],
            dimension=dimension,
            shard_count=_exact_int(payload["shard_count"], "cluster shard_count"),
            replication_factor=_exact_int(
                payload["replication_factor"], "cluster replication_factor"
            ),
            epoch=_exact_int(payload["epoch"], "cluster epoch"),
            routing_version=routing_version,
            members=members,
            shards=shards,
            collection_config=collection_config,
            request_table=dict(payload["request_table"]),
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
        version, payload = _decode_envelope_versioned(value)
        return cls.from_payload(payload, protocol_version=version)


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
        for name, value in (
            ("shard_id", self.shard_id),
            ("term", self.term),
            ("placement_epoch", self.placement_epoch),
            ("index", self.index),
            ("mutation_checksum", self.mutation_checksum),
        ):
            _exact_int(value, f"replicated {name}")
        if self.shard_id < 0 or self.term <= 0 or self.placement_epoch <= 0:
            raise ProtocolError("invalid replicated entry epoch")
        if (
            type(self.request_id) is not str
            or self.index <= 0
            or not self.request_id
        ):
            raise ProtocolError("invalid replicated entry identity")
        validate_replicated_mutation(self.mutation)
        if self.mutation_checksum != payload_checksum(self.mutation):
            raise ProtocolError("replicated mutation checksum mismatch")

    def to_dict(self) -> dict[str, Any]:
        self.validate()
        return asdict(self)

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "ReplicatedEntry":
        if type(value) is not dict or set(value) != REPLICATED_ENTRY_FIELDS:
            raise ProtocolError("replicated entry fields mismatch")
        if type(value["mutation"]) is not dict:
            raise ProtocolError("replicated mutation must be an object")
        entry = cls(
            shard_id=_exact_int(value["shard_id"], "replicated shard_id"),
            term=_exact_int(value["term"], "replicated term"),
            placement_epoch=_exact_int(
                value["placement_epoch"], "replicated placement_epoch"
            ),
            index=_exact_int(value["index"], "replicated index"),
            request_id=value["request_id"]
            if type(value["request_id"]) is str
            else "",
            mutation=dict(value["mutation"]),
            mutation_checksum=_exact_int(
                value["mutation_checksum"], "replicated mutation_checksum"
            ),
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
        repair_torn_tail = bool(data and not data.endswith(b"\n"))
        if repair_torn_tail:
            complete_size = data.rfind(b"\n") + 1
            data = data[:complete_size]
        for line in data.splitlines():
            if not line:
                continue
            try:
                _, payload = _decode_envelope_versioned(json.loads(line))
            except (json.JSONDecodeError, ProtocolError) as error:
                raise ProtocolError("replica journal corruption") from error
            kind = payload.get("kind")
            if kind == "prepare":
                if set(payload) != PREPARE_RECORD_FIELDS:
                    raise ProtocolError("replica journal prepare fields mismatch")
                entry = ReplicatedEntry.from_dict(payload["entry"])
                existing = self.prepared.get(entry.index)
                if existing and existing.mutation_checksum != entry.mutation_checksum:
                    raise ProtocolError("conflicting replicated journal entry")
                self.prepared[entry.index] = entry
            elif kind == "commit":
                if set(payload) != INDEX_RECORD_FIELDS:
                    raise ProtocolError("replica journal commit fields mismatch")
                index = _exact_int(payload["index"], "replica commit index")
                if index not in self.prepared:
                    raise ProtocolError("commit marker has no prepared entry")
                self.committed.add(index)
            elif kind == "snapshot":
                if set(payload) != INDEX_RECORD_FIELDS:
                    raise ProtocolError("replica journal snapshot fields mismatch")
                index = _exact_int(payload["index"], "replica snapshot index")
                self.snapshot_index = max(self.snapshot_index, index)
            else:
                raise ProtocolError("unknown replica journal record")
        if repair_torn_tail:
            with self.path.open("r+b") as file:
                file.truncate(complete_size)
                file.flush()
                os.fsync(file.fileno())

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
