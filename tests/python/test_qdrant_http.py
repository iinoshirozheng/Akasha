import asyncio
from copy import deepcopy

import httpx
import pytest

from benchmarks.qdrant_http import (
    audit_sample, cell_summary, concurrent_requests, matched_http_summary,
    request_sample, search_body,
)
from benchmarks.qdrant_workload import MODES, exact_ids, synthetic_workload


def test_concurrent_qps_uses_cell_wall_time_and_keeps_tail():
    samples = [{"ordinal": i, "latency_ns": 100, "valid": True, "recall": 1.0} for i in range(4)]
    result = cell_summary(samples, 200, range(4))
    assert result["qps"] == 20_000_000
    assert result["p95_ns"] == 100
    samples[-1]["latency_ns"] = 1000
    assert cell_summary(samples, 1100, range(4))["p95_ns"] == 1000
    samples[-1]["valid"] = False
    assert cell_summary(samples, 1100, range(4))["quality_status"] == "FAILED"
    assert cell_summary(samples[:3], 200, range(4))["complete"] is False
    samples[-1] = samples[0]
    assert cell_summary(samples, 200, range(4))["complete"] is False


def test_closed_loop_has_bounded_overlap_and_retains_http_failure():
    async def run():
        active, peak = 0, 0
        seen = []

        async def handle(request):
            nonlocal active, peak
            import json
            ordinal = json.loads(request.content)["ordinal"]
            seen.append(ordinal)
            active += 1
            peak = max(peak, active)
            await asyncio.sleep(.002)
            active -= 1
            return httpx.Response(500 if ordinal == 4 else 200, json=[])

        async with httpx.AsyncClient(transport=httpx.MockTransport(handle), base_url="http://benchmark") as client:
            samples, wall = await concurrent_requests([client, client], "/search", {i: {"ordinal": i} for i in range(9)})
        assert sorted(seen) == list(range(9))
        assert peak == 2
        assert [s["ordinal"] for s in samples] == list(range(9))
        assert samples[4]["http_status"] == 500 and "error" in samples[4]
        assert all(s["latency_ns"] > 0 for s in samples) and wall > 0
    asyncio.run(run())


@pytest.mark.parametrize("failure", ["json", "timeout"])
def test_transport_failures_remain_positive_duration_samples(failure):
    async def run():
        def handle(request):
            if failure == "timeout":
                raise httpx.ReadTimeout("timed out", request=request)
            return httpx.Response(200, text="invalid JSON")
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle), base_url="http://benchmark") as client:
            sample = await request_sample(client, "/search", {}, 7)
        assert sample["ordinal"] == 7 and sample["latency_ns"] > 0
        assert "error" in sample
    asyncio.run(run())


def test_http_audit_checks_live_filter_finite_and_serial_identity():
    workload = synthetic_workload(128, 8, 4)
    expected = exact_ids(workload, workload.queries[0, 3], "dot", 10, "all", 3)
    good = {"ordinal": 3, "body": [{"id": i, "score": float(i)} for i in expected]}
    audit_sample(good, "akasha", workload, expected, "all")
    assert good["valid"] and good["recall"] == 1.0
    for value in [float("nan"), float("inf")]:
        bad = deepcopy(good)
        bad["body"][0]["score"] = value
        audit_sample(bad, "akasha", workload, expected, "all")
        assert not bad["valid"]
    for bad_id in [int(workload.deletes[0]), expected[1]]:
        bad = deepcopy(good)
        bad["body"][0]["id"] = bad_id
        audit_sample(bad, "akasha", workload, expected, "all")
        assert not bad["valid"]
    bad = deepcopy(good)
    bad["body"][0]["score"] += 1
    audit_sample(bad, "akasha", workload, expected, "all", good)
    assert not bad["valid"] and "serial" in bad["audit_error"]
    bad = deepcopy(good)
    audit_sample(bad, "akasha", workload, expected, "selective")
    assert not bad["valid"]
    wrapped = {"ordinal": 3, "body": {"result": {"points": good["body"]}}}
    audit_sample(wrapped, "qdrant", workload, expected, "all", good)
    assert wrapped["valid"]


def test_http_request_filter_and_exact_controls_match_both_public_apis():
    spec = {"metric": "cosine", "k": 10}
    a = search_body("akasha", spec, [1, 2], "selective", 35, 128)
    q = search_body("qdrant", spec, [1, 2], "selective", 35, 96)
    assert a["filter"]["name"] == q["filter"]["must"][0]["key"] == "rare"
    assert a["filter"]["value"] == q["filter"]["must"][0]["match"]["value"] == 3
    assert a["mode"] == "approx" and q["params"] == {"hnsw_ef": 96, "exact": False}
    assert search_body("akasha", spec, [1, 2], "all", 3, 128, exact=True)["mode"] == "exact"
    assert search_body("qdrant", spec, [1, 2], "all", 3, 96, exact=True)["params"]["exact"]


@pytest.mark.parametrize("failure", ["qps", "p95", "recall", "missing", "duplicate", "trial", "workload", "preflight", "spec", "boundary"])
def test_strict_http_gate_cannot_hide_one_bad_cell(failure):
    a = {"workload_checksum": "same", "trial": 0, "target_recall": .95, "preflight_valid": True, "boundary": "HTTP",
         "cells": [{"mode": mode, "concurrency": c, "quality_status": "PASSED", "qps": 100, "p95_ns": 100}
                   for mode in MODES for c in [1, 2, 4]]}
    b = deepcopy(a)
    if failure == "qps":
        a["cells"][0]["qps"] = 99.99
    elif failure == "p95":
        a["cells"][0]["p95_ns"] = 100.01
    elif failure == "recall":
        a["cells"][0]["quality_status"] = "FAILED"
    elif failure == "missing":
        a["cells"].pop(0)
    elif failure == "duplicate":
        a["cells"].append(deepcopy(a["cells"][0]))
    elif failure == "trial":
        a["trial"] = 1
    elif failure == "workload":
        a["workload_checksum"] = "different"
    elif failure == "spec":
        a["spec"] = {"metric": "dot"}
        b["spec"] = {"metric": "cosine"}
    elif failure == "boundary":
        b["boundary"] = "bindings"
    else:
        a["preflight_valid"] = False
    rows = matched_http_summary(a, b)
    assert len(rows) == 12 and rows[0]["status"] == "FAILED"
    if failure not in ["qps", "p95"]:
        assert "qps_ratio_akasha_over_qdrant" not in rows[0]
    if failure not in ["trial", "workload", "preflight", "spec", "boundary"]:
        assert all(r["status"] == "PASSED" for r in rows[1:])


def test_akasha_http_body_reaches_public_search_with_matching_filters(tmp_path):
    from fastapi.testclient import TestClient
    from akashadb import LocalDatabase
    from apps.server.main import create_app
    from benchmarks.qdrant_compare import Akasha
    from benchmarks.qdrant_http_matrix import akasha_config

    workload = synthetic_workload(128, 8, 2)
    spec = {"dimension": 8, "metric": "dot", "scalar": "f32", "efs": [128],
            "points": 128, "seed": 12345, "k": 10}
    database = Akasha(tmp_path / "benchmark", spec)
    database.upsert(workload.ids, workload.vectors)
    database.optimize()
    database.upsert(workload.update_ids, workload.updates)
    database.delete(workload.deletes)
    database.flush()
    database.close()
    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        response = client.post("/collections/benchmark", json=akasha_config(spec))
        assert response.status_code == 200, response.text
        for mi, mode in enumerate(MODES):
            query = workload.queries[mi, 3].tolist()
            body = search_body("akasha", spec, query, mode, 3, 128, exact=True)
            response = client.post("/collections/benchmark/search", json=body)
            assert response.status_code == 200, response.text
            expected = exact_ids(workload, query, "dot", 10, mode, 3)
            sample = {"ordinal": 3, "body": response.json()}
            audit_sample(sample, "akasha", workload, expected, mode)
            assert sample["valid"] and sample["recall"] == 1.0
