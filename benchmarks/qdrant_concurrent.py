"""External clients against one shared handle through the same local HTTP shim.

This measures a separate service boundary, not the binding-only comparison or
either product's HTTP server. Requests include server-side conversion and JSON
responses. Client processes measure queueing even when a binding holds the GIL.
Run one isolated worker with ``python -m benchmarks.qdrant_concurrent JOB.json``.
"""

from __future__ import annotations

from collections import Counter
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import multiprocessing
import os
from pathlib import Path
import queue
import socket
import statistics
import struct
import sys
import threading
import time
import traceback

from benchmarks.qdrant_compare import Akasha, Qdrant, execution_kind, latency_summary
from benchmarks.qdrant_workload import MODES, file_sha256, load_workload, validate_result


def result_payload(values):
    return {"ids": [int(value.id) for value in values],
            "scores_f32_hex": [struct.pack("<f", float(value.score)).hex() for value in values]}


def serve(database):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def setup(self):
            super().setup()
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        def log_message(self, *_args):
            pass

        def do_POST(self):
            try:
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                values = database.search(database.request(**request))
                body, status = result_payload(values), 200
            except Exception:
                body, status = {"error": traceback.format_exc()}, 500
            encoded = json.dumps(body, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def _client(port, requests, passes, barrier, output, timeout):
    connection = HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        prepared = [(request["ordinal"], json.dumps(request, separators=(",", ":")).encode())
                    for request in requests]
        connection.connect()
        connection.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        # Establish the persistent connection and server thread before timing.
        connection.request("POST", "/search", prepared[0][1], {"Content-Type": "application/json"})
        response = connection.getresponse()
        warmup = json.loads(response.read())
        if response.status != 200:
            raise RuntimeError(warmup)
        barrier.wait(timeout=timeout)
        rows = []
        for repeat in range(passes):
            for ordinal, encoded in prepared:
                started = time.perf_counter_ns()
                connection.request("POST", "/search", encoded, {"Content-Type": "application/json"})
                response = connection.getresponse()
                values = json.loads(response.read())
                ended = time.perf_counter_ns()
                if response.status != 200:
                    raise RuntimeError(values)
                rows.append({"client_pid": os.getpid(), "ordinal": ordinal, "pass": repeat,
                             "start_ns": started, "end_ns": ended, "latency_ns": ended - started,
                             "response": values})
        output.put({"rows": rows})
    except BaseException:
        barrier.abort()
        output.put({"error": traceback.format_exc()})
    finally:
        connection.close()


def run_clients(port, requests, *, clients, passes, timeout=60):
    if not 1 <= clients <= len(requests) or passes < 1:
        raise ValueError("positive passes and at least one request per client required")
    context = multiprocessing.get_context("spawn")
    barrier, output = context.Barrier(clients), context.Queue()
    processes = [context.Process(target=_client, args=(
        port, requests[index::clients], passes, barrier, output, timeout)) for index in range(clients)]
    deadline = time.monotonic() + timeout
    try:
        for process in processes:
            process.start()
        rows = []
        # Drain before joining: a full pipe otherwise keeps the child alive.
        for _ in processes:
            try:
                message = output.get(timeout=max(0.001, deadline - time.monotonic()))
            except queue.Empty as error:
                raise RuntimeError("concurrent clients timed out") from error
            if "error" in message:
                raise RuntimeError("client failed: " + message["error"])
            rows.extend(message["rows"])
        for process in processes:
            process.join(timeout=max(0.001, deadline - time.monotonic()))
            if process.exitcode != 0:
                raise RuntimeError(f"client did not exit successfully: {process.exitcode}")
        expected = Counter((request["ordinal"], repeat) for request in requests for repeat in range(passes))
        if Counter((row["ordinal"], row["pass"]) for row in rows) != expected:
            raise RuntimeError("missing or duplicate concurrent responses")
        return rows
    finally:
        for process in processes:
            if process.is_alive():
                process.terminate()
            if process.pid is not None:
                process.join(timeout=5)
                if process.is_alive():
                    process.kill()
                    process.join()
        output.close()
        output.join_thread()


def wall_summary(rows):
    summary = latency_summary([row["latency_ns"] for row in rows])
    wall = max(row["end_ns"] for row in rows) - min(row["start_ns"] for row in rows)
    return {**summary, "wall_ns": wall, "qps": len(rows) * 1e9 / wall}


def measure(job):
    corpus = Path(job["corpus"])
    spec = json.loads((corpus / "spec.json").read_text())
    data = load_workload(corpus / "workload.npz")
    oracle = json.loads((corpus / "oracle.json").read_text())
    if data.checksum() != oracle["checksum"]:
        raise ValueError("oracle workload checksum mismatch")
    engine = job["engine"]
    if engine == "akasha":
        from akashadb import _kernel as native
    elif engine == "qdrant":
        from qdrant_edge import qdrant_edge as native
    else:
        raise ValueError("unknown engine")
    binary_hash = file_sha256(Path(native.__file__))
    if binary_hash != job["native_binary_sha256"]:
        raise ValueError("wrong native binary")
    report = {"engine": engine, "status": "running", "spec": spec,
              "native_binary_sha256": binary_hash, "workload_sha256": data.checksum(),
              "clients": job["clients"], "passes": job["passes"], "measurements": [],
              "scope": "Common loopback HTTP shim, one engine handle, persistent external process clients. "
                       "QPS uses elapsed wall time; latency includes queueing, server request conversion, "
                       "response encoding and client decoding. Preflight and connection warmups excluded. "
                       "Repeated passes add timing samples, not independent recall observations. "
                       "Execution stats are serial preflight only; shared last-search stats are racy."}
    output = Path(job["output"])
    database = (Akasha if engine == "akasha" else Qdrant)(Path(job["database"]), spec, reopen=True)
    server = thread = None
    try:
        report["info"] = database.info()
        server, thread = serve(database)
        for mode_index, mode in enumerate(MODES):
            ef = job["efs"][mode_index]
            queries = [query.tolist() for query in data.queries[mode_index]]
            preflight = []
            for ordinal, query in enumerate(queries):
                exact = database.search(database.request(query, mode, ordinal, ef, exact=True))
                if validate_result(data, [int(value.id) for value in exact],
                                   oracle["ids"][mode_index][ordinal], mode, ordinal) != 1.0:
                    raise ValueError("exact oracle mismatch")
                values = database.search(database.request(query, mode, ordinal, ef))
                result = result_payload(values)
                recall = validate_result(data, result["ids"], oracle["ids"][mode_index][ordinal], mode, ordinal)
                stats = database.stats()
                preflight.append({"ordinal": ordinal, **result, "recall": recall, "stats": stats,
                                  "execution": execution_kind(engine, mode, stats, recall, spec)})
            requests = [{"query": queries[ordinal], "mode": mode, "ordinal": ordinal, "ef": ef}
                        for ordinal in range(3, len(queries))]
            rows = run_clients(server.server_address[1], requests, clients=job["clients"], passes=job["passes"])
            # Every timed result must equal the independently audited preflight.
            for row in rows:
                expected = preflight[row["ordinal"]]
                if row["response"] != {key: expected[key] for key in ("ids", "scores_f32_hex")}:
                    raise ValueError(f"concurrent response changed: {mode}, {row['ordinal']}")
            recall = statistics.mean(row["recall"] for row in preflight[3:])
            execution_valid = all(row["execution"] != "invalid_fallback" for row in preflight)
            report["measurements"].append({"mode": mode, "ef": ef, "recall": recall,
                "unique_queries": len(requests), "execution_valid": execution_valid,
                "execution_counts": dict(Counter(row["execution"] for row in preflight[3:])),
                "quality_status": "PASSED" if recall >= spec["target_recall"] and execution_valid else "FAILED",
                "preflight": preflight, "rows": rows, **wall_summary(rows)})
            output.write_text(json.dumps(report, indent=2) + "\n")
        report["status"] = "ok"
    except BaseException:
        report["status"] = "error"
        report["error"] = traceback.format_exc()
        raise
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        database.close()
        output.write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    measure(json.loads(Path(sys.argv[1]).read_text()))
