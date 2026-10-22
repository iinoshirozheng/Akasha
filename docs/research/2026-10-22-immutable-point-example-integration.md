# Retained candidate examples, integration and benchmark consumers

The unchanged deferred-ID candidate passes all three runnable Mojo examples,
the ten existing local multiprocess integration tests and both existing CI
smoke-quality commands. This closes those local validation gaps. Its latest
strict Qdrant mixed acceptance remains **21/36**; no performance result or
native Linux gate is changed by this work.

The audit also finds and fixes two missed candidate benchmark call sites and
a separate repository diagnostic bug. `hnsw_query_stages.mojo` used the legacy
60-byte configuration decoder on the current 144-byte field catalog. It now
uses `load_field_catalog` and the default field's HNSW configuration, matching
`PersistentCollection.open_with_config`. Existing catalog validation and v1
support remain in that established reader. No durable bytes or engine behavior
change. This loader correction is applied to the repository benchmark.

## Validation and scope

| Check | Result |
| --- | --- |
| `smoke`, `persistent_collection`, `configured_hnsw` | 3 built and run against retained source |
| `tests/distributed` | 10 passed; 26 Python processes verify retained native identity |
| `hnsw_quality --smoke` | 6 datasets; observed recall 1.0 throughout |
| `post_hnsw.py --profile smoke --min-recall 0.95` | 11 metric/scalar cells × 4 modes; 528 measured queries, final recall 1.0 throughout |
| Query-stage CLI after catalog correction | 12 private/public ID and score comparisons per implementation, retained and production |

The post-HNSW ANN modes have zero fallback; its eleven selective modes use the
expected exact fallback. Dataset size, dimensions, seeds, ef, oracle and recall
threshold are unchanged. The original HNSW smoke program prints recall but
does **not** enforce a recall threshold itself; its observed result must not be
confused with an asserted gate. Neither timing output replaces frozen Qdrant
acceptance.

The retained MemTable is held by an `ArcPointer`. The isolated copies of
`post_hnsw_quality.mojo` and `hnsw_query_stages.mojo` now dereference that owner
when passing the table to existing helpers. `candidate-benchmarks.patch` records
both one-line changes relative to current repository benchmark sources. They
are candidate adoption changes, not changes to the repository's current
plain-MemTable engine. The driver only redirects source/include paths.

The configured example exercises BF16/cosine, metric mismatch, flush and
reopen. Its small pre-flush search uses the expected delta-scan path. Only the
two example database path literals change to fresh evidence directories.
The diagnostic runs on a copy of the resulting database with three fixed F32
queries, four passes each. Production receives its own database created by the
same example compiled against production source. The repeated diagnostic
queries are not independent performance samples.

`tests/integration` contains only a README, and the three Python examples are
placeholders. No passing tests are invented for those locations. The existing
distributed tests cover local replication, failover, recovery and snapshot
failure paths; they do not establish Qdrant distributed-API or Raft parity.

## Preserved failures

- The first examples driver expected an incorrect backend name after all six
  build/run actions had succeeded. It was corrected to check the actual backend
  contract; source, command and log hashes allowed reuse of those completions.
- The initial post-HNSW build failed when passing the MemTable owner directly.
  Its failure log and original driver remain in `quality/initial`.
- The first compiled query-stage helper failed with `collection config length
  mismatch`. Its source, identity and log remain in `quality/initial-query-stages`.
  Only that helper was rebuilt after the loader correction; completed quality
  workloads were not rerun.

## Reproduction and evidence

The [text evidence archive](2026-10-22-immutable-point-example-integration.json.gz)
contains the validation drivers, original/copied benchmark sources, logs,
per-query quality rows, command identities and initial failures. The retained
132 engine files and Python native are checked against the
[deferred-ID source archive](2026-10-20-immutable-point-deferred-id.md).
The native SHA-256 remains
`64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`.
Production `src` remains unchanged from `a6822c3`.

Fresh execution used `rtk proxy pixi run python` with `validate.py`,
`check_quality.py` and `validate_query_stages.py` under
`.build/qdrant-alignment/immutable-point-example-integration`. Drivers preserve
explicit source paths and failure history; use a fresh evidence root for a
new run. Extracted `verify_evidence.py` independently recomputes command/log
checks, all quality summaries and percentile timings. Archive-only replay
matches exactly and verifies every artifact hash.

Verified archive: **165 artifacts, 153,329 bytes**, SHA-256
`005fc5892ea48547182a920ab8f59f1e7bed1c4748e5ad180eb35c9fc421c2e1`.

The next adoption check is complete Mojo consumer coverage: the earlier
262-case validation was a relevant subset, not all 166 repository Mojo test
modules. The missed benchmark callers demonstrate why that distinction matters.
M5/M6 remain incomplete, including the twelve speed failures, three Qdrant
quality failures, sustained nonresident capacity and native Linux validation.
