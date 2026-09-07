from fastapi.testclient import TestClient

from akashadb import Collection, LocalDatabase
from apps.server.main import app, create_app


def test_server_exposes_project_metadata() -> None:
    assert app.title == "AkashaDB"
    assert app.version == "0.1.0"


def test_http_adapter_runs_collection_document_and_hybrid_flow(tmp_path) -> None:
    local_app = create_app(LocalDatabase(tmp_path))
    with TestClient(local_app) as client:
        assert client.get("/health").json() == {"status": "ok", "kernel": "mojo"}
        opened = client.post("/collections/demo", json={"dimension": 2})
        assert opened.status_code == 200

        first = client.post(
            "/collections/demo/points",
            json={
                "id": 1,
                "vector": [1.0, 0.0],
                "fields": [{"name": "kind", "type": "string", "value": "chunk"}],
                "sparse": [{"term_id": 7, "weight": 2.0}],
            },
        )
        second = client.post(
            "/collections/demo/points",
            json={
                "id": 2,
                "vector": [0.5, 0.5],
                "sparse": [{"term_id": 7, "weight": 1.0}],
            },
        )
        assert first.status_code == second.status_code == 200
        assert client.get("/collections/demo/points/1").json()["fields"][0][
            "value"
        ] == "chunk"

        searched = client.post(
            "/collections/demo/search",
            json={
                "metric": "dot",
                "mode": "hybrid",
                "k": 2,
                "fetch_k": 2,
                "vector": [1.0, 0.0],
                "sparse": [{"term_id": 7, "weight": 1.0}],
                "filter": {
                    "kind": "condition",
                    "name": "kind",
                    "operator": "eq",
                    "type": "string",
                    "value": "chunk",
                },
            },
        )
        assert searched.status_code == 200
        assert [item["id"] for item in searched.json()] == [1]

        nested = client.post(
            "/collections/demo/search",
            json={
                "metric": "dot",
                "mode": "exact",
                "k": 2,
                "vector": [1.0, 0.0],
                "filter": {
                    "kind": "any",
                    "children": [
                        {
                            "kind": "condition",
                            "name": "kind",
                            "operator": "eq",
                            "type": "string",
                            "value": "chunk",
                        },
                        {
                            "kind": "condition",
                            "name": "kind",
                            "operator": "ne",
                            "type": "string",
                            "value": "chunk",
                        },
                    ],
                },
            },
        )
        assert nested.status_code == 200
        assert [item["id"] for item in nested.json()] == [1]
        assert client.post("/collections/demo/flush").status_code == 200
        assert client.delete("/collections/demo").json() == {"closed": True}


def test_http_adapter_returns_deterministic_errors(tmp_path) -> None:
    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        missing = client.get("/collections/missing/points/1")
        invalid = client.post("/collections/demo", json={"dimension": 0})
        assert missing.status_code == 404
        assert invalid.status_code == 422


def test_http_config_round_trip_and_separate_search_stats_endpoint(tmp_path) -> None:
    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        opened = client.post(
            "/collections/configured",
            json={
                "dimension": 2,
                "ann_metric": "dot",
                "scalar_kind": "f16",
                "m": 8,
                "m0": 16,
                "ef_construction": 64,
                "default_ef_search": 24,
                "max_ef_search": 96,
                "rebuild_inactive_percent": 30,
                "level_seed": 77,
            },
        )
        assert opened.status_code == 200
        assert opened.json()["config"]["ann_metric"] == "dot"
        assert opened.json()["config"]["scalar_kind"] == "f16"
        for point_id in range(64):
            assert client.post(
                "/collections/configured/points",
                json={"id": point_id, "vector": [float(point_id + 1), 1.0]},
            ).status_code == 200
        searched = client.post(
            "/collections/configured/search",
            json={
                "metric": "l2",
                "mode": "approx",
                "k": 3,
                "ef_search": 20,
                "vector": [4.0, 1.0],
            },
        )
        assert searched.status_code == 200
        assert isinstance(searched.json(), list)
        stats = client.get("/collections/configured/stats")
        assert stats.status_code == 200
        assert stats.json()["last_search"]["planner_reason"] == "metric_mismatch"
        assert stats.json()["last_search"]["requested_ef"] == 20
        assert stats.json()["config"]["fingerprint"] > 0


def test_http_accepts_documented_camel_case_ann_options(tmp_path) -> None:
    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        opened = client.post(
            "/collections/camel",
            json={
                "dimension": 2,
                "annMetric": "cosine",
                "scalarKind": "bf16",
                "M": 8,
                "M0": 16,
                "efConstruction": 64,
                "defaultEfSearch": 24,
                "maxEfSearch": 96,
                "rebuildInactivePercent": 30,
                "levelSeed": 77,
            },
        )
        assert opened.status_code == 200
        assert opened.json()["config"]["ann_metric"] == "cosine"
        assert opened.json()["config"]["m"] == 8


def test_http_rejects_unknown_ann_option_before_creating_state(tmp_path) -> None:
    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        opened = client.post(
            "/collections/unknown", json={"dimension": 2, "unknownAnn": 7}
        )
        assert opened.status_code == 422
        assert not (tmp_path / "unknown").exists()


def test_http_metrics_and_graceful_shutdown_release_collection_locks(tmp_path) -> None:
    database = LocalDatabase(tmp_path)
    with TestClient(create_app(database)) as client:
        assert client.post("/collections/live", json={"dimension": 2}).status_code == 200
        assert client.post(
            "/collections/live/points", json={"id": 1, "vector": [1.0, 0.0]}
        ).status_code == 200
        metrics = client.get("/metrics").json()
        assert metrics["open_collections"] == 1
        assert metrics["collections"]["live"]["writes"] >= 1

    assert database.metrics()["open_collections"] == 0
    reopened = Collection(tmp_path / "live", 2)
    assert reopened.get(1).vector == [1.0, 0.0]
    reopened.close()
