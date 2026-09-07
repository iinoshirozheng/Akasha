"""Reproducible production HNSW workload runner; timings are diagnostic."""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import json
import hashlib
import math
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
METRICS = {"dot": 0, "l2": 1, "cosine": 2}
SCALARS = {"f32": 0, "bf16": 1, "f16": 2, "i8": 3}


def parse_rows(output: str) -> list[dict]:
    rows = []
    for line in output.splitlines():
        if not line.startswith(("build ", "query ", "quality ")):
            continue
        kind, *fields = line.split()
        rows.append({"kind": kind, **dict(field.split("=", 1) for field in fields)})
    return rows


def nearest_rank(values: list[int], percentile: float) -> int:
    return sorted(values)[max(0, math.ceil(len(values) * percentile) - 1)]


def run_cell(binary: Path, output: Path, spec: dict) -> dict:
    with tempfile.TemporaryDirectory(prefix="akasha-quality-") as directory:
        command = [str(binary), directory, *map(str, [spec[k] for k in (
            "points", "dimension", "queries", "seed", "metric_tag", "scalar_tag",
            "base_percent", "update_percent", "ef", "clustered", "min_recall",
        )])]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    output.with_suffix(".log").write_text(result.stdout + result.stderr)
    rows = parse_rows(result.stdout)
    summaries = []
    for row in rows:
        if row["kind"] != "quality":
            continue
        samples = [r for r in rows if r["kind"] == "query" and r["mode"] == row["mode"]]
        if len(samples) != spec["queries"]:
            raise RuntimeError("quality result omitted query samples")
        summary = {**spec, **row}
        for label in ("exact_ns", "collection_ann_ns"):
            values = [int(s[label]) for s in samples]
            summary[f"{label}_p50"] = nearest_rank(values, .50)
            summary[f"{label}_p95"] = nearest_rank(values, .95)
        summaries.append(summary)
    report = {"spec": spec, "argv": command, "returncode": result.returncode,
              "rows": rows, "summaries": summaries}
    output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
    if result.returncode:
        raise RuntimeError(f"workload failed; see {output.with_suffix('.log')}")
    if len(summaries) != 4:
        raise RuntimeError("workload omitted a filter mode")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=["smoke", "representative", "full", "scaling", "cell"], default="representative")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/post-hnsw/quality-results")
    parser.add_argument("--points", type=int, default=8192)
    parser.add_argument("--dimension", type=int, default=384)
    parser.add_argument("--queries", type=int, default=64)
    parser.add_argument("--seed", type=int, default=12345)
    parser.add_argument("--metric", choices=METRICS, default="dot")
    parser.add_argument("--scalar", choices=SCALARS, default="f32")
    parser.add_argument("--base-percent", type=int, default=75)
    parser.add_argument("--update-percent", type=int, default=10)
    parser.add_argument("--ef", type=int, default=128)
    parser.add_argument("--min-recall", type=float, default=0.0,
                        help="Explicit optional large-workload gate; existing locked CI gates are unchanged")
    parser.add_argument("--uniform", action="store_true")
    args = parser.parse_args()
    if args.queries < 1 or args.points < 128 or args.dimension < 1 or args.ef < 10:
        parser.error("require points >= 128, dimension/queries > 0, ef >= 10")
    if not 0 <= args.min_recall <= 1:
        parser.error("min-recall must be in [0, 1]")
    args.output.mkdir(parents=True, exist_ok=True)
    binary = args.output.resolve() / "quality"
    subprocess.run(["pixi", "run", "mojo", "build", "-I", "src", "-I", "benchmarks/mojo",
                    "benchmarks/mojo/post_hnsw_quality.mojo", "-o", str(binary)], cwd=ROOT, check=True)
    manifest = {"started_utc": datetime.now(timezone.utc).isoformat(), "host": platform.platform(),
                "machine": platform.machine(), "profile": args.profile,
                "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "git_diff": subprocess.check_output(["git", "diff"], cwd=ROOT, text=True),
                "mojo": subprocess.check_output(["pixi", "run", "mojo", "--version"], cwd=ROOT, text=True).strip(),
                "lockfile_sha256": hashlib.sha256((ROOT / "pixi.lock").read_bytes()).hexdigest(),
                "benchmark_sha256": hashlib.sha256((ROOT / "benchmarks/mojo/post_hnsw_quality.mojo").read_bytes()).hexdigest(), "warmup_queries_per_mode": 3,
                "timing_scope": "public collection query including validation/filter/planner/traversal/F32 rerank; excludes Python/HTTP, snapshot capture, ingestion and candidate diagnostics"}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    base = dict(points=args.points, dimension=args.dimension, queries=args.queries,
                seed=args.seed, metric_tag=METRICS[args.metric], scalar_tag=SCALARS[args.scalar],
                base_percent=args.base_percent, update_percent=args.update_percent, ef=args.ef,
                clustered=int(not args.uniform), min_recall=args.min_recall)
    pairs = [(m, s) for m in METRICS for s in SCALARS if not (m == "l2" and s == "i8")]
    if args.profile == "cell":
        cells = [base]
    elif args.profile == "scaling":
        cells = [{**base, "points": n, "dimension": 64, "metric_tag": 1, "scalar_tag": 0}
                 for n in [4096, 16384, 65536]]
    elif args.profile == "smoke":
        cells = [{**base, "points": 512, "dimension": 32, "queries": 12,
                  "metric_tag": METRICS[m], "scalar_tag": SCALARS[s]} for m, s in pairs]
    elif args.profile == "representative":
        cells = [{**base, "dimension": [384, 768, 1536][i % 3], "seed": seed,
                  "clustered": i % 2, "base_percent": [25, 75, 100][i % 3],
                  "metric_tag": METRICS[m], "scalar_tag": SCALARS[s]}
                 for seed in [12345, 67890] for i, (m, s) in enumerate(pairs)]
    else:
        cells = [{**base, "dimension": dimension, "seed": seed,
                  "clustered": clustered, "base_percent": ratio,
                  "metric_tag": METRICS[m], "scalar_tag": SCALARS[s]}
                 for dimension in [384, 768, 1536] for seed in [12345, 67890]
                 for clustered in [0, 1] for ratio in [25, 75, 100] for m, s in pairs]
    summaries = []
    for index, cell in enumerate(cells):
        print(f"[{index + 1}/{len(cells)}] {cell}", flush=True)
        report = run_cell(binary, args.output / f"cell-{index:03d}", cell)
        summaries.extend(report["summaries"])
        with (args.output / "summary.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(summaries[0]))
            writer.writeheader()
            writer.writerows(summaries)
        print("  " + ", ".join(f"{r['mode']}: recall={r['final_recall']} fallback={r['fallback_rate']}" for r in report["summaries"]), flush=True)


if __name__ == "__main__":
    main()
