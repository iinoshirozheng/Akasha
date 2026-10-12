# Mapped legacy segment recovery

The adopted change removes the owned, file-sized byte buffer from
`read_segment`. It fixes the observed recovery OOM at 224 and 192 MiB for the
fixed real-1536 corpus. It does **not** establish Qdrant query parity: the
three-way resident comparison passes speed in only 16/36 cells, both before
and after. All 36 cells meet the quality gate in each version.

## Change and contracts

The previous loader retained an encoded 53 MiB segment while allocating its
decoded records. The new loader validates the immutable file through
`MappedFile`, then decodes it through an origin-bound `MappedBinaryReader`.
Scalar reads are checked and unaligned; bulk byte/F32 reads return independent
owned lists. Bounds use subtraction and division before multiplication or
allocation. Empty ranges never dereference an absent mapping pointer.

The owned `decode_segment_bytes` API and mapped file reader share one parser
through the narrow `BinaryReaderSource` trait. The segment bytes, versions
1–3, checksum coverage, sequence checks, payload decoding and returned record
ownership are unchanged. There is no new durable format or fallback path.
The file inode must remain immutable during the synchronous read, as with
other mapped storage; committed segment publication already uses new inodes.

The baseline is maintenance-fixed engine `be3be53`, with benchmark/documentation
HEAD `00dfccd`. Mac tests and measurements use Mojo 1.0.0 with
`--target-accelerator=metal:4 --target-cpu=apple-m4`. Linux uses the existing
emulated x86-64 Docker runtime, not native Linux performance hardware.
The archive distinguishes the original built source from the final formatted
source and verifies every original Mac source hash against the preserved Linux
copy. A final root-source Python extension and C ABI were rebuilt separately.

## Recovery measurements

Three alternating native Mac pairs read the same real-1536 base segment:

| Trial | Owned read ms | Mapped read ms | Owned process peak MiB | Mapped process peak MiB |
| --- | ---: | ---: | ---: | ---: |
| 0 | 32.841 | 16.663 | 205.8 | 121.5 |
| 1 | 30.478 | 17.138 | 205.8 | 121.4 |
| 2 | 30.225 | 16.454 | 205.8 | 121.4 |

All pairs return 8,192 entries with identical checksum and vector-bit XOR.
This microbenchmark is diagnostic; the correctness tests and query oracle
audits provide the stronger equivalence checks.

Full public-open times from the resident query experiment are:

| Corpus | Before ms, all trials | After ms, all trials |
| --- | --- | --- |
| Uniform 128 | 170.30, 124.44, 124.78 | 125.49, 120.57, 120.56 |
| Uniform 1536 | 182.73, 189.94, 186.66 | 170.58, 174.55, 174.59 |
| Real 1536 | 208.47, 207.20, 205.42 | 187.22, 186.80, 187.72 |

The first uniform-128 baseline outlier is retained. Whole Python-worker peak
RSS includes NumPy workload inputs and must not be equated with kernel-only
memory: real-1536 before peaks were 498.0–502.6 MiB versus 325.7–333.2 MiB after.

## Controlled memory follow-up

This reuses the [baseline cap diagnostic](2026-10-13-memory-cap-probe.md): same
Linux-volume fixtures, fresh copied inodes, zero initial vector-file residency,
one CPU, disabled container swap, query-only input, frozen efs and eight passes
of 64 queries per mode. No cache eviction occurs during measurement.

| Cap | Original Akasha | Mapped loader | Sustained nonresident ANN evidence |
| --- | --- | --- | --- |
| 256 MiB | Completes, resident | Completes, resident | No |
| 224 MiB | OOM during open | Completes | Does not meet the defined criterion |
| 192 MiB | OOM during open | Completes | All, correlated and independent |
| 128 MiB | OOM during open | OOM during open | No completed queries |

Every successful mapped run has identical preflight IDs, F32 score bits and
execution statistics to the original 6 GiB control. Recall is .9671875 for
all, .953125 correlated, .965625 independent, and 1.0 selective. Repeated
passes verify stable responses; they do not add independent recall queries.

At 192 MiB, every final-four ANN pass has positive process major faults and
vector-file residency below .95, satisfying the predeclared diagnostic rule:

| Mode | Final-four faults per pass | Final-four vector residency | Aggregate QPS |
| --- | --- | --- | ---: |
| All | 24,348 / 24,522 / 23,972 / 24,214 | .413 / .404 / .421 / .416 | 45.3 |
| Correlated | 42,637 / 41,637 / 41,934 / 42,404 | .364 / .381 / .374 / .370 | 26.3 |
| Independent | 54,071 / 52,960 / 53,438 / 53,878 | .319 / .332 / .325 / .320 | 21.4 |

Fault counts are process-wide, not per-file attribution. Selective exact
search uses owned record vectors and has zero late faults, so an evicted HNSW
sidecar does not prove nonresident exact inputs. Akasha's 192 MiB ANN speed is
far below the earlier Qdrant 192 MiB diagnostic; success at opening the
database is not a speed pass. This one-corpus follow-up is not the complete
repeated memory-limit matrix. Both engines' nonmonotonic cap curves and all
OOM states remain in the evidence.

## Resident query comparison

Three rotating before/after/Qdrant triples per corpus use the existing fixed
8,192-point workloads, 64 measured queries plus three warmups per mode, K=10,
and frozen warm efs. Qdrant is Edge 0.8.0. This is the binding-call boundary,
separate from the HTTP concurrent-client and constrained-memory experiments.
All before/after IDs, F32 score bits, execution statistics and warmup results
match exactly. Both versions pass quality 36/36 and strict speed 16/36.

| Corpus / mode | Median after/before QPS | Median after/before p95 |
| --- | ---: | ---: |
| Uniform 128 / all | 1.020 | .951 |
| Uniform 128 / correlated | .964 | .995 |
| Uniform 128 / independent | .984 | 1.107 |
| Uniform 128 / selective | .959 | 1.172 |
| Uniform 1536 / all | .956 | 1.061 |
| Uniform 1536 / correlated | 1.018 | .992 |
| Uniform 1536 / independent | 1.004 | .977 |
| Uniform 1536 / selective | .936 | 1.047 |
| Real 1536 / all | 1.012 | 1.014 |
| Real 1536 / correlated | 1.004 | .901 |
| Real 1536 / independent | .970 | 1.040 |
| Real 1536 / selective | 1.019 | .962 |

These include regressions. The change is adopted for measured recovery memory
and opening behavior, with no claim that unchanged query kernels improved or
that these regressions can be offset by another cell. Each trial's Qdrant
comparison remains independent: QPS must be at least Qdrant and p95 no greater,
with Recall@10 at least .95. Real-1536 speed fails in all 12 cells.

## Verification and reproduction

- Mac: 105 distinct relevant Mojo tests, plus all 23 crash cases; this includes
  the eight existing segment tests, six new reader/equivalence cases, 71
  storage/recovery cases and 20 background-publication cases.
- Mac: full Python suite 355 passed, followed by the new reader-origin compile
  rejection test (356 distinct cases across these runs). The final source
  passed seven mapping ABI/compile checks; the rebuilt root extension passed
  17 package integration cases. These retries are not extra distinct tests.
- Rebuilt C ABI library and its compiled C consumer pass.
- Emulated Linux x86-64: 22 targeted cases pass, covering checksum, bulk F32,
  segment, reader and mapped equivalence, followed by a fresh Python extension
  build. The later empty-reader test was executed on Mac only.

New cases cover v1/v2/v3 base/delta equivalence, legacy NaN payload bits and
negative zero, negative IDs, UTF-8 payloads, every torn prefix, corrupted CRC,
checksummed invalid headers, wrong dimension, invalid/overflow counts,
unaligned reads, close and empty mapping behavior, and owned data surviving
mapping destruction/file overwrite/unlink. A negative compile check prevents
the reader from escaping its owner's origin.

Canonical focused commands (add the Mac target flags above on this host):

```bash
pixi run mojo run -I src tests/mojo/test_mapped_binary_reader.mojo
pixi run mojo run -I src tests/mojo/test_mapped_segment.mojo
pixi run pytest tests/python/test_mapped_file_abi.py tests/python/test_mapped_file_compile_contract.py -q
```

The raw archive contains the exact benchmark/test drivers, all warm trial
results and latencies, cap jobs/cgroup/mincore observations, source/binary
hashes, initial missing-module red test and initial microbenchmark compile
failure. It references the baseline cap archive for the original OOMs and
Qdrant controls. Local large fixtures remain under `.build/m5-resume/` and the
owned Docker volume `akasha-m5-memory-20261013`.

Artifact: [raw evidence](2026-10-13-mapped-segment-read.json.gz).
SHA-256: `1a422eb942233e3b233c5999407cee19a36eba0234f8aa59acf0d15d4ec12e81`.
