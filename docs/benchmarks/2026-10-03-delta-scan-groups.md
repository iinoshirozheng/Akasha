# Four-row F32 delta scan grouping — not adopted

The isolated candidate on `a57f11a` reuses the existing owned four-row F32 kernel
for admitted delta rows, keeping scalar tails and all non-F32 paths. It preserves
query validation, scan bounds, result/heap order, score bits and every reported
stat. Public gains are not consistent across the affected real ANN cells, and
both full-matrix gates fail. **The candidate is not promoted; production remains
`a57f11a` / Python binary `b183b880…`. M5/M6 is incomplete.**

## Evidence and decision

The preceding profile puts scalar delta scoring at 6.04–7.05% of filtered real
ANN main-thread samples. That limits the likely end-to-end benefit. A separate
read-only disassembly of the profiled `c00494f` binary maps the mapped four-row
hot offsets +1512 / +1536 to a vector load / loop progression. The steady loop
has no vector-register spills. Bounds branches remain, but this sample does not
separate their cost or validate the previously rejected full-row/raw-span probes.
Frozen sidecars place the vector section at byte 327840 (32 modulo 64), with
1536D rows retaining that offset; the paired 32-byte native loads are aligned.
No storage-layout change follows from that observation.

The candidate passes **101 targeted Mojo tests** and **358 full Python tests**
(three existing warnings). The three new Mojo cases compare scalar-oracle IDs,
score bits and stats for Dot/L2/Cosine, dimensions 3/17/64/65/128/1536, admitted
counts 0–11, reverse-ID ties, inactive/replaced rows, rejected current rows, full
groups and every tail. They pass on the baseline before the candidate is written,
and again against the isolated tree. These tests are retained in the repository.
Existing invalid query/demand/identity and all native backend tests also pass.
No new C ABI/examples/crash/distributed/full Mojo gate is claimed for this
unadopted candidate; the prior production validations remain applicable.

Saved pytest uses `-o pythonpath=` and the copied package first. The binding entry
and includes both come from the copied source. Pixi activation and the Metal
wrapper propagate to child compilation. Compiler: Mojo 1.0.0 (`ed45d567`), Apple
M4 / Metal:4. TestSuite times are milliseconds. Production binary and native
worker remain untouched throughout the experiment.

| Workload | Baseline strict pass | Candidate strict pass | Pass→fail |
|---|---:|---:|---:|
| Warm | 23/36 | 22/36 | 2 |
| Mixed | 28/36 | 29/36 | 1 |

All 108 quality cells in each run pass. Warm retains 6,912 timed audits, 7,236
exact checks and 324 warmups; mixed retains 7,776 audits, 27 reopens and 18 leases.
IDs, Float32 bits, stats and execution match. Each assessment correctly returns
exit 1 (**FAILED**). Corpora, seeds, filters, K, efs, service boundaries and three
rotating trials are unchanged; workers run serially with no overlapping builds,
tests, profiles or compression. Every latency sample remains, including failures.
Recall@10 ≥ .95 and both QPS ≥ Qdrant / p95 ≤ Qdrant remain mandatory per cell.

Warm real correlated QPS improves 4.3–7.9% in all three trials, but real independent
trial 0 regresses to QPS 0.924 / p95 1.139. Mixed real correlated and independent
trial 1 regress to QPS 0.979 / 0.974 and p95 1.067 / 1.104. Mixed real all QPS
also regresses in every trial, although that operation uses the unchanged owned
HNSW traversal. This is insufficient repeatable public benefit for promotion.
Unchanged paths and earlier A/A variability do not justify excluding regressions.

Warm pass→fail cells: uniform-128 independent trial 1 and uniform-1536 selective
trial 2. Mixed pass→fail: uniform-128 selective trial 0 (p95 ratio 3.373). No gains
in another cell or workload offset these failures.

## Every candidate/baseline trial

Ratios are trials 0 / 1 / 2; higher QPS and lower p95 are better.

### Warm

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 0.999 / 1.004 / 0.985 | 0.994 / 0.995 / 1.057 |
| uniform-128 | correlated | 0.934 / 1.018 / 0.939 | 1.307 / 0.917 / 1.095 |
| uniform-128 | independent | 2.056 / 0.609 / 0.792 | 0.389 / 1.831 / 1.843 |
| uniform-128 | selective | 1.230 / 1.043 / 1.016 | 0.676 / 1.008 / 0.964 |
| uniform-1536 | all | 0.997 / 1.027 / 1.004 | 0.955 / 0.968 / 0.995 |
| uniform-1536 | correlated | 1.019 / 1.036 / 0.979 | 0.960 / 0.997 / 1.013 |
| uniform-1536 | independent | 0.984 / 1.058 / 0.974 | 1.006 / 0.967 / 1.016 |
| uniform-1536 | selective | 1.011 / 1.049 / 0.938 | 0.959 / 0.908 / 1.145 |
| real-1536 | all | 1.001 / 0.997 / 0.985 | 1.027 / 1.004 / 1.040 |
| real-1536 | correlated | 1.064 / 1.043 / 1.079 | 0.949 / 0.942 / 0.921 |
| real-1536 | independent | 0.924 / 1.035 / 1.007 | 1.139 / 0.970 / 0.970 |
| real-1536 | selective | 0.993 / 1.013 / 1.006 | 0.988 / 0.964 / 0.951 |

### Mixed

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 0.999 / 0.989 / 1.061 | 1.010 / 1.022 / 0.888 |
| uniform-128 | correlated | 1.125 / 1.076 / 0.969 | 0.562 / 0.641 / 0.939 |
| uniform-128 | independent | 0.953 / 0.935 / 0.995 | 1.076 / 1.167 / 0.901 |
| uniform-128 | selective | 0.804 / 1.061 / 1.139 | 3.373 / 1.047 / 0.302 |
| uniform-1536 | all | 1.007 / 1.000 / 1.025 | 1.004 / 1.000 / 0.996 |
| uniform-1536 | correlated | 1.030 / 0.996 / 1.064 | 0.996 / 1.005 / 0.937 |
| uniform-1536 | independent | 1.053 / 1.003 / 1.042 | 0.836 / 0.975 / 1.022 |
| uniform-1536 | selective | 1.071 / 1.043 / 1.145 | 0.974 / 0.743 / 0.603 |
| real-1536 | all | 0.950 / 0.885 / 0.970 | 1.061 / 1.310 / 0.995 |
| real-1536 | correlated | 1.028 / 0.979 / 1.067 | 0.983 / 1.067 / 0.973 |
| real-1536 | independent | 1.039 / 0.974 / 1.036 | 0.931 / 1.104 / 0.995 |
| real-1536 | selective | 1.009 / 1.001 / 1.095 | 0.913 / 0.657 / 0.995 |

## Frozen evidence and reproduction

[Immutable archive](results/2026-10-03-delta-scan-groups.json.gz): 189 files,
18,656,128 bytes; SHA-256
`c8a273b4e2ed1e6087904b546c45ebcd70636660cac766461d3d2f94b5c6c044`.
Every decoded file hash was verified. It retains the candidate source, baseline
and candidate test logs, full public trials/samples, identities, drivers, plan
and baseline mapped-kernel disassembly. Production source baseline is `a57f11a`;
the native assembly identity is explicitly the earlier `c00494f` binary.
Candidate Python SHA-256:
`32122968c796b03c88e7cbf5f5ad9a68e9069d12683880290b8d5e0cdcbe55ec`.

Warm / mixed report hashes:
`a6bab0990aa050fbcd5a1a73e6bec62f0fe4f5907a2dabb47a84fdc50fd45ade` /
`1d06249abc90a0e18f3cf94ff4049d6b21cc5413defce6b70dc838bb65ffd7b4`.
Archived `validate.py`, `measure-warm.py`, `assess-warm.py`, `measure-mixed.py`
and `measure.py` preserve the exact commands and schedule. The archived integration
script was prepared but **not run**; it is not validation evidence. Use fresh
directories and do not rerun mutating drivers over preserved variants/archives.

Retained test:

```bash
rtk proxy sh -c 'pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_delta_scan_groups.mojo'
```

There is no available native Linux runner. Sustained nonresident / controlled
memory and concurrent-client/HTTP parity remain unfinished. This experiment
neither closes those gates nor repeats the completed October 2 Git delivery.
