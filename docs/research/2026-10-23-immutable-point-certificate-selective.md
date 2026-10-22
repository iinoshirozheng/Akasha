# Selective-query follow-up for the weak certificate candidate

This diagnostic does **not consistently reproduce** the low-dimensional
selective slowdown seen in the [full warm comparison](2026-10-23-immutable-point-score-certificate.md).
Some paired trials still regress. The formal uniform-128 selective trial-1
failed gate remains failed; no engine or acceptance result changes here.

The full comparison's selected ef=10 cell is the first selective cell. Its
candidate/prior QPS ratios are .8709, .8999 and .8923 across three trials, while
later selective cells have no consistent direction. The exact scorer itself
does not use the new score certificates. We tested whether a stable intrinsic
exact-path penalty or prior ANN work explains the result before changing code.

Eight serial workers use the same frozen uniform-128 trial-1 graph and the
same native binaries as the full comparison. Four pairs use process orders
prior/candidate, candidate/prior, candidate/prior, prior/candidate. Each worker:

1. Runs exact selective preflight for all 67 queries, then eight repetitions
   of selective ef=10. Each repetition excludes the same first three warmups
   and records all remaining 64 queries.
2. Primes all/correlated/independent using the complete 12-ef grid and all
   67 queries per cell, preserving the full comparison's ANN order.
3. Repeats selective exact preflight and the eight measured repetitions,
   then independently reopens the database for an exact check.

Request construction plus search uses the unchanged `_timed_query` boundary.
IDs, F32 bits, stats, routes and recalls match the frozen trial's reports for
every recorded query. All **8,192 measured responses, 19,296 ANN priming
responses, 1,072 preflight responses, 384 warmups and eight reopens** pass.
Every latency sample is retained and independently audited.

The diagnostic does not recreate the whole benchmark driver. In particular,
it saves its report once at the end, while the full warm driver serializes the
growing report after each cell. It also omits exact preflight for the ANN modes.
These differences limit causal conclusions; neither serialization, allocator
state, scheduling nor GC has been established as the cause.

| Phase | Repetitions | Median candidate/prior QPS | Median candidate/prior p95 |
|---|---|---:|---:|
| Before ANN | First | 1.1143 | .8208 |
| Before ANN | Later seven pooled | 1.0255 | .9751 |
| Before ANN | All eight pooled | 1.0431 | .9520 |
| After ANN | First | 1.0189 | .9612 |
| After ANN | Later seven pooled | 1.0108 | .9461 |
| After ANN | All eight pooled | 1.0179 | .9311 |

Medians above summarize the four process pairs; they do not erase regressions.
For all eight repetitions pooled, the individual ratios are:

| Pair | Before QPS | Before p95 | After QPS | After p95 |
|---|---:|---:|---:|---:|
| 0 | 1.0228 | .9889 | 1.0289 | .8963 |
| 1 | 1.2242 | .6795 | 1.0497 | .9145 |
| 2 | 1.0633 | .9152 | .9675 | 1.1309 |
| 3 | .8609 | 1.2142 | 1.0070 | .9477 |

The evidence does not justify removing the certificate design or changing the
unchanged exact scorer on the assumption of a stable ANN-induced penalty.
It also does not justify calling the formal regression noise. Continue with
full-driver phase/allocation diagnostics and the remaining real correlated
traversal cost; keep the strict warm result at **12/36**.

The [archive](2026-10-23-immutable-point-certificate-selective.json.gz) contains
**40 artifacts / 3,551,531 compressed bytes**, SHA-256
`395ccc1e31e251d9795c0aa56468320fa82858db393cadd7bcd3247cb3ae4ee1`.
It includes workers, raw reports, original failed-gate context, frozen expected
responses, database/workload/native identities, the decision and auditors.
The complete engine source is hash-linked to the parent candidate archive.
Archive-only replay verifies every embedded hash and reproduces `audit.json`
byte-for-byte. Extract its `files` text entries and run `audit_archive.py ARCHIVE`
without engine binaries or databases. No Qdrant rerun or new acceptance is claimed.
