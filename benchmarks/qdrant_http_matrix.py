"""Run the fixed resident HTTP matrix with sequential local real servers."""

from __future__ import annotations

import argparse
import asyncio
from contextlib import contextmanager
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import socket
import subprocess
import sys
import time
from types import SimpleNamespace

import httpx

from benchmarks.qdrant_compare import QDRANT_COMMIT
from benchmarks.qdrant_http import matched_http_summary, measure
from benchmarks.qdrant_workload import file_sha256, load_workload, payload

ROOT = Path(__file__).resolve().parents[1]
CORPORA = ("uniform-128", "uniform-1536", "real-1536")
# Previously fixed selected efs. Failures stay visible; no automatic retuning.
EFS = {
    "akasha": ((128, 32, 32, 10), (512, 128, 128, 10), (16, 32, 40, 10)),
    "qdrant": ((96, 256, 256, 10), (512, 512, 512, 10), (24, 128, 128, 10)),
}


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextmanager
def server(command, directory, env, port, health, *, cwd=ROOT):
    """Own one process group; never stop an unrelated listener on the port."""
    with (directory / "server.log").open("x") as log:
        process = subprocess.Popen(["rtk", "proxy", *command], cwd=cwd, env=env,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        url = f"http://127.0.0.1:{port}"
        try:
            with httpx.Client(base_url=url, trust_env=False, timeout=2) as client:
                deadline = time.monotonic() + 90
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(f"server exited {process.returncode}; see {directory}/server.log")
                    try:
                        if client.get(health).status_code == 200:
                            break
                    except httpx.HTTPError:
                        pass
                    if time.monotonic() >= deadline:
                        raise TimeoutError("server readiness timeout")
                    time.sleep(.1)
            yield url
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
            (directory / "server-exit.json").write_text(json.dumps({"exit": process.returncode}) + "\n")


def api(client, method, path, body=None):
    response = client.request(method, path, json=body)
    if response.is_error:
        raise RuntimeError(f"{method} {path}: HTTP {response.status_code}: {response.text}")
    return response.json()


def akasha_config(spec):
    return dict(dimension=spec["dimension"], ann_metric=spec["metric"], scalar_kind=spec["scalar"],
                m=24, m0=48, ef_construction=192, max_level=16,
                default_ef_search=128, max_ef_search=max(512, max(spec["efs"])),
                delta_max_points=spec["points"], rebuild_inactive_percent=90, level_seed=spec["seed"])


def wait_index(client, count, directory, phase, minimum_indexed=None):
    if minimum_indexed is None:
        minimum_indexed = count
    deadline = time.monotonic() + 600
    observations = []
    stable = 0
    while True:
        info = api(client, "GET", "/collections/benchmark")["result"]
        optimization = api(client, "GET", "/collections/benchmark/optimizations?with=queued")["result"]
        observations.append({"info": info, "optimization": optimization})
        (directory / f"{phase}-index-wait.json").write_text(json.dumps(observations, indent=2) + "\n")
        if info["optimizer_status"] != "ok":
            raise RuntimeError(f"optimizer failure: {info['optimizer_status']}")
        ready = (info["status"] == "green" and info["points_count"] == count and
                 info["indexed_vectors_count"] >= minimum_indexed and not optimization["running"] and
                 not optimization.get("queued"))
        stable = stable + 1 if ready else 0
        if stable >= 2:
            return info
        if time.monotonic() >= deadline:
            raise TimeoutError(f"index did not become ready: {phase}")
        time.sleep(.5)


def seed_qdrant(client, workload, spec, directory):
    config = {
        "vectors": {"size": spec["dimension"], "distance": {"cosine": "Cosine", "dot": "Dot", "l2": "Euclid"}[spec["metric"]], "on_disk": False},
        "shard_number": 1, "replication_factor": 1, "on_disk_payload": False,
        "hnsw_config": {"m": 24, "ef_construct": 192, "max_indexing_threads": 1,
                        "full_scan_threshold": spec["qdrant_full_scan_threshold_kib"]},
        "optimizers_config": {"default_segment_number": 1, "indexing_threshold": 0, "max_optimization_threads": 1},
    }
    api(client, "PUT", "/collections/benchmark", config)
    (directory / "collection-config.json").write_text(json.dumps(config, indent=2) + "\n")
    for field in ("correlated", "independent", "rare"):
        api(client, "PUT", "/collections/benchmark/index?wait=true", {"field_name": field, "field_schema": "integer"})

    def upsert(ids, vectors):
        for start in range(0, len(ids), 256):
            points = [{"id": int(i), "vector": v.tolist(), "payload": payload(int(i), spec["seed"])}
                      for i, v in zip(ids[start:start + 256], vectors[start:start + 256], strict=True)]
            api(client, "PUT", "/collections/benchmark/points?wait=true", {"points": points})

    upsert(workload.ids, workload.vectors)
    api(client, "PATCH", "/collections/benchmark", {"optimizers_config": {"indexing_threshold": 1}})
    wait_index(client, spec["points"], directory, "base")
    upsert(workload.update_ids, workload.updates)
    api(client, "POST", "/collections/benchmark/points/delete?wait=true", {"points": workload.deletes.tolist()})
    live_count = spec["points"] - len(workload.deletes)
    # As in the binding workload, updated points may remain in an appendable
    # delta. Require the built base to remain indexed; don't force a different
    # all-points compaction just to make an approximate info counter equal N.
    return wait_index(client, live_count, directory, "final", live_count - len(workload.update_ids))


def run_matrix(args):
    build = json.loads(args.qdrant_build.read_text())
    if build["exit"] != 0 or build["commit"] != QDRANT_COMMIT or file_sha256(args.qdrant_binary) != build["binary_sha256"]:
        raise ValueError("pinned Qdrant build identity mismatch")
    args.output.mkdir(parents=True, exist_ok=False)
    report = {"qdrant_build": build, "akasha_commit": subprocess.check_output(["rtk", "proxy", "git", "rev-parse", "HEAD"], text=True).strip(),
              "akasha_binary_sha256": file_sha256(ROOT / "python/akashadb/_kernel.so"),
              "harness_sha256": {name: file_sha256(ROOT / "benchmarks" / name) for name in
                                 ["qdrant_http.py", "qdrant_http_matrix.py", "qdrant_compare.py", "qdrant_workload.py"]},
              "versions": {name: importlib.metadata.version(name) for name in ["httpx", "uvicorn", "fastapi", "uvloop", "httptools"]},
              "platform": platform.platform(), "scope": "resident HTTP, closed-loop clients 1/2/4; three trials, fixed selected efs",
              "trials": [], "status": "INCOMPLETE"}

    def save():
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    save()
    try:
        for ci, corpus in enumerate(CORPORA):
            source = args.workload_root / ("cost-plan-" + corpus)
            spec = json.loads((source / "spec.json").read_text())
            workload = load_workload(source / "workload.npz")
            for trial in range(3):
                row = {"corpus": corpus, "trial": trial, "engines": {}}
                report["trials"].append(row)
                for engine in (("akasha", "qdrant") if trial % 2 == 0 else ("qdrant", "akasha")):
                    directory = args.output / f"{corpus}-{trial}-{engine}"
                    directory.mkdir()
                    port = free_port()
                    env = dict(os.environ, PYTHONPATH=f"{ROOT}/python:{ROOT}",
                               OPENBLAS_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")
                    if engine == "akasha":
                        shutil.copytree(source / f"trial-{trial}-akasha/database", directory / "storage/benchmark")
                        env["AKASHA_DATA_DIR"] = str(directory / "storage")
                        command = [sys.executable, "-m", "uvicorn", "apps.server.main:app", "--host", "127.0.0.1", "--port", str(port),
                                   "--workers", "1", "--loop", "uvloop", "--http", "httptools", "--no-access-log"]
                        health = "/health"
                    else:
                        config = {"log_level": "WARN", "telemetry_disabled": True,
                                  "service": {"host": "127.0.0.1", "http_port": port, "grpc_port": None, "max_workers": 1},
                                  "cluster": {"enabled": False},
                                  "storage": {"storage_path": str(directory / "storage"), "snapshots_path": str(directory / "snapshots"),
                                              "performance": {"max_search_threads": 1, "optimizer_cpu_budget": 1}}}
                        # JSON is a YAML subset; this pinned config crate enables YAML only.
                        config_path = directory / "config.yaml"
                        config_path.write_text(json.dumps(config, indent=2) + "\n")
                        command = [str(args.qdrant_binary), "--config-path", str(config_path), "--disable-telemetry"]
                        health = "/healthz"
                    (directory / "command.json").write_text(json.dumps(command, indent=2) + "\n")
                    with server(command, directory, env, port, health,
                                cwd=ROOT if engine == "akasha" else directory) as url:
                        with httpx.Client(base_url=url, timeout=120, trust_env=False) as client:
                            if engine == "akasha":
                                info = api(client, "POST", "/collections/benchmark", akasha_config(spec))
                            else:
                                version = api(client, "GET", "/")
                                (directory / "version.json").write_text(json.dumps(version, indent=2) + "\n")
                                if version.get("commit") != QDRANT_COMMIT:
                                    raise ValueError("HTTP server reports a different commit")
                                info = seed_qdrant(client, workload, spec, directory)
                            (directory / "ready.json").write_text(json.dumps(info, indent=2) + "\n")
                        engine_report = asyncio.run(measure(SimpleNamespace(
                            engine=engine, url=url, collection="benchmark", workload=source,
                            efs=",".join(map(str, EFS[engine][ci])), concurrency="1,2,4", trial=trial,
                            output=directory / "measurement.json")))
                    row["engines"][engine] = {"path": str(directory / "measurement.json"), "preflight_valid": engine_report["preflight_valid"]}
                    save()
                    print(corpus, trial, engine, "measurement completed", flush=True)
                a, q = [json.loads(Path(row["engines"][e]["path"]).read_text()) for e in ("akasha", "qdrant")]
                row["cells"] = matched_http_summary(a, q)
                # The raw engine reports own all samples; avoid duplication here.
                for cell in row["cells"]:
                    for engine in ("akasha", "qdrant"):
                        if engine in cell:
                            cell[engine] = {k: v for k, v in cell[engine].items() if k not in ("warmup", "raw_samples")}
                save()
        cells = [c for t in report["trials"] for c in t["cells"]]
        report["quality_passed"] = sum(c["quality_status"] == "PASSED" for c in cells)
        report["parity_passed"] = sum(c["status"] == "PASSED" for c in cells)
        report["status"] = "PASSED" if len(cells) == 108 and report["parity_passed"] == 108 else "FAILED"
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
        save()
        raise
    save()
    return 0 if report["status"] == "PASSED" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qdrant-binary", type=Path, required=True)
    parser.add_argument("--qdrant-build", type=Path, required=True)
    parser.add_argument("--workload-root", type=Path, default=ROOT / ".build/qdrant-compare")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for key in ("qdrant_binary", "qdrant_build", "workload_root", "output"):
        setattr(args, key, getattr(args, key).resolve())
    return run_matrix(args)


if __name__ == "__main__":
    raise SystemExit(main())
