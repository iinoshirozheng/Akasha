# Compaction capture: a rejected manifest-reuse optimization

The candidate saves 8–12% of capture's writer-lock time in instrumented pairs,
but regresses selective mixed-query latency and throughput on both uniform
corpora. It is rejected. Production source and the Python library are restored
to the accepted F32-codec implementation; the C library is rebuilt and tested
from restored source. No acceptance gate is newly passed.

## Capture cost and candidate

The [preceding thread controls](2026-10-16-codec-query-control.md) localized
41 of 57 slow, low-CPU selective requests to maintenance capture holding the
writer lock. This follow-up splits capture into manifest loading, checkpoint
kind detection, catalog loading and generation/file pinning. Timestamps are
stored in isolated diagnostic inputs; records are emitted after unlocking.
The same calibrated uptime clock and complete thread-framed records are used.

Nine initial workers run the original 32-block workload with `ad21da3` source,
three per corpus. Median phase durations in microseconds are:

| Corpus | Capture lock | Manifest | Kind | Catalog | Pin |
| --- | ---: | ---: | ---: | ---: | ---: |
| Uniform-128 | 121.1 | 23.5 | 10.8 | 16.1 | 67.6 |
| Uniform-1536 | 159.8 | 45.4 | 13.2 | 18.8 | 79.4 |
| Real-1536 | 159.0 | 40.5 | 13.1 | 18.0 | 83.3 |

Independent phase medians need not sum to the lock median. Pinning calls
`ManifestFileLease`, which reopens and validates the manifest already read by
capture, then opens and shared-locks its referenced files. The candidate adds
`GenerationPinRegistry.pin_manifest` and a directory/manifest lease constructor
so compaction can reuse its validated authority while holding the writer lock.
Generation-only snapshot pinning continues to load and check the manifest;
per-file opens, advisory locks, cleanup and durable publication stay intact.

This is an Akasha file-ownership optimization, not a Qdrant-format port. The
prior report retains the pinned Qdrant merge-planner evidence; that separate
size-based batching design was not implemented in this candidate.

## Paired results

Three alternating version pairs per corpus compare the accepted library with
the candidate, using fresh database copies, unchanged updates, ef, query order,
oracles and Python adapters. All builds/tests finish before timing starts.
A separate three-pair series measures the native capture phases. Table entries
are medians of paired **candidate / accepted** ratios.

| Corpus | Capture lock, traced | Pin, traced | Selective QPS, uninstrumented | Selective p95, uninstrumented | Total flush, uninstrumented |
| --- | ---: | ---: | ---: | ---: | ---: |
| Uniform-128 | 0.898 | 0.848 | 0.918 | 2.299 | 0.972 |
| Uniform-1536 | 0.876 | 0.836 | 0.944 | 1.672 | 1.057 |
| Real-1536 | 0.919 | 0.893 | 1.047 | 0.657 | 1.057 |

Uniform-128 selective p95 ratios are 2.299, 0.826 and 2.764 across the three
trials. Uniform-1536 ratios are 1.054, 1.986 and 1.672. Favorable real-corpus
results and traced selective ratios do not override those failures. Among
non-selective uninstrumented cells, QPS ratios range from 0.981 to 1.009 and
p95 from 0.921 to 1.029. Full per-trial query, write and flush results remain
in the archive, including the 1.137 uniform-1536 median write-total ratio.

The measured local savings are real evidence for the duplicated work, but they
do not demonstrate a useful end-to-end optimization. Scheduling and I/O vary;
this experiment does not prove that the removed read caused every regression.
It is sufficient to reject this candidate as the proposed tail-latency fix.

## Correctness and restoration

- New tests first fail because `pin_manifest` does not exist, then all three
  pass: exact-file retention across close/reopen and last release, missing
  authority without a leaked pin, and registry-dimension rejection.
- The candidate passes 76 relevant native Mojo/recovery cases, 388 Python/
  distributed cases (one skip, three warnings), and the rebuilt C suite.
  Seventeen cases also pass on emulated Linux x86_64, including the new tests,
  file retirement and point compaction. This is not native Linux acceptance.
- All 45 measurement workers preserve the original response IDs, F32 bits,
  search statistics and execution classification: 12,960 equality audits.
  All 45 exact reopens and 45 Arrow leases pass. Minimum mode-mean recall is
  0.95694. These checks cover the nine localization workers and both 18-worker
  paired series.
- The candidate's production patch, new tests, native libraries, source
  snapshots and validation logs are retained as evidence. Its production
  source and test additions are removed from the working branch after rejection.

The restored Python library is SHA-256
`5caff7a35db0edca7b9ad94f919a5c892b4a3c0eb828d5ac1546ca5363f69d78`;
the candidate is
`11d3d432bb94a113a7598445ce226e4d169cf3047575c11fa81e534dc6f93042`.
The rebuilt/restored C library is
`d9bcb992dda8859948e5cc1775ed76cb5c27375b9a4d25fe3c8a283ce12cb32b`.
Source restoration is checked with an empty `git diff -- src tests`, and the
restored C test passes. Earlier unchanged accepted-code tests remain applicable.

The next design boundary is moving filesystem capture/pinning outside the
writer lock, with a retained source owner and explicit handling of a manifest
advance or file-retirement race. Missing/corrupt authority at an unchanged
generation must remain an error; partial leases must unwind before retry.
That protocol needs deterministic publication/reclamation race tests before
implementation is retained. Simply removing locks/leases or trimming another
small operation inside the same critical section is not a demonstrated fix.

Formal speed, 128 MiB pressure, full type/lifecycle, concurrent-client and native
Linux gates remain open. The local reference state is `b606911` / production
implementation `ad21da3`; this report commits evidence only.

[Evidence archive](results/2026-10-16-compaction-capture.json.gz): 250 text
artifacts, 2,051,802 bytes, SHA-256
`ebe762cfd5d52535ca9e060ab2529ca6a3f3275e846481d022b9ad8625506505`.
Every embedded file hash is verified after decompression. Original query plans
are linked by hash to the preceding archive, which contains their complete
text; they are not duplicated here.
