"""Measure synchronous Arrow ingress and explicitly scoped allocation counters."""

import argparse
import gc
import json
from pathlib import Path
import platform
import statistics
import tempfile
from time import perf_counter_ns
import tracemalloc

import numpy as np
import pyarrow as pa
from akashadb import Collection
from akashadb.arrow import ArrowBatchLease, _validated_descriptor


def batch(rows, dimension, payload_bytes, sparse_size):
    values = np.arange(rows * dimension, dtype=np.float32) % 101
    columns = [pa.array(np.arange(rows, dtype=np.int64)),
               pa.FixedSizeListArray.from_arrays(pa.array(values), dimension)]
    names = ["id", "vector"]
    if sparse_size:
        offsets = pa.array(np.arange(rows + 1, dtype=np.int32) * sparse_size)
        columns += [pa.ListArray.from_arrays(offsets, pa.array(np.tile(np.arange(sparse_size, dtype=np.int64), rows))),
                    pa.ListArray.from_arrays(offsets, pa.array(np.ones(rows * sparse_size, dtype=np.float32)))]
        names += ["sparse_term_ids", "sparse_weights"]
    if payload_bytes:
        columns.append(pa.array(["x" * payload_bytes] * rows))
        names.append("payload.text")
    return pa.record_batch(columns, names=names)


def trial(source, dimension, trace=False):
    with tempfile.TemporaryDirectory(prefix="akasha-arrow-bench-") as directory:
        collection = Collection(directory, dimension)
        gc.collect()
        if trace:
            tracemalloc.start()
        arrow_before = pa.total_allocated_bytes()
        start = perf_counter_ns()
        lease = ArrowBatchLease.from_producer(source)
        descriptor = _validated_descriptor(collection, lease.batch)
        prepared = perf_counter_ns()
        arrow_after_prepare = pa.total_allocated_bytes()
        assert collection._call("apply_arrow_batch", descriptor) == source.num_rows
        accepted = perf_counter_ns()
        lease.release()
        elapsed = perf_counter_ns() - start
        python_peak = tracemalloc.get_traced_memory()[1] if trace else None
        if trace:
            tracemalloc.stop()
        # Physical WAL output is measured separately from in-memory copies.
        wal_bytes = sum(path.stat().st_size for path in Path(directory).glob("*.wal"))
        wal_bytes += (Path(directory) / "wal.bin").stat().st_size
        assert collection.get(source.num_rows - 1).vector[0] == float(((source.num_rows - 1) * dimension) % 101)
        collection.close()
        return {"prepare_ns": prepared - start, "kernel_ns": accepted - prepared,
                "ingress_ns": elapsed, "python_traced_peak_bytes": python_peak,
                "arrow_prepare_allocated_delta_bytes": arrow_after_prepare - arrow_before,
                "wal_file_bytes": wal_bytes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    cells = []
    for dimension, payload, sparse in [(256, 0, 0), (256, 64, 4)]:
        rows = 512
        source = batch(rows, dimension, payload, sparse)
        trial(source, dimension)  # warm runtime/imports outside timed samples
        runs = [trial(source, dimension) for _ in range(5)]
        allocation = trial(source, dimension, trace=True)  # do not contaminate timing
        cells.append({"rows": rows, "dimension": dimension, "payload_bytes_per_row": payload,
                      "sparse_elements_per_row": sparse, "runs": runs, "allocation_probe": allocation,
                      "median": {key: statistics.median(r[key] for r in runs)
                                 for key in ["prepare_ns", "kernel_ns", "ingress_ns"]}})
        print(json.dumps(cells[-1]["median"]), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"label": args.label, "platform": platform.platform(),
                                     "pyarrow": pa.__version__, "numpy": np.__version__, "cells": cells}, indent=2) + "\n")


if __name__ == "__main__":
    main()
