"""Paired, isolated-process lookup measurements; build both binaries first."""

import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


def run(binary, mode, count, iterations):
    with tempfile.TemporaryFile(mode="w+") as output:
        process = subprocess.Popen(
            [str(binary), mode, str(count), str(iterations)],
            stdout=output, stderr=subprocess.STDOUT,
        )
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
        output.seek(0)
        line = output.read().strip()
        if process.returncode:
            raise RuntimeError(line)
    result = {key: float(value) for key, value in (token.split("=") for token in line.split())}
    result["peak_rss_bytes"] = usage.ru_maxrss * (1 if platform.system() == "Darwin" else 1024)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--mode", choices=["sparse", "fusion"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--trials", type=int, default=5)
    args = parser.parse_args()
    cells = []
    for count in [512, 2048, 8192]:
        rows = {"before": [], "after": []}
        for trial in range(args.trials):
            for label in (["before", "after"] if trial % 2 == 0 else ["after", "before"]):
                rows[label].append(run(getattr(args, label).resolve(), args.mode, count, 20))
        if len({r["checksum"] for group in rows.values() for r in group}) != 1:
            raise AssertionError("before/after output mismatch")
        cell = {"count": count, "iterations": 20, "runs": rows,
                "median": {label: {key: statistics.median(r[key] for r in group)
                                   for key in group[0]} for label, group in rows.items()}}
        cells.append(cell)
        print(json.dumps({"count": count, "median": cell["median"]}), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"mode": args.mode, "platform": platform.platform(),
                                     "peak_rss_scope": "whole child, including build/mutation/clone; no compiler",
                                     "cells": cells}, indent=2) + "\n")


if __name__ == "__main__":
    main()
