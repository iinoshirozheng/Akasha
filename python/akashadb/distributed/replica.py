"""Independent replica process backed by one Mojo collection per shard."""

from __future__ import annotations

import json
from dataclasses import asdict
import math
import multiprocessing
from multiprocessing.connection import Client, Connection, Listener
import os
from pathlib import Path
import shutil
from typing import Any

from akashadb.database import Collection
from akashadb.models import (
    BatchMutation,
    CollectionConfig,
    PayloadField,
    SearchRequest,
    SparseElement,
)

from .protocol import (
    ProtocolError,
    ReplicaJournal,
    ReplicatedEntry,
    canonical_collection_config,
    canonical_bytes,
    checked_envelope,
    decode_envelope,
    payload_checksum,
)


SNAPSHOT_ROW_FIELDS = frozenset(
    {"id", "sequence", "vector", "fields", "sparse"}
)
SNAPSHOT_FIELD_FIELDS = frozenset({"name", "type", "value"})
SNAPSHOT_SPARSE_FIELDS = frozenset({"term_id", "weight"})
REPLICA_STATE_FIELDS = frozenset({"term", "placement_epoch", "applied_index"})


class StaleEpochError(ProtocolError):
    pass


class ReplicaUnavailable(ConnectionError):
    pass


def _publish_checked(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("wb") as output:
        output.write(canonical_bytes(checked_envelope(payload)) + b"\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


def _load_checked(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    if not path.exists():
        return default
    try:
        return decode_envelope(json.loads(path.read_bytes()))
    except (OSError, json.JSONDecodeError, ProtocolError) as error:
        raise ProtocolError(f"corrupt replica state: {path.name}") from error


def _exact_int(value: Any, name: str) -> int:
    if type(value) is not int:
        raise ProtocolError(f"{name} must be an integer")
    return value


def _snapshot_payload(
    rows: list[dict[str, Any]], config: dict[str, Any], index: int
) -> dict[str, Any]:
    return {"rows": rows, "collection_config": config, "index": index}


def snapshot_checksum(
    rows: list[dict[str, Any]], config: dict[str, Any], index: int
) -> int:
    return payload_checksum(_snapshot_payload(rows, config, index))


def _parse_snapshot_rows(
    rows: Any, dimension: int
) -> tuple[list[BatchMutation], list[tuple[int, list[SparseElement]]]]:
    if type(rows) is not list:
        raise ProtocolError("snapshot rows must be a list")
    mutations: list[BatchMutation] = []
    sparse_rows: list[tuple[int, list[SparseElement]]] = []
    seen_ids: set[int] = set()
    for row in rows:
        if type(row) is not dict or set(row) != SNAPSHOT_ROW_FIELDS:
            raise ProtocolError("snapshot row fields mismatch")
        point_id = _exact_int(row["id"], "snapshot point id")
        sequence = _exact_int(row["sequence"], "snapshot sequence")
        if sequence <= 0:
            raise ProtocolError("snapshot sequence must be positive")
        if point_id in seen_ids:
            raise ProtocolError("snapshot point IDs must be unique")
        seen_ids.add(point_id)

        raw_vector = row["vector"]
        if type(raw_vector) is not list or len(raw_vector) != dimension:
            raise ProtocolError("snapshot vector dimension mismatch")
        vector: list[float] = []
        for value in raw_vector:
            if type(value) not in {int, float}:
                raise ProtocolError("snapshot vector values must be numeric")
            converted = float(value)
            if not math.isfinite(converted):
                raise ProtocolError("snapshot vector values must be finite")
            vector.append(converted)

        raw_fields = row["fields"]
        if type(raw_fields) is not list:
            raise ProtocolError("snapshot fields must be a list")
        fields: list[PayloadField] = []
        field_names: set[str] = set()
        for item in raw_fields:
            if type(item) is not dict or set(item) != SNAPSHOT_FIELD_FIELDS:
                raise ProtocolError("snapshot payload fields mismatch")
            name = item["name"]
            kind = item["type"]
            value = item["value"]
            if type(name) is not str or not name or name in field_names:
                raise ProtocolError("snapshot payload names must be unique strings")
            field_names.add(name)
            if type(kind) is not str or kind not in {
                "string",
                "int",
                "float",
                "bool",
            }:
                raise ProtocolError("snapshot payload type is invalid")
            if kind == "string" and type(value) is not str:
                raise ProtocolError("snapshot string payload type mismatch")
            if kind == "int" and type(value) is not int:
                raise ProtocolError("snapshot integer payload type mismatch")
            if kind == "bool" and type(value) is not bool:
                raise ProtocolError("snapshot boolean payload type mismatch")
            if kind == "float":
                if type(value) not in {int, float} or not math.isfinite(
                    float(value)
                ):
                    raise ProtocolError("snapshot float payload type mismatch")
                value = float(value)
            fields.append(PayloadField(name, kind, value))

        raw_sparse = row["sparse"]
        if type(raw_sparse) is not list:
            raise ProtocolError("snapshot sparse vector must be a list")
        sparse: list[SparseElement] = []
        seen_terms: set[int] = set()
        for item in raw_sparse:
            if type(item) is not dict or set(item) != SNAPSHOT_SPARSE_FIELDS:
                raise ProtocolError("snapshot sparse fields mismatch")
            term_id = _exact_int(item["term_id"], "snapshot sparse term ID")
            weight = item["weight"]
            if term_id < 0 or term_id in seen_terms:
                raise ProtocolError(
                    "snapshot sparse term IDs must be unique and non-negative"
                )
            if type(weight) not in {int, float} or not math.isfinite(
                float(weight)
            ):
                raise ProtocolError("snapshot sparse weights must be finite numbers")
            seen_terms.add(term_id)
            sparse.append(SparseElement(term_id, float(weight)))
        mutations.append(BatchMutation.upsert(point_id, vector, fields))
        sparse_rows.append((point_id, sparse))
    return mutations, sparse_rows


def _remove_snapshot_workspace(path: Path, parent: Path, prefix: str) -> None:
    if path.parent != parent or not path.name.startswith(prefix):
        raise RuntimeError("refusing to remove an unexpected snapshot workspace")
    if path.exists():
        shutil.rmtree(path)


def _snapshot_workspaces(root: Path) -> tuple[Path, Path, Path]:
    return (
        root.parent / f".{root.name}.snapshot-stage",
        root.parent / f".{root.name}.snapshot-backup",
        root.parent / f".{root.name}.snapshot-failed",
    )


def _recover_snapshot_workspaces(root: Path) -> None:
    stage_root, backup_root, failed_root = _snapshot_workspaces(root)
    parent = root.parent
    if backup_root.exists():
        if root.exists():
            _remove_snapshot_workspace(
                backup_root, parent, f".{root.name}.snapshot-backup"
            )
        else:
            os.replace(backup_root, root)
            _fsync_directory(parent)
    _remove_snapshot_workspace(stage_root, parent, f".{root.name}.snapshot-stage")
    _remove_snapshot_workspace(
        failed_root, parent, f".{root.name}.snapshot-failed"
    )


def _fsync_directory(path: Path) -> None:
    directory_fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


class ReplicaShard:
    def __init__(
        self,
        root: Path,
        shard_id: int,
        dimension: int,
        config: dict[str, Any],
    ) -> None:
        self.root = root
        self.shard_id = shard_id
        self.dimension = dimension
        canonical_config = canonical_collection_config(config, dimension)
        self.config = CollectionConfig.from_kernel(canonical_config)
        _recover_snapshot_workspaces(self.root)
        self.root.mkdir(parents=True, exist_ok=True)
        state = _load_checked(
            self.root / "replica-state.json",
            {"term": 0, "placement_epoch": 0, "applied_index": 0},
        )
        if type(state) is not dict or set(state) != REPLICA_STATE_FIELDS:
            raise ProtocolError("replica state fields mismatch")
        self.term = _exact_int(state["term"], "replica state term")
        self.placement_epoch = _exact_int(
            state["placement_epoch"], "replica state placement epoch"
        )
        self.applied_index = _exact_int(
            state["applied_index"], "replica state applied index"
        )
        self.journal = ReplicaJournal(self.root / "replicated.log")
        self.collection = Collection(
            self.root / "collection", dimension, config=self.config
        )
        self._replay_committed()

    def _publish_state(self) -> None:
        _publish_checked(
            self.root / "replica-state.json",
            {
                "term": self.term,
                "placement_epoch": self.placement_epoch,
                "applied_index": self.applied_index,
            },
        )

    def configure(self, term: int, placement_epoch: int) -> dict[str, Any]:
        if term < self.term or placement_epoch < self.placement_epoch:
            raise StaleEpochError("replica configuration epoch regression")
        self.term = term
        self.placement_epoch = placement_epoch
        self._publish_state()
        return self.status()

    def _validate_entry_epoch(self, entry: ReplicatedEntry) -> None:
        if entry.shard_id != self.shard_id:
            raise ProtocolError("replicated entry routed to wrong shard")
        if entry.term != self.term or entry.placement_epoch != self.placement_epoch:
            raise StaleEpochError("stale shard term or placement epoch")

    def prepare(self, entry: ReplicatedEntry) -> dict[str, Any]:
        self._validate_entry_epoch(entry)
        if entry.index <= self.journal.snapshot_index:
            raise ProtocolError("replicated index predates installed snapshot")
        self.journal.prepare(entry)
        return {"prepared_index": entry.index, "checksum": entry.mutation_checksum}

    def commit(self, entry: ReplicatedEntry) -> dict[str, Any]:
        self._validate_entry_epoch(entry)
        self.journal.prepare(entry)
        committed = self.journal.commit(entry.index)
        if committed.index > self.applied_index:
            self._apply(committed.mutation)
            self.applied_index = committed.index
            self._publish_state()
        return {"committed_index": entry.index, "applied_index": self.applied_index}

    def _apply(self, mutation: dict[str, Any]) -> None:
        operation = mutation["operation"]
        point_id = int(mutation["id"])
        if operation == "delete":
            self.collection.delete(point_id)
            return
        if operation != "upsert":
            raise ProtocolError("unknown replicated mutation operation")
        fields = [
            PayloadField(str(item["name"]), item["type"], item["value"])
            for item in mutation.get("fields", [])
        ]
        self.collection.upsert(
            point_id,
            [float(value) for value in mutation["vector"]],
            fields,
        )
        sparse = [
            SparseElement(int(item["term_id"]), float(item["weight"]))
            for item in mutation.get("sparse", [])
        ]
        if sparse:
            self.collection.upsert_sparse(point_id, sparse)

    def _replay_committed(self) -> None:
        for entry in self.journal.committed_after(self.applied_index):
            self._apply(entry.mutation)
            self.applied_index = entry.index
            self._publish_state()

    def query(self, request: dict[str, Any]) -> dict[str, Any]:
        sparse = [
            SparseElement(int(item["term_id"]), float(item["weight"]))
            for item in request.get("sparse", [])
        ]
        typed = SearchRequest(
            metric=request["metric"],
            k=int(request["k"]),
            vector=request.get("vector"),
            sparse=sparse,
            mode=request.get("mode", "exact"),
            ef_search=int(request.get("ef_search", 64)),
            fetch_k=int(request.get("fetch_k", 50)),
            rank_constant=int(request.get("rank_constant", 60)),
            filter=request.get("filter"),
        )
        items = [
            {"id": result.id, "score": result.score}
            for result in self.collection.search(typed)
        ]
        return {"items": items, "stats": asdict(self.collection.last_search_stats())}

    def get(self, point_id: int) -> dict[str, Any] | None:
        document = self.collection.get(point_id)
        if document is None:
            return None
        return {
            "id": document.id,
            "sequence": document.sequence,
            "vector": document.vector,
            "fields": [field.to_kernel() for field in document.fields],
        }

    def export_records(self) -> list[dict[str, Any]]:
        return self.collection._export_records()

    def entries_after(self, index: int) -> list[dict[str, Any]]:
        return [entry.to_dict() for entry in self.journal.committed_after(index)]

    def install_snapshot(
        self,
        rows: list[dict[str, Any]],
        config: dict[str, Any],
        index: int,
        term: int,
        placement_epoch: int,
        checksum: int,
    ) -> dict[str, Any]:
        index = _exact_int(index, "snapshot index")
        term = _exact_int(term, "snapshot term")
        placement_epoch = _exact_int(
            placement_epoch, "snapshot placement epoch"
        )
        checksum = _exact_int(checksum, "snapshot checksum")
        if index < self.applied_index:
            raise ProtocolError("snapshot cannot regress applied index")
        if term < self.term or placement_epoch < self.placement_epoch:
            raise StaleEpochError("snapshot epoch regression")
        incoming_config = canonical_collection_config(config, self.dimension)
        current_config = asdict(self.config)
        if incoming_config != current_config:
            raise ProtocolError("snapshot collection config mismatch")
        mutations, sparse_rows = _parse_snapshot_rows(rows, self.dimension)
        if checksum != snapshot_checksum(rows, incoming_config, index):
            raise ProtocolError("snapshot checksum mismatch")

        parent = self.root.parent
        _recover_snapshot_workspaces(self.root)
        stage_root, backup_root, failed_root = _snapshot_workspaces(self.root)
        stage_prefix = f".{self.root.name}.snapshot-stage"
        backup_prefix = f".{self.root.name}.snapshot-backup"
        failed_prefix = f".{self.root.name}.snapshot-failed"
        stage_root.mkdir()
        try:
            staged_collection = Collection(
                stage_root / "collection", self.dimension, config=self.config
            )
            try:
                if mutations:
                    staged_collection.apply_batch(mutations)
                    for point_id, sparse in sparse_rows:
                        if sparse:
                            staged_collection.upsert_sparse(point_id, sparse)
                staged_collection.flush()
                if asdict(staged_collection.collection_config()) != incoming_config:
                    raise ProtocolError("staged snapshot config mismatch")
            finally:
                staged_collection.close()
            staged_journal = ReplicaJournal(stage_root / "replicated.log")
            staged_journal.install_snapshot(index)
            _publish_checked(
                stage_root / "replica-state.json",
                {
                    "term": term,
                    "placement_epoch": placement_epoch,
                    "applied_index": index,
                },
            )
            _fsync_directory(stage_root)

            self.collection.close()
            try:
                os.replace(self.root, backup_root)
            except BaseException:
                self.collection = Collection(
                    self.root / "collection", self.dimension, config=self.config
                )
                raise
            replacement: Collection | None = None
            try:
                os.replace(stage_root, self.root)
                _fsync_directory(parent)
                replacement = Collection(
                    self.root / "collection", self.dimension, config=self.config
                )
                replacement_journal = ReplicaJournal(self.root / "replicated.log")
                if replacement_journal.snapshot_index != index:
                    replacement.close()
                    raise ProtocolError("installed snapshot journal mismatch")
            except BaseException:
                if replacement is not None:
                    replacement.close()
                if self.root.exists():
                    os.replace(self.root, failed_root)
                os.replace(backup_root, self.root)
                _fsync_directory(parent)
                self.collection = Collection(
                    self.root / "collection", self.dimension, config=self.config
                )
                self.journal = ReplicaJournal(self.root / "replicated.log")
                _remove_snapshot_workspace(failed_root, parent, failed_prefix)
                raise

            assert replacement is not None
            self.collection = replacement
            self.journal = replacement_journal
            self.term = term
            self.placement_epoch = placement_epoch
            self.applied_index = index
            _remove_snapshot_workspace(backup_root, parent, backup_prefix)
            _fsync_directory(parent)
        finally:
            _remove_snapshot_workspace(stage_root, parent, stage_prefix)
        return self.status()

    def status(self) -> dict[str, Any]:
        return {
            "shard_id": self.shard_id,
            "term": self.term,
            "placement_epoch": self.placement_epoch,
            "applied_index": self.applied_index,
            "last_sequence": self.collection.last_sequence,
            "config_fingerprint": self.collection.collection_config().fingerprint,
        }

    def close(self) -> None:
        self.collection.close()


def replica_server_main(
    node_id: str,
    root: str,
    dimension: int,
    config: dict[str, Any],
    authkey: bytes,
    ready: Connection,
) -> None:
    shards: dict[int, ReplicaShard] = {}
    partitioned = False
    drop_commit_responses = 0
    drop_query_responses = 0
    listener = Listener(("127.0.0.1", 0), authkey=authkey)
    ready.send(listener.address)
    ready.close()
    running = True
    while running:
        connection = listener.accept()
        try:
            request = connection.recv()
            operation = request.get("operation")
            if partitioned and operation not in {"partition", "fault", "shutdown"}:
                raise ReplicaUnavailable("replica is network partitioned")
            if operation == "partition":
                partitioned = bool(request["enabled"])
                result: Any = {"partitioned": partitioned}
            elif operation == "fault":
                drop_commit_responses = int(request.get("drop_commit_responses", 0))
                drop_query_responses = int(request.get("drop_query_responses", 0))
                result = {
                    "drop_commit_responses": drop_commit_responses,
                    "drop_query_responses": drop_query_responses,
                }
            elif operation == "shutdown":
                result = {"stopped": True}
                running = False
            elif operation == "crash":
                os._exit(17)
            else:
                shard_id = int(request["shard_id"])
                if operation == "configure":
                    shard = shards.get(shard_id)
                    if shard is None:
                        shard = ReplicaShard(
                            Path(root) / f"shard-{shard_id}",
                            shard_id,
                            dimension,
                            config,
                        )
                        shards[shard_id] = shard
                    result = shard.configure(
                        int(request["term"]), int(request["placement_epoch"])
                    )
                else:
                    shard = shards.get(shard_id)
                    if shard is None:
                        raise ProtocolError("replica does not own requested shard")
                    if operation == "prepare":
                        result = shard.prepare(ReplicatedEntry.from_dict(request["entry"]))
                    elif operation == "commit":
                        result = shard.commit(ReplicatedEntry.from_dict(request["entry"]))
                    elif operation == "query":
                        result = shard.query(request["request"])
                    elif operation == "get":
                        result = shard.get(int(request["id"]))
                    elif operation == "export":
                        rows = shard.export_records()
                        applied_index = shard.applied_index
                        exported_config = asdict(shard.config)
                        result = {
                            "rows": rows,
                            "applied_index": applied_index,
                            "collection_config": exported_config,
                            "snapshot_checksum": snapshot_checksum(
                                rows, exported_config, applied_index
                            ),
                        }
                    elif operation == "entries":
                        result = shard.entries_after(int(request["after_index"]))
                    elif operation == "install_snapshot":
                        result = shard.install_snapshot(
                            request["rows"],
                            request["collection_config"],
                            request["index"],
                            request["term"],
                            request["placement_epoch"],
                            request["snapshot_checksum"],
                        )
                    elif operation == "status":
                        result = shard.status()
                    else:
                        raise ProtocolError("unknown replica RPC operation")
            if operation == "commit" and drop_commit_responses > 0:
                drop_commit_responses -= 1
                connection.close()
                continue
            if operation == "query" and drop_query_responses > 0:
                drop_query_responses -= 1
                connection.close()
                continue
            connection.send({"ok": True, "result": result})
        except BaseException as error:
            try:
                connection.send(
                    {
                        "ok": False,
                        "error_type": type(error).__name__,
                        "error": str(error),
                    }
                )
            except BaseException:
                pass
        finally:
            connection.close()
    for shard in shards.values():
        shard.close()
    listener.close()


class ReplicaProcess:
    def __init__(
        self,
        node_id: str,
        root: str | Path,
        dimension: int,
        config: dict[str, Any],
        authkey: bytes,
    ) -> None:
        self.node_id = node_id
        self.root = Path(root)
        self.dimension = dimension
        self.config = dict(config)
        self.authkey = authkey
        self.address: tuple[str, int] | None = None
        self.process: multiprocessing.Process | None = None

    def start(self) -> tuple[str, int]:
        if self.process is not None and self.process.is_alive():
            raise RuntimeError("replica process is already running")
        context = multiprocessing.get_context("spawn")
        parent, child = context.Pipe(duplex=False)
        self.process = context.Process(
            target=replica_server_main,
            args=(
                self.node_id,
                str(self.root),
                self.dimension,
                self.config,
                self.authkey,
                child,
            ),
            name=f"akasha-replica-{self.node_id}",
        )
        self.process.start()
        child.close()
        if not parent.poll(20):
            self.process.terminate()
            self.process.join(5)
            raise ReplicaUnavailable("replica did not become ready")
        self.address = tuple(parent.recv())  # type: ignore[assignment]
        parent.close()
        return self.address

    @property
    def alive(self) -> bool:
        return self.process is not None and self.process.is_alive()

    def rpc(self, request: dict[str, Any]) -> Any:
        if not self.alive or self.address is None:
            raise ReplicaUnavailable(f"replica {self.node_id} is unavailable")
        try:
            connection = Client(self.address, authkey=self.authkey)
            connection.send(request)
            response = connection.recv()
            connection.close()
        except (OSError, EOFError, ConnectionError) as error:
            raise ReplicaUnavailable(f"replica {self.node_id} RPC failed") from error
        if not response["ok"]:
            error_type = response.get("error_type")
            message = response.get("error", "replica RPC failed")
            if error_type == "StaleEpochError":
                raise StaleEpochError(message)
            if error_type == "ReplicaUnavailable":
                raise ReplicaUnavailable(message)
            raise ProtocolError(message)
        return response["result"]

    def stop(self) -> None:
        if not self.alive:
            return
        try:
            self.rpc({"operation": "shutdown"})
        finally:
            assert self.process is not None
            self.process.join(10)
            if self.process.is_alive():
                self.process.terminate()
                self.process.join(5)

    def crash(self) -> None:
        if self.process is None:
            return
        if self.process.is_alive():
            self.process.terminate()
        self.process.join(5)
