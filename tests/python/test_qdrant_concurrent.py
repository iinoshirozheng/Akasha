"""Check external-client timing and failure handling without a database build."""

from types import SimpleNamespace

import pytest

from benchmarks.qdrant_concurrent import run_clients, serve, wall_summary


class EchoEngine:
    def request(self, query, mode, ordinal, ef):
        return ordinal

    def search(self, ordinal):
        return [SimpleNamespace(id=ordinal, score=0.5)]


def test_wall_throughput_includes_overlap_and_idle_gaps():
    rows = [
        {"start_ns": 100, "end_ns": 200, "latency_ns": 100},
        {"start_ns": 150, "end_ns": 250, "latency_ns": 100},
        {"start_ns": 500, "end_ns": 600, "latency_ns": 100},
    ]
    result = wall_summary(rows)
    assert result["wall_ns"] == 500
    assert result["qps"] == 3 * 1e9 / 500
    assert result["p95_ns"] == 100


def test_external_clients_complete_and_preserve_all_responses():
    server, thread = serve(EchoEngine())
    try:
        requests = [{"query": [0.0], "mode": "all", "ordinal": i, "ef": 10}
                    for i in range(8)]
        result = run_clients(server.server_address[1], requests, clients=2, passes=2)
        assert len(result) == 16
        assert len({row["client_pid"] for row in result}) == 2
        for row in result:
            assert row["response"] == {"ids": [row["ordinal"]], "scores_f32_hex": ["0000003f"]}
            assert row["end_ns"] - row["start_ns"] == row["latency_ns"]
        assert {(row["ordinal"], row["pass"]) for row in result} == {
            (ordinal, repeat) for ordinal in range(8) for repeat in range(2)}
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_external_client_server_failure_is_reported_and_reaped():
    import multiprocessing

    class FailingEngine(EchoEngine):
        def search(self, ordinal):
            raise ValueError("injected search failure")

    original = {child.pid for child in multiprocessing.active_children()}
    server, thread = serve(FailingEngine())
    try:
        with pytest.raises(RuntimeError, match="client failed"):
            run_clients(server.server_address[1],
                        [{"query": [0.0], "mode": "all", "ordinal": 0, "ef": 10}],
                        clients=1, passes=1, timeout=10)
        assert {child.pid for child in multiprocessing.active_children()} == original
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
