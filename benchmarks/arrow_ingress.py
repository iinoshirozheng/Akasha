"""Measure Arrow ingress or direct result columns with scoped allocation counters."""

import argparse
import gc
import json
from pathlib import Path
import platform
import statistics
import tempfile
from time import perf_counter_ns
import tracemalloc
from unittest.mock import patch
import weakref

import numpy as np
import pyarrow as pa
from akashadb import Collection, SearchRequest
from akashadb.arrow import (
    ArrowBatchLease,
    _validated_descriptor,
    results_to_record_batch,
    search_record_batch,
    upsert_record_batch,
)


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


def result_trial(collection, request, direct, trace=False):
    gc.collect()
    if trace:
        tracemalloc.start()
    arrow_before = pa.total_allocated_bytes()
    start = perf_counter_ns()
    if direct:
        result = search_record_batch(collection, request)
    else:
        result = results_to_record_batch(collection.search(request))
    elapsed = perf_counter_ns() - start
    python_peak = tracemalloc.get_traced_memory()[1] if trace else None
    if trace:
        tracemalloc.stop()
    allocation_delta = pa.total_allocated_bytes() - arrow_before
    assert result.num_rows == request.k
    assert result.schema == pa.schema([("id", pa.int64()), ("score", pa.float32())])
    return result, {
        "query_and_export_ns": elapsed,
        "python_traced_peak_bytes": python_peak,
        "arrow_allocated_delta_bytes": allocation_delta,
        "result_column_bytes": result.nbytes,
    }


def result_ownership_probe(collection, request):
    arrays = []
    empty = np.empty

    def capture_empty(*args, **kwargs):
        array = empty(*args, **kwargs)
        arrays.append(array)
        return array

    with patch.object(np, "empty", capture_empty):
        result = search_record_batch(collection, request)
    assert len(arrays) == 2
    assert [array.dtype for array in arrays] == [np.dtype("int64"), np.dtype("float32")]
    pointers_match = [
        result.column(index).buffers()[1].address == array.ctypes.data
        for index, array in enumerate(arrays)
    ]
    assert all(pointers_match)
    output_bytes = sum(array.nbytes for array in arrays)
    assert output_bytes == 12 * result.num_rows
    owners = [weakref.ref(array) for array in arrays]
    arrays.clear()
    sliced = result.slice(1)
    del result
    gc.collect()
    assert all(owner() is not None for owner in owners)
    del sliced
    gc.collect()
    assert all(owner() is None for owner in owners)
    return {
        "native_output_buffer_allocations": len(owners),
        "native_output_buffer_bytes": output_bytes,
        "arrow_pointer_identity": pointers_match,
        "last_slice_released_numpy_owners": True,
    }


def result_cells():
    cells = []
    dimension = 16
    rows = 4096
    with tempfile.TemporaryDirectory(prefix="akasha-arrow-results-") as directory:
        collection = Collection(directory, dimension)
        upsert_record_batch(collection, batch(rows, dimension, 0, 0))
        for k in [32, 1024, rows]:
            request = SearchRequest("dot", k, vector=[1.0] * dimension)
            expected, _ = result_trial(collection, request, False)
            actual, _ = result_trial(collection, request, True)
            assert actual.equals(expected)
            cell = {"points": rows, "dimension": dimension, "k": k}
            for name, direct in [("python_rows", False), ("direct_columns", True)]:
                runs = []
                for _ in range(9):
                    result, measurement = result_trial(collection, request, direct)
                    assert result.equals(expected)
                    runs.append(measurement)
                result, allocation = result_trial(collection, request, direct, trace=True)
                assert result.equals(expected)
                cell[name] = {
                    "runs": runs,
                    "median_ns": statistics.median(run["query_and_export_ns"] for run in runs),
                    "allocation_probe": allocation,
                }
            cell["native_columnization_bytes"] = 12 * k
            cell["ownership_probe"] = result_ownership_probe(collection, request)
            cell["copy_scope"] = (
                "Native AoS to NumPy I64/F32 columns: one pass, 12 bytes/result. "
                "Arrow reuses those buffers. Counts exclude native query allocations, "
                "input conversion and Python wrapper objects; tracemalloc excludes Mojo memory."
            )
            cells.append(cell)
            print(json.dumps({
                "k": k,
                "python_rows_ns": cell["python_rows"]["median_ns"],
                "direct_columns_ns": cell["direct_columns"]["median_ns"],
            }), flush=True)
        collection.close()
    return cells


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--mode", choices=["ingress", "results"], default="ingress")
    args = parser.parse_args()
    if args.mode == "results":
        cells = result_cells()
    else:
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
    args.output.write_text(json.dumps({"label": args.label, "mode": args.mode, "platform": platform.platform(),
                                     "pyarrow": pa.__version__, "numpy": np.__version__, "cells": cells}, indent=2) + "\n")


if __name__ == "__main__":
    main()
