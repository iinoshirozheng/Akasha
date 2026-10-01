"""Per-process bounded scanner measurements, including real peak RSS.

Run under `pixi run env PYTHONPATH=python:. python benchmarks/arrow_scanner.py`.
RSS is the process high-water mark, not an allocation counter. Setup can establish
a higher peak than scanning; retain both values instead of implying zero memory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import resource
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path
from time import perf_counter_ns

ROOT = Path(__file__).resolve().parents[1]


def source_hash() -> str:
    digest = hashlib.sha256()
    paths = subprocess.check_output(
        ["rg", "--files", "src", "tests", "native", "include", "python"], cwd=ROOT, text=True
    ).splitlines()
    for name in sorted(paths):
        digest.update(name.encode() + b"\0" + (ROOT / name).read_bytes() + b"\0")
    return digest.hexdigest()


def peak_rss() -> int:
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(value if sys.platform == "darwin" else value * 1024)


def measure(rows: int, dimension: int, batch_size: int) -> dict:
    import numpy as np
    import pyarrow as pa
    import akashadb

    ids = np.arange(rows, dtype=np.int64)
    vectors = (np.arange(rows * dimension, dtype=np.float32) % 101).reshape(rows, dimension)
    data_checksum = hashlib.sha256(ids.tobytes() + vectors.tobytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="akasha-scan-bench-") as directory:
        collection = akashadb.Collection(directory, dimension)
        for offset in range(0, rows, 1024):
            values = vectors[offset:offset + 1024].reshape(-1)
            batch = pa.record_batch([
                pa.array(ids[offset:offset + 1024]),
                pa.FixedSizeListArray.from_arrays(pa.array(values), dimension),
            ], names=["id", "vector"])
            akashadb.upsert_record_batch(collection, batch)
        # Establish the shared immutable root and import costs before measuring.
        with akashadb.scan_record_batches(collection, columns=("id", "vector")) as warm:
            for batch in warm:
                batch.validate(full=True)
        before = peak_rss()
        timings = []
        stats = None
        max_batch_owned = 0
        for _ in range(5):
            started = perf_counter_ns()
            checksum = 0
            with akashadb.scan_record_batches(collection, batch_size=batch_size,
                                             columns=("id", "vector")) as scanner:
                previous_owned = 0
                for batch in scanner:
                    checksum += int(batch.column("id").to_numpy(zero_copy_only=True).sum())
                    current = scanner.stats["materialized_bytes"]
                    max_batch_owned = max(max_batch_owned, current - previous_owned)
                    previous_owned = current
                stats = scanner.stats
            timings.append(perf_counter_ns() - started)
            assert checksum == rows * (rows - 1) // 2
            assert stats["rows"] == rows
        after = peak_rss()
        collection.close()
    return dict(rows=rows, dimension=dimension, batch_size=batch_size,
                data_sha256=data_checksum, elapsed_ns=timings,
                median_ns=statistics.median(timings), stats=stats,
                max_batch_materialized_bytes=max_batch_owned,
                setup_peak_rss_bytes=before, final_peak_rss_bytes=after,
                peak_increase_bytes=max(0, after - before),
                numpy=np.__version__, pyarrow=pa.__version__)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=4096)
    parser.add_argument("--dimension", type=int, default=128)
    parser.add_argument("--batch-size", type=int)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.batch_size is not None:
        print(json.dumps(measure(args.rows, args.dimension, args.batch_size)))
        return
    cells = []
    for size in (1, 128, 1024, 4096):
        result = subprocess.run([
            sys.executable, str(Path(__file__).resolve()), "--rows", str(args.rows),
            "--dimension", str(args.dimension), "--batch-size", str(size),
        ], check=True, text=True, stdout=subprocess.PIPE)
        cells.append(json.loads(result.stdout))
    output = dict(source_sha256=source_hash(), benchmark_sha256=hashlib.sha256(
        Path(__file__).read_bytes()).hexdigest(), platform=platform.platform(),
        mojo=subprocess.check_output(["mojo", "--version"], text=True).strip(),
        python=sys.version, cells=cells)
    text = json.dumps(output, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    print(text)


if __name__ == "__main__":
    main()
