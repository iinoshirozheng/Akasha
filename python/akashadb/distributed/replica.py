"""Independent replica process backed by one Mojo collection per shard."""

from __future__ import annotations

import json
import multiprocessing
from multiprocessing.connection import Client, Connection, Listener
import os
from pathlib import Path
import shutil
from typing import Any

from akashadb.database import Collection
from akashadb.models import (
    BatchMutation,
    PayloadField,
    SearchRequest,
    SparseElement,
)

from .protocol import (
    ProtocolError,
    ReplicaJournal,
    ReplicatedEntry,
    canonical_bytes,
    checked_envelope,
    decode_envelope,
)


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


class ReplicaShard:
    def __init__(self, root: Path, shard_id: int, dimension: int) -> None:
        self.root = root
        self.shard_id = shard_id
        self.dimension = dimension
        self.root.mkdir(parents=True, exist_ok=True)
        state = _load_checked(
            self.root / "replica-state.json",
            {"term": 0, "placement_epoch": 0, "applied_index": 0},
        )
        self.term = int(state["term"])
        self.placement_epoch = int(state["placement_epoch"])
        self.applied_index = int(state["applied_index"])
        self.journal = ReplicaJournal(self.root / "replicated.log")
        self.collection = Collection(self.root / "collection", dimension)
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

    def query(self, request: dict[str, Any]) -> list[dict[str, Any]]:
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
        return [
            {"id": result.id, "score": result.score}
            for result in self.collection.search(typed)
        ]

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
        index: int,
        term: int,
        placement_epoch: int,
    ) -> dict[str, Any]:
        if index < self.applied_index:
            raise ProtocolError("snapshot cannot regress applied index")
        self.collection.close()
        collection_path = self.root / "collection"
        if collection_path.exists():
            shutil.rmtree(collection_path)
        journal_path = self.root / "replicated.log"
        if journal_path.exists():
            journal_path.unlink()
        self.collection = Collection(collection_path, self.dimension)
        if rows:
            mutations: list[BatchMutation] = []
            sparse_rows: list[tuple[int, list[SparseElement]]] = []
            for row in rows:
                point_id = int(row["id"])
                fields = [
                    PayloadField(str(item["name"]), item["type"], item["value"])
                    for item in row.get("fields", [])
                ]
                mutations.append(
                    BatchMutation.upsert(
                        point_id,
                        [float(value) for value in row["vector"]],
                        fields,
                    )
                )
                sparse_rows.append(
                    (
                        point_id,
                        [
                            SparseElement(
                                int(item["term_id"]), float(item["weight"])
                            )
                            for item in row.get("sparse", [])
                        ],
                    )
                )
            self.collection.apply_batch(mutations)
            for point_id, sparse in sparse_rows:
                if sparse:
                    self.collection.upsert_sparse(point_id, sparse)
        self.journal = ReplicaJournal(journal_path)
        self.journal.install_snapshot(index)
        self.term = term
        self.placement_epoch = placement_epoch
        self.applied_index = index
        self._publish_state()
        return self.status()

    def status(self) -> dict[str, Any]:
        return {
            "shard_id": self.shard_id,
            "term": self.term,
            "placement_epoch": self.placement_epoch,
            "applied_index": self.applied_index,
            "last_sequence": self.collection.last_sequence,
        }

    def close(self) -> None:
        self.collection.close()


def replica_server_main(
    node_id: str,
    root: str,
    dimension: int,
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
                        shard = ReplicaShard(Path(root) / f"shard-{shard_id}", shard_id, dimension)
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
                        result = {
                            "rows": shard.export_records(),
                            "applied_index": shard.applied_index,
                        }
                    elif operation == "entries":
                        result = shard.entries_after(int(request["after_index"]))
                    elif operation == "install_snapshot":
                        result = shard.install_snapshot(
                            request["rows"],
                            int(request["index"]),
                            int(request["term"]),
                            int(request["placement_epoch"]),
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
        authkey: bytes,
    ) -> None:
        self.node_id = node_id
        self.root = Path(root)
        self.dimension = dimension
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
            args=(self.node_id, str(self.root), self.dimension, self.authkey, child),
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
