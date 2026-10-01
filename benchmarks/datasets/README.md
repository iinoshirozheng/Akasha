# Benchmark datasets

Large generated or downloaded datasets must not be committed. The #59 runner
stores inputs and databases under `.build/qdrant-compare/`.

## Shared comparison inputs

`benchmarks/qdrant_workload.py` generates the uniform synthetic 128D/1536D inputs
with the existing Mojo `post_hnsw_quality` SplitMix64 stream and Float32 rounding.
IDs are shuffled before generating vectors; the first 10% are replaced, then
every twentieth ID in the second half is deleted. The four filter modes are
all, two roughly 25% buckets, and a roughly 1/32 selective bucket. On uniform
and real data the historical `correlated` label is just an ID bucket, not a
claim of correlation with the embedding geometry.

Real data is the public Qdrant
[DBpedia / text-embedding-3-large 1536D dataset](https://huggingface.co/datasets/Qdrant/dbpedia-entities-openai3-text-embedding-3-large-1536-100K),
revision `e8931e5eeba5b31bb9481f98687cf0ced14c2442`. The first Parquet shard is
318,404,753 bytes; SHA-256:
`793fa64beb2d89added80b2a4640719e6a26216f31122d222f7b37ee2dbc24cb`.
The runner checks the entire source file before reading any data. It uses
disjoint contiguous source rows for initial corpus, replacement vectors, and
queries; both engines receive the same Float32 cast of the source Float64 data.
Every generated array, shape, dtype and metadata record participates in the
workload checksum. The NPZ loader rejects changed arrays.

```sh
mkdir -p .build/qdrant-compare
curl -fL 'https://huggingface.co/datasets/Qdrant/dbpedia-entities-openai3-text-embedding-3-large-1536-100K/resolve/e8931e5eeba5b31bb9481f98687cf0ced14c2442/data/train-00000-of-00003.parquet' -o .build/qdrant-compare/dbpedia-1536.parquet
```

## Native Qdrant dependency

Use the official `qdrant-edge-py==0.8.0` package, **not** qdrant-client's local
NumPy implementation. This is the in-process Rust engine behind the official
[Edge Python API](https://qdrant.tech/documentation/edge/edge-quickstart/).
Its [release workflow](https://github.com/qdrant/qdrant/actions/runs/31007802524)
used Qdrant commit `21db2f3ff95d50de3a2b88a741312c056fd1762d`;
the commit's `lib/edge/python/Cargo.toml` declares version 0.8.0.

The macOS ARM64 CPython abi3 wheel used here is 10,016,514 bytes, SHA-256
`d84d0702a31b6560c84f4d28b3272f94f1df354c04b80167e73acc08cc134642`.
The following installation stays inside the worktree and does not change the
project's runtime dependencies or Pixi environment:

```sh
curl -fL 'https://files.pythonhosted.org/packages/4f/d6/9b52178490526866aeff57bec2aa28972a85fc532da20d79db3a82a4eaf3/qdrant_edge_py-0.8.0-cp310-abi3-macosx_11_0_arm64.whl' -o .build/qdrant-compare/qdrant_edge_py-0.8.0-cp310-abi3-macosx_11_0_arm64.whl
shasum -a 256 .build/qdrant-compare/qdrant_edge_py-0.8.0-cp310-abi3-macosx_11_0_arm64.whl
pixi run python -m venv .build/qdrant-compare/install-env
.build/qdrant-compare/install-env/bin/python -m pip install --no-index --no-deps --no-cache-dir --target .build/qdrant-compare/deps .build/qdrant-compare/qdrant_edge_py-0.8.0-cp310-abi3-macosx_11_0_arm64.whl
```

Check the printed checksum against the value above before installation. For a
different platform, choose the matching official 0.8.0 wheel from
[PyPI](https://pypi.org/project/qdrant-edge-py/0.8.0/#files), record its SHA-256,
and use the same isolated target. Do not use the ARM64 binary on another CPU.

## Run and interpret

Build the current Python binding first with `pixi run build-python`. Each output
directory must be empty. Failed cells can be repeated with the same command and
a new output directory; inputs and oracle are checksum bound. The controller
keeps raw query IDs/timings/stats and child failure artifacts, then exits nonzero
if any filter has no passing pair. A single-engine diagnostic also has no
passing *pair* and therefore exits nonzero even when its own cells pass.

```sh
pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps pytest tests/python/test_qdrant_compare.py -q
pixi run env PYTHONPATH=. mojo run -I src -I benchmarks/mojo benchmarks/mojo/qdrant_workload_parity.mojo
pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps python benchmarks/qdrant_compare.py --output .build/qdrant-compare/uniform-128 --dimension 128
pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps python benchmarks/qdrant_compare.py --output .build/qdrant-compare/uniform-1536 --dimension 1536
pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps python benchmarks/qdrant_compare.py --output .build/qdrant-compare/real-1536 --metric cosine --real-parquet .build/qdrant-compare/dbpedia-1536.parquet
```

Defaults: 8,192 points, 64 measured queries plus 3 warmups per filter/ef, k=10,
three independent builds, one query thread, M=24/M0=48, efConstruction=192,
ef=32/64/128/256/512/1024, and target mean Recall@10 >= 0.95. A Float64 NumPy
oracle operates on the final live Float32 input state, with ascending ID ties.
Both engines' exact APIs must agree with it. Result duplicates, non-live IDs and
filter violations are errors. Select the **smallest passing ef** separately for
each engine/filter; do not select whichever noisy latency sample is fastest.

Query timing starts from a Python vector list and filter/ef values, includes
native request construction and the public binding call, and ends with returned
result objects. Request construction matters because Qdrant's constructor
already marshals vectors into Rust. ID extraction, oracle checks and telemetry
are outside timing. QPS is reciprocal mean single-request service time, not
concurrent server throughput. Cold/open uses a new process after flush/close;
OS page cache is **not** evicted. Peak RSS includes Python, libraries and input
arrays; it is not an isolated index allocation measurement.

Qdrant builds payload indexes before ingest and optimizes to HNSW before updates.
Akasha uses its public flush to publish the base. Both then apply the same
replacements/deletes and flush; post-mutation base/delta planner costs remain
part of search. Qdrant's full-scan threshold is fixed to one eighth of the initial
corpus's dense bytes, expressed in KiB, matching Akasha's eligible-fraction cutoff
for these well-separated filter buckets. Its public Edge API does not expose
per-query fallback or candidate counters.
Akasha ANN-only filters reject exact fallback; the selective filter explicitly
allows it. No graph seed is exposed by Edge, so fresh trial variability matters.

Write stage timings retain each public API's semantics: Akasha fsyncs each atomic
WAL batch; Edge's `update` writes WAL and applies the operation, and its explicit
`flush` synchronizes WAL/segments. Report ingest plus build/checkpoint and updates
plus flush separately; a raw `replace_ns` ratio is not a durability-equivalent
write-throughput claim. Both complete their flush before any measured query.

This baseline does not complete the later M6 concurrent writes/maintenance,
non-resident data, HTTP, memory-limit or expanded vector-type acceptance matrix.
