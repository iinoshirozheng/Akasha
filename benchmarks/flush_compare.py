"""Compare two compiled engines on identical incremental-flush fixtures."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def run(binary: Path, fixture: Path, args: argparse.Namespace, log: Path) -> dict:
    with log.open("w") as stream:
        process = subprocess.Popen(
            [str(binary), "flush", str(fixture), str(args.points),
             str(args.dimension), str(args.delta), str(args.payload_bytes), "off"],
            stdout=stream, stderr=subprocess.STDOUT,
        )
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
    if process.returncode:
        raise RuntimeError(log.read_text())
    line, = (line for line in log.read_text().splitlines() if line.startswith("flush "))
    row = {key: int(value) for key, value in
           (item.split("=") for item in line.split()[1:])}
    row["peak_rss_bytes"] = int(usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024))
    # Compare every durable .bin file, including dense/sparse segments, config,
    # manifest and index sidecars; collection.lock and temporary files excluded.
    row["durable_sha256"] = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(fixture.glob("*.bin"))
    }
    return row


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--points", type=int, default=8192)
    parser.add_argument("--dimension", type=int, default=64)
    parser.add_argument("--delta", type=int, default=16)
    parser.add_argument("--payload-bytes", type=int, default=4096)
    parser.add_argument("--trials", type=int, default=7)
    args = parser.parse_args()
    if min(args.points, args.dimension, args.delta, args.trials) <= 0 or args.payload_bytes < 0 or args.delta > args.points:
        parser.error("invalid workload size")
    binaries = {name: getattr(args, name).resolve() for name in ("before", "after")}
    args.output.mkdir(parents=True, exist_ok=True)
    report = {
        "binaries": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                     for name, path in binaries.items()},
        "rss_scope": "whole open/update/flush/close child; excludes fixture construction and compiler",
        "latency_scope": "public collection.flush only; includes index/cache publication and fsync",
        "trials": [],
    }
    with tempfile.TemporaryDirectory(prefix="akasha-flush-") as directory:
        root = Path(directory)
        fixture = root / "prepared"
        subprocess.run(
            [str(binaries["before"]), "prepare", str(fixture), str(args.points),
             str(args.dimension), str(args.delta), str(args.payload_bytes), "off"],
            check=True,
        )
        for trial in range(args.trials):
            pair = {}
            for name in (("before", "after") if trial % 2 == 0 else ("after", "before")):
                candidate = root / f"{name}-{trial}"
                shutil.copytree(fixture, candidate)
                pair[name] = run(binaries[name], candidate, args, args.output / f"{name}-{trial}.log")
                shutil.rmtree(candidate)
            if pair["before"]["durable_sha256"] != pair["after"]["durable_sha256"]:
                raise RuntimeError("before/after durable files differ")
            report["trials"].append(pair)
            (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"pair {trial + 1}: before_ns={pair['before']['flush_ns']} after_ns={pair['after']['flush_ns']} bytes_identical=true", flush=True)


if __name__ == "__main__":
    main()
