"""Resident HTTP boundary, including closed-loop concurrent clients.

Start the real servers separately. This driver never substitutes Qdrant Edge for
the REST server, changes an index, or drops an unsuccessful request. See the
2026-10-03 HTTP plan for fixed workload, resources, and lifecycle requirements.
"""

from __future__ import annotations

import argparse
import asyncio
from contextlib import AsyncExitStack
import importlib.metadata
import json
import math
from pathlib import Path
import statistics
import struct
from time import perf_counter_ns

import httpx

from benchmarks.post_hnsw import nearest_rank
from benchmarks.qdrant_compare import execution_kind, latency_parity
from benchmarks.qdrant_workload import (
    MODES, file_sha256, filter_spec, load_workload, validate_result,
)


def search_body(engine, spec, vector, mode, ordinal, ef, *, exact=False):
    condition = filter_spec(mode, ordinal)
    if engine == "akasha":
        expression = None if condition is None else {
            "kind": "condition", "name": condition[0], "operator": "eq",
            "type": "int", "value": condition[1],
        }
        return {"metric": spec["metric"], "k": spec["k"], "vector": vector,
                "mode": "exact" if exact else "approx", "ef_search": ef,
                "filter": expression}
    if engine != "qdrant":
        raise ValueError("unknown engine")
    expression = None if condition is None else {
        "must": [{"key": condition[0], "match": {"value": condition[1]}}],
    }
    return {"query": vector, "limit": spec["k"], "filter": expression,
            "params": {"hnsw_ef": ef, "exact": exact},
            "with_payload": False, "with_vector": False}


async def request_sample(client, path, body, ordinal):
    """Keep failures as samples; JSON serialization and decode are timed."""
    sample = {"ordinal": ordinal}
    start = perf_counter_ns()
    try:
        response = await client.post(path, json=body)
        sample["http_status"] = response.status_code
        sample["body"] = response.json()
        response.raise_for_status()
    except Exception as error:
        sample["error"] = f"{type(error).__name__}: {error}"
    sample["latency_ns"] = perf_counter_ns() - start
    return sample


async def concurrent_requests(clients, path, bodies):
    """Each worker owns one connection and one outstanding request at a time."""
    if not clients or not bodies:
        raise ValueError("clients and requests required")
    items = list(bodies.items())
    ready = asyncio.Event()

    async def worker(index, client):
        await ready.wait()
        samples = []
        for ordinal, body in items[index::len(clients)]:
            sample = await request_sample(client, path, body, ordinal)
            sample["client"] = index
            samples.append(sample)
        return samples

    tasks = [asyncio.create_task(worker(i, client)) for i, client in enumerate(clients)]
    start = perf_counter_ns()
    ready.set()
    groups = await asyncio.gather(*tasks)
    wall_ns = perf_counter_ns() - start
    samples = sorted((s for group in groups for s in group), key=lambda s: s["ordinal"])
    return samples, wall_ns


def decode_hits(engine, body):
    hits = body if engine == "akasha" else body["result"]["points"]
    if not isinstance(hits, list):
        raise ValueError("result must be a list")
    for hit in hits:
        if type(hit["id"]) is not int:
            raise ValueError("integer point ID required")
        if not isinstance(hit["score"], (int, float)) or not math.isfinite(hit["score"]):
            raise ValueError("finite score required")
    return hits


def audit_sample(sample, engine, workload, expected, mode, reference=None):
    sample["valid"] = False
    sample["recall"] = 0.0
    if "error" in sample:
        return
    try:
        hits = decode_hits(engine, sample["body"])
        ids = [h["id"] for h in hits]
        bits = [struct.pack("<f", h["score"]).hex() for h in hits]
        sample["ids"], sample["scores_f32_hex"] = ids, bits
        sample["recall"] = validate_result(workload, ids, expected, mode, sample["ordinal"])
        if reference is not None and (ids != reference.get("ids") or bits != reference.get("scores_f32_hex")):
            raise ValueError("concurrent result differs from serial preflight IDs/score bits")
        sample["valid"] = True
    except (KeyError, TypeError, ValueError, OverflowError, struct.error) as error:
        sample["audit_error"] = str(error)


def cell_summary(samples, wall_ns, expected_ordinals, target=.95):
    if wall_ns <= 0:
        raise ValueError("positive wall duration required")
    complete = sorted(s["ordinal"] for s in samples) == sorted(expected_ordinals)
    latency = [s["latency_ns"] for s in samples]
    if not latency or min(latency) <= 0:
        raise ValueError("positive latency samples required")
    recall = statistics.mean(s.get("recall", 0.0) for s in samples)
    quality = complete and all(s.get("valid", False) for s in samples) and recall >= target
    return {"samples": len(samples), "wall_ns": wall_ns, "qps": len(samples) * 1e9 / wall_ns,
            **{f"p{p}_ns": nearest_rank(latency, p / 100) for p in (50, 95, 99)},
            "complete": complete, "recall": recall,
            "quality_status": "PASSED" if quality else "FAILED"}


def matched_http_summary(akasha, qdrant, concurrencies=(1, 2, 4)):
    rows = []
    identity_keys = ("workload_checksum", "trial", "target_recall", "boundary")
    compatible = all(akasha.get(k) == qdrant.get(k) for k in identity_keys)
    compatible &= all(k in akasha and k in qdrant for k in identity_keys)
    compatible &= akasha.get("spec") == qdrant.get("spec")
    for mode in MODES:
        for concurrency in concurrencies:
            row = {"mode": mode, "concurrency": concurrency,
                   "quality_status": "FAILED", "status": "FAILED"}
            selected = {}
            for engine, report in (("akasha", akasha), ("qdrant", qdrant)):
                cells = [c for c in report.get("cells", []) if
                         c["mode"] == mode and c["concurrency"] == concurrency]
                if len(cells) == 1 and report.get("preflight_valid") and cells[0]["quality_status"] == "PASSED":
                    selected[engine] = cells[0]
            if compatible and len(selected) == 2:
                row.update(selected)
                row["quality_status"] = "PASSED"
                row.update(latency_parity(selected["akasha"], selected["qdrant"]))
            else:
                row["reason"] = "missing/duplicate cell, incompatible workload/trial, or quality failure"
            rows.append(row)
    return rows


async def measure(args):
    source = args.workload
    spec = json.loads((source / "spec.json").read_text())
    workload = load_workload(source / "workload.npz")
    oracle = json.loads((source / "oracle.json").read_text())
    if oracle["checksum"] != workload.checksum():
        raise ValueError("oracle checksum mismatch")
    efs = list(map(int, args.efs.split(",")))
    if len(efs) != len(MODES) or min(efs) < 1:
        raise ValueError("four positive ef values required")
    concurrencies = list(map(int, args.concurrency.split(",")))
    if len(set(concurrencies)) != len(concurrencies) or min(concurrencies) < 1:
        raise ValueError("unique positive client counts required")
    if args.output.exists():
        raise FileExistsError(args.output)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {"engine": args.engine, "boundary": "HTTP JSON loopback closed-loop",
              "driver_sha256": file_sha256(Path(__file__)),
              "httpx_version": importlib.metadata.version("httpx"),
              "trial": args.trial, "spec": spec, "target_recall": spec["target_recall"],
              "workload_checksum": workload.checksum(), "base_url": args.url,
              "inputs_sha256": {name: file_sha256(source / name) for name in
                                ["spec.json", "workload.npz", "oracle.json"]},
              "concurrencies": concurrencies, "efs": efs, "preflight": [], "cells": [],
              "preflight_valid": True,
              "concurrent_stats": "per-request counters unavailable; last_search_stats is shared"}

    def save():
        args.output.write_text(json.dumps(report, indent=2) + "\n")

    path = f"/collections/{args.collection}/" + ("search" if args.engine == "akasha" else "points/query")
    health = "/health" if args.engine == "akasha" else "/healthz"
    timeout = httpx.Timeout(60.0)
    try:
        async with AsyncExitStack() as stack:
            clients = [await stack.enter_async_context(httpx.AsyncClient(
                base_url=args.url, timeout=timeout, trust_env=False,
                limits=httpx.Limits(max_connections=1, max_keepalive_connections=1),
            )) for _ in range(max(concurrencies))]
            for client in clients:
                (await client.get(health)).raise_for_status()
            for mi, mode in enumerate(MODES):
                vectors = workload.queries[mi].tolist()
                references = {}
                for ordinal, vector in enumerate(vectors):
                    preflight = {"mode": mode, "ordinal": ordinal}
                    for exact in [True, False]:
                        body = search_body(args.engine, spec, vector, mode, ordinal, efs[mi], exact=exact)
                        sample = await request_sample(clients[0], path, body, ordinal)
                        audit_sample(sample, args.engine, workload, oracle["ids"][mi][ordinal], mode)
                        if exact:
                            sample["valid"] &= sample["recall"] == 1.0
                        elif args.engine == "akasha":
                            response = await clients[0].get(f"/collections/{args.collection}/stats")
                            response.raise_for_status()
                            sample["stats"] = response.json()["last_search"]
                            sample["execution"] = execution_kind("akasha", mode, sample["stats"], sample["recall"], spec)
                            sample["valid"] &= sample["execution"] != "invalid_fallback"
                        report["preflight_valid"] &= sample["valid"]
                        preflight["exact" if exact else "approx"] = sample
                        if not exact:
                            references[ordinal] = sample
                    report["preflight"].append(preflight)
                for concurrency in concurrencies:
                    for client in clients[:concurrency]:
                        (await client.get(health)).raise_for_status()
                    warmup = []
                    for ordinal in range(3):
                        body = search_body(args.engine, spec, vectors[ordinal], mode, ordinal, efs[mi])
                        warmup.append(await request_sample(clients[0], path, body, ordinal))
                    bodies = {i: search_body(args.engine, spec, vectors[i], mode, i, efs[mi]) for i in range(3, len(vectors))}
                    samples, wall_ns = await concurrent_requests(clients[:concurrency], path, bodies)
                    for sample in warmup + samples:
                        i = sample["ordinal"]
                        audit_sample(sample, args.engine, workload, oracle["ids"][mi][i], mode, references[i])
                    cell = {"mode": mode, "concurrency": concurrency, "ef": efs[mi],
                            **cell_summary(samples, wall_ns, bodies, spec["target_recall"]),
                            "warmup": warmup, "raw_samples": samples}
                    if not all(s["valid"] for s in warmup) or not report["preflight_valid"]:
                        cell["quality_status"] = "FAILED"
                    report["cells"].append(cell)
                    save()
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
        report["preflight_valid"] = False
        save()
        raise
    save()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, choices=["akasha", "qdrant"])
    parser.add_argument("--url", required=True)
    parser.add_argument("--collection", default="benchmark")
    parser.add_argument("--workload", type=Path, required=True)
    parser.add_argument("--efs", required=True, help="all,correlated,independent,selective")
    parser.add_argument("--concurrency", default="1,2,4")
    parser.add_argument("--trial", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    report = asyncio.run(measure(parser.parse_args()))
    return 0 if report["preflight_valid"] and all(c["quality_status"] == "PASSED" for c in report["cells"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
