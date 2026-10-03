# Default-vector borrow investigation — 2026-10-03

Both query prototypes were rejected after public latency regressions. Production
Mojo sources and the Python binary were restored to baseline `a710aa5`; the three
new default-vector lifecycle regression cases remain. **M5/M6 is not complete.**

## Investigation

Five-second `/usr/bin/sample` captures used the production binary, serial
resident queries and the frozen comparison corpora. Samples are diagnostics,
not an independent latency or recall gate. Idle runtime threads are excluded
from the following percentages; denominators are main-thread samples.

- Uniform 128D all: 684/4,210 samples (16.2%) in `field_ordinal`, 373 (8.9%)
  in `MemTableEntry.values`, 405 (9.6%) in Top-K offer, and 2,165 (51.4%) in
  the collection exact-scan function, including its inlined distance kernel.
- Real 1536D all: mapped distance 1,817/4,159 (43.7%), owned distance 544
  (13.1%), checked rerank distance 315 (7.6%). Metric norm/value validation
  accounts for 277 (6.7%) combined. This includes required checks; it is **not**
  a measurement of redundant validation alone. Per-call validation counts were
  not instrumented, and no checks were removed.
- Real selective: 2,928/4,194 samples (69.8%) in collection exact scan.

Call-path inspection found `has_dense()` followed by `values()` performing two
reserved-field lookups per scanned row. The first candidate borrowed `values()`
once and skipped the empty projection. Valid default dense vectors are nonempty;
missing fields project an empty list. The borrow stayed within the immutable
collection operation; no pointer or owner escaped. Arithmetic, validation,
planner, formats and dependencies were unchanged.

A second isolated candidate also used sorted nonnegative field IDs to resolve
reserved field zero directly at slot zero in MemTable descriptors. It added no
cache or persistent format. It did not show stable public improvement either.

Local Qdrant metric preprocessing (`74f3e85`) and USearch (`0ef97e1`) were inspected.
Existing full-row bounds and prefetch probes had already failed to demonstrate
consistent end-to-end gains; they were not repeated. The prefetch rejection is
also recorded in `results/2026-10-01-hnsw-prefetch.json`.

## Public results and rejection

All trials retain the fixed corpora, seeds, filters, K, service boundaries and
selected ef values. Each corpus has three rotating baseline/candidate/Qdrant
orders. No compilation, tests or archive compression overlapped measurement.
Slow samples remain. The common Recall@10 target is .95; the speed gate requires
both QPS ≥ Qdrant and p95 ≤ Qdrant in **each** cell.

| Experiment | Baseline strict pass | Candidate strict pass | Quality and audits |
|---|---:|---:|---|
| Single-borrow warm | 16/36 | 17/36 | 108 quality cells; 6,912 timed audits; 7,236 exact checks |
| Single-borrow mixed | 24/36 | 24/36 | 108 quality cells; 7,776 timed audits; 27 reopen checks; 18 Akasha leases |
| Direct-slot warm | 19/36 | 18/36 | 108 quality cells; 6,912 timed audits; 7,236 exact checks |

Each row is a separate experiment, not a combined acceptance run. Warm
baseline/candidate IDs, Float32 score bits, stats and warmups match. Mixed IDs
and score bits match in all nine triples; every worker passes its evolving-state
oracle audit and final reopen check. Both Akasha variants preserve their Arrow
lease across close. These correctness results do not imply speed acceptance.

Single-borrow warm ratios below are candidate/baseline for trials 0 / 1 / 2.
QPS higher is better; p95 lower is better. The final columns count candidate
trials meeting both Qdrant speed conditions.

| Corpus | Filter | QPS ratios | p95 ratios | Warm | Mixed |
|---|---|---|---|---:|---:|
| uniform-128 | all | 1.044 / 1.024 / 1.171 | 1.015 / 1.077 / 0.775 | 1/3 | 3/3 |
| uniform-128 | correlated | 0.954 / 0.472 / 0.615 | 1.098 / 2.219 / 1.987 | 2/3 | 3/3 |
| uniform-128 | independent | 1.189 / 0.675 / 1.234 | 0.998 / 1.288 / 0.677 | 3/3 | 3/3 |
| uniform-128 | selective | 0.979 / 0.873 / 1.094 | 0.928 / 1.205 / 0.882 | 2/3 | 1/3 |
| uniform-1536 | all | 0.974 / 1.099 / 0.990 | 1.092 / 0.846 / 1.010 | 3/3 | 3/3 |
| uniform-1536 | correlated | 0.931 / 0.999 / 1.031 | 0.976 / 0.993 / 0.963 | 3/3 | 3/3 |
| uniform-1536 | independent | 0.955 / 0.989 / 1.024 | 1.025 / 1.021 / 0.964 | 3/3 | 3/3 |
| uniform-1536 | selective | 1.134 / 0.973 / 1.065 | 0.862 / 1.144 / 0.831 | 0/3 | 1/3 |
| real-1536 | all | 1.089 / 0.941 / 1.019 | 0.882 / 1.097 / 0.975 | 0/3 | 1/3 |
| real-1536 | correlated | 0.971 / 0.971 / 0.971 | 1.038 / 1.021 / 1.045 | 0/3 | 1/3 |
| real-1536 | independent | 0.793 / 0.984 / 1.030 | 1.223 / 1.010 / 0.993 | 0/3 | 0/3 |
| real-1536 | selective | 0.844 / 1.162 / 1.005 | 1.248 / 0.774 / 1.030 | 0/3 | 2/3 |

Uniform-128 all QPS improved in all three warm trials, but its p95 regressed in
two. Uniform-128 correlated, an affected **planned exact** path, had p95 ratios
2.219 and 1.987. Real correlated ANN QPS also regressed in all three warm trials;
its traversal source did not change, so the experiment does not establish the
cause of that regression. Neither change is retained on the strength of a
median or another cell's improvement.

Single-borrow warm has one pass→fail cell (uniform-128 correlated, trial 2);
mixed has one (real all, trial 1). Direct-slot warm has one (uniform-128
independent, trial 0). Aggregate counts cannot offset these failures. Different
baseline counts across experiments also show why cross-run counts alone do
not establish an improvement.

## Verification and restored state

Final restored production validation: **355 Python + 10 distributed tests**,
zero failures/errors, plus rebuilt C ABI and its client test. The distributed
suite now starts its localhost services successfully; the former socket-bind
sandbox failure is resolved in this environment.

The prototypes additionally passed 30 targeted Mojo tests (persistent filters,
query executor, point read view, planner), 355 Python, and C ABI. Direct-slot
passed 14 MemTable tests and 65 targeted Python cases. Those are prototype
results, not a new full production Mojo/crash run. Prior applicable production
Mojo/crash/examples evidence remains as documented in the October 2 handoff.

The retained three metric-parametrized tests cover filtered/unfiltered exact
and planned scans over default, named-only, empty-sparse and deleted points,
including default-field addition/removal and flush/reopen. They pass on baseline
and both candidates, preserving the existing behavior rather than asserting a
specific implementation. The performance failure is the before/after matrix.

Restored Python `_kernel.so` SHA-256:
`3ccdc28c64b16c26277649c1d890c552b437ad357fde30b02067f03a115b3401`.
Rejected single-borrow binary:
`7614ddeb7742ccb47bc538f8da73379d15a91427987fe2ced390d362cc6dc8db`.
Rejected direct-slot binary:
`fb57d73990a4eeeb4cab0dd1edf67b9d5bbb5e8a9dba05b606239c7930568e1d`.

## Reproduction and evidence

From the worktree root (use fresh output paths for any new run):

```bash
rtk proxy pixi run mojo --version
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:/usr/bin:/bin" PYTHONPATH=python:.:.build/qdrant-compare/deps pytest tests/python tests/distributed -q --tb=short --junitxml=.build/next-python-network.xml
rtk proxy pixi run env DYLD_LIBRARY_PATH=.build/c .build/c/test_akasha_c_api
rtk proxy git diff a710aa5 -- src
```

The final command must produce no production-source diff for this delivery.
Local raw work lives under `.build/2026-10-03-resume`,
`.build/2026-10-03-single-values-warm`, `.build/2026-10-03-single-values-mixed`,
and `.build/2026-10-03-default-slot-warm`. The archived drivers specify package
paths and fresh output directories; change those paths for a new experiment,
not the frozen workload, chosen ef values or existing reports. The mixed driver
and warm assessments intentionally exit 1 for failed speed gates.

The portable archive contains both candidates' changed sources, drivers,
workload/oracle identities, all raw reports, sample stacks, compiler/test logs,
JUnit, and restored source/binary identity. Interim `production-identity.json`
records the temporarily installed prototype; `restored-identity.json` records
the final production state. No sustained nonresident, controlled-memory,
concurrent-client, Linux runtime, ASan or GPU-device gate was completed here.

[Portable evidence archive](results/2026-10-03-default-vector-borrow.json.gz) (17,963,326 bytes),
SHA-256 `01c426775a9b05b466cb8be0fc693cdf97c9f5b912e96966ebdde436a07dfafc`.
