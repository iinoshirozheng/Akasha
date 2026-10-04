# Combined authority and metadata cache encoding — 2026-10-04

Adopted as a maintenance CPU improvement, with query regressions retained. **M5/M6 remains incomplete; the original performance matrix is FAILED.** Warm strict parity is 25→26/36, mixed 19→17/36, and durable write+flush 3→3/9. Both variants pass the selected recall gate in all 36 warm and 36 mixed cells. Four mixed performance pass→fail cells remain failures.

Baseline `df61cf6` / engine `8ba04ce`; Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4. [Design](../plans/2026-10-04-combined-cache-encoding.md).

## Implementation and contracts

The legacy cache publisher encoded each authoritative payload for its source checksum and then encoded the same stable metadata slots again. It now walks authority once and shares each validated payload byte sequence between the unchanged CRC stream and metadata framing. A private framing helper is shared with the existing metadata encoder. The existing checksum-only entry point remains available and does not produce metadata.

No cache version/kind, source fingerprint, accepted payload, durable commit order, index/query semantics or dependency changes. The named point-store branch retains its existing path. The native maintenance worker is unchanged. This removes a second serialization pass; it is distinct from the rejected payload scratch-reuse prototype.

## Correctness and integration

- 108 unique targeted Mojo tests and 7 related checkpoint-order crash tests passed. The three new tests cover independent frozen little-endian bytes/CRC, empty state, tombstones, all payload types, signed zero, 96 update/delete/reinsert steps across 19 IDs, sparse-only fingerprint identity, oversized payload rejection and retry.
- Independent fixtures include empty CRC `0x2707D814`, initial CRC `0xFFE4398B`, 112-byte initial metadata and 64-byte tombstone metadata. Mutation comparisons additionally use the prior metadata encoder and standalone checksum.
- Full saved-package Python: **506 passed**, with `-o pythonpath=`, absolute import/hash guard, copied-source child compiler remapping and Metal wrapper. C ABI/client and all three rebuilt examples passed.
- Original warm: 7,236 result audits and 7,236 exact-oracle checks; 2,412 A/B paired IDs/stats and 24,120 F32 score bits agree. Original mixed: 7,776 result audits; 2,592 A/B paired IDs/stats and 25,920 score bits agree. All 32 writes/flushes per worker, final reopen exact oracles and retained Arrow leases pass.
- All nine A/B final metadata payload byte hashes, source checksums, dimensions, sequences and slot counts agree. Eighteen outer CRCs were independently checked. Complete files agree in only 2/9 pairs: background compaction produced different generation headers in the other seven, so this is not a claim of nine whole-file byte matches.
- No new full Mojo/full crash, HTTP performance, Linux, GPU, ASan, sustained nonresident or controlled memory-limit gate. The user has no Linux runner.

The initial expected pre-implementation compile failure (missing factory), the new test’s initial UInt8 literal inference error, its successful correction, and the final independent tombstone fixture rerun are all retained. Repeat tests are not added to unique counts. TestSuite durations are milliseconds.

## Fixed original performance matrix

The full 54 workers completed successfully. Strict assessment exits **1** because the gate fails, not because measurement was incomplete. The original corpora/seeds/filters/K/efs, service boundaries and three trials are unchanged. Order is B/A/Q, Q/A/B, B/A/Q with fresh clones. No build, test or compression overlapped measurement; every sample and slow tail remains. Recall@10 ≥ .95 and both QPS ≥ Qdrant and p95 ≤ Qdrant are required for each cell; no tolerance or cross-cell compensation.

QPS ratios are higher-is-better; p95 ratios are lower-is-better. Each entry below is QPS / p95. A/B is candidate/baseline; A/Q is candidate/Qdrant.

### Warm

| Corpus | Trial | Mode | A/B | A/Q | Strict |
|---|---:|---|---:|---:|---|
| uniform-128 | 0 | all | 1.0096 / 0.9695 | 1.3813 / 0.6196 | PASSED |
| uniform-128 | 0 | correlated | 1.0428 / 1.0029 | 1.9271 / 0.5853 | PASSED |
| uniform-128 | 0 | independent | 0.8532 / 1.1169 | 1.5293 / 0.7282 | PASSED |
| uniform-128 | 0 | selective | 0.8103 / 1.3968 | 1.0188 / 0.9342 | PASSED |
| uniform-128 | 1 | all | 0.9809 / 1.0058 | 1.2308 / 0.7286 | PASSED |
| uniform-128 | 1 | correlated | 0.9509 / 1.0064 | 1.9336 / 0.5270 | PASSED |
| uniform-128 | 1 | independent | 0.9706 / 1.0533 | 1.5116 / 0.7666 | PASSED |
| uniform-128 | 1 | selective | 0.9715 / 1.0857 | 0.8400 / 1.2837 | FAILED |
| uniform-128 | 2 | all | 1.1674 / 0.8173 | 1.8170 / 0.4205 | PASSED |
| uniform-128 | 2 | correlated | 1.2211 / 0.9212 | 1.8511 / 0.6478 | PASSED |
| uniform-128 | 2 | independent | 1.1489 / 1.0072 | 1.8195 / 0.6812 | PASSED |
| uniform-128 | 2 | selective | 1.1418 / 0.8867 | 1.0173 / 0.7952 | PASSED |
| uniform-1536 | 0 | all | 0.9882 / 1.0797 | 2.4788 / 0.4226 | PASSED |
| uniform-1536 | 0 | correlated | 0.9543 / 1.0926 | 1.5343 / 0.7298 | PASSED |
| uniform-1536 | 0 | independent | 0.9584 / 1.0619 | 1.6154 / 0.6739 | PASSED |
| uniform-1536 | 0 | selective | 1.0070 / 0.9768 | 1.1329 / 0.7781 | PASSED |
| uniform-1536 | 1 | all | 0.9810 / 1.0755 | 2.5019 / 0.4175 | PASSED |
| uniform-1536 | 1 | correlated | 1.0017 / 1.0042 | 1.5844 / 0.6999 | PASSED |
| uniform-1536 | 1 | independent | 1.0006 / 0.9996 | 1.6918 / 0.6366 | PASSED |
| uniform-1536 | 1 | selective | 1.0212 / 1.0129 | 1.0848 / 0.8274 | PASSED |
| uniform-1536 | 2 | all | 1.0178 / 0.9485 | 2.4400 / 0.4147 | PASSED |
| uniform-1536 | 2 | correlated | 0.9265 / 1.0620 | 1.4729 / 0.7506 | PASSED |
| uniform-1536 | 2 | independent | 0.9967 / 1.0037 | 1.7402 / 0.6210 | PASSED |
| uniform-1536 | 2 | selective | 1.0569 / 0.8965 | 1.0925 / 0.8849 | PASSED |
| real-1536 | 0 | all | 1.0645 / 0.9468 | 1.0259 / 1.0068 | FAILED |
| real-1536 | 0 | correlated | 1.0617 / 0.9375 | 0.8530 / 1.0851 | FAILED |
| real-1536 | 0 | independent | 1.0416 / 0.9512 | 0.7452 / 1.3258 | FAILED |
| real-1536 | 0 | selective | 0.9734 / 1.0410 | 0.9893 / 1.0585 | FAILED |
| real-1536 | 1 | all | 1.1425 / 0.8924 | 1.0179 / 1.0461 | FAILED |
| real-1536 | 1 | correlated | 1.1817 / 0.7368 | 0.7989 / 1.1342 | FAILED |
| real-1536 | 1 | independent | 1.0276 / 0.9644 | 0.7247 / 1.4141 | FAILED |
| real-1536 | 1 | selective | 1.0208 / 1.0344 | 1.0662 / 0.8906 | PASSED |
| real-1536 | 2 | all | 0.9849 / 1.0055 | 1.0096 / 0.9863 | PASSED |
| real-1536 | 2 | correlated | 0.9853 / 1.0002 | 0.8529 / 1.1514 | FAILED |
| real-1536 | 2 | independent | 0.9197 / 1.0641 | 0.6957 / 1.4201 | FAILED |
| real-1536 | 2 | selective | 1.0111 / 0.9910 | 1.1822 / 0.7910 | PASSED |

### Mixed

| Corpus | Trial | Mode | A/B | A/Q | Strict |
|---|---:|---|---:|---:|---|
| uniform-128 | 0 | all | 0.9659 / 1.0091 | 1.2122 / 0.7853 | PASSED |
| uniform-128 | 0 | correlated | 0.9418 / 1.0775 | 1.9437 / 0.6851 | PASSED |
| uniform-128 | 0 | independent | 0.9422 / 1.0858 | 1.8316 / 0.7697 | PASSED |
| uniform-128 | 0 | selective | 0.9666 / 3.0589 | 0.8697 / 2.7505 | FAILED |
| uniform-128 | 1 | all | 0.8535 / 1.5229 | 1.1534 / 1.1398 | FAILED |
| uniform-128 | 1 | correlated | 0.8592 / 1.8109 | 1.9069 / 1.1863 | FAILED |
| uniform-128 | 1 | independent | 1.0005 / 1.0477 | 1.7978 / 0.7703 | PASSED |
| uniform-128 | 1 | selective | 0.9589 / 1.2301 | 0.9446 / 1.1428 | FAILED |
| uniform-128 | 2 | all | 0.9702 / 1.4712 | 1.0006 / 1.3736 | FAILED |
| uniform-128 | 2 | correlated | 0.9905 / 0.9794 | 1.8776 / 0.6524 | PASSED |
| uniform-128 | 2 | independent | 0.9874 / 0.7751 | 1.8523 / 0.7460 | PASSED |
| uniform-128 | 2 | selective | 0.9721 / 0.8226 | 1.0155 / 0.9068 | PASSED |
| uniform-1536 | 0 | all | 0.9784 / 1.0321 | 2.2187 / 0.4679 | PASSED |
| uniform-1536 | 0 | correlated | 0.9614 / 1.0303 | 1.6436 / 0.6882 | PASSED |
| uniform-1536 | 0 | independent | 0.9256 / 1.1846 | 1.6192 / 0.7379 | PASSED |
| uniform-1536 | 0 | selective | 0.9876 / 0.5684 | 1.0642 / 0.8814 | PASSED |
| uniform-1536 | 1 | all | 0.9901 / 1.0117 | 2.1030 / 0.5226 | PASSED |
| uniform-1536 | 1 | correlated | 0.9995 / 0.8369 | 1.5735 / 0.6998 | PASSED |
| uniform-1536 | 1 | independent | 0.9451 / 1.0542 | 1.5577 / 0.7379 | PASSED |
| uniform-1536 | 1 | selective | 0.8938 / 1.2005 | 0.9324 / 1.1459 | FAILED |
| uniform-1536 | 2 | all | 1.0007 / 0.9801 | 2.1280 / 0.5194 | PASSED |
| uniform-1536 | 2 | correlated | 0.9700 / 1.0575 | 1.5241 / 0.7667 | PASSED |
| uniform-1536 | 2 | independent | 1.0016 / 0.9411 | 1.5997 / 0.6734 | PASSED |
| uniform-1536 | 2 | selective | 0.8918 / 1.6152 | 0.9406 / 1.6261 | FAILED |
| real-1536 | 0 | all | 0.9607 / 1.0606 | 1.0417 / 1.3535 | FAILED |
| real-1536 | 0 | correlated | 0.9985 / 1.0386 | 0.7788 / 1.4532 | FAILED |
| real-1536 | 0 | independent | 0.9642 / 1.1352 | 0.4947 / 2.3177 | FAILED |
| real-1536 | 0 | selective | 0.8947 / 1.7190 | 0.8019 / 2.1461 | FAILED |
| real-1536 | 1 | all | 1.0066 / 0.8926 | 0.8056 / 1.3740 | FAILED |
| real-1536 | 1 | correlated | 0.9890 / 0.9252 | 0.7526 / 1.3483 | FAILED |
| real-1536 | 1 | independent | 0.9827 / 0.9032 | 0.4891 / 2.0898 | FAILED |
| real-1536 | 1 | selective | 0.9302 / 1.2461 | 0.8119 / 2.0831 | FAILED |
| real-1536 | 2 | all | 1.0049 / 1.0645 | 0.7892 / 1.5292 | FAILED |
| real-1536 | 2 | correlated | 0.9987 / 1.0206 | 0.7392 / 1.6032 | FAILED |
| real-1536 | 2 | independent | 1.0150 / 0.9109 | 0.4859 / 2.0826 | FAILED |
| real-1536 | 2 | selective | 0.9346 / 1.9115 | 0.7862 / 2.0059 | FAILED |

There are 21/36 warm and 32/36 mixed A/B cells with lower QPS or higher p95. Mixed pass→fail: uniform-128 trial 1 all/correlated, uniform-128 trial 2 all, uniform-1536 trial 1 selective. These are retained and are not excused by the write improvement.

### Durable write and flush

Write-only calls have different durability boundaries, so the accepted maintenance comparison is each block’s own write+flush sum. Each worker retains all 32 samples.

| Corpus | Trial | Flush A/B | Combined A/B | Combined A/Q | Strict |
|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | 1.2913 / 0.7296 | 1.1988 / 0.7929 | 1.6704 / 0.6006 | PASSED |
| uniform-128 | 1 | 1.3181 / 0.7613 | 1.2109 / 0.8246 | 1.5596 / 0.6388 | PASSED |
| uniform-128 | 2 | 1.3444 / 0.7337 | 1.2338 / 0.7901 | 1.6589 / 0.6140 | PASSED |
| uniform-1536 | 0 | 1.2306 / 0.7179 | 1.1059 / 0.8890 | 0.6907 / 1.5030 | FAILED |
| uniform-1536 | 1 | 1.2129 / 0.8222 | 1.1083 / 0.8930 | 0.6556 / 1.5932 | FAILED |
| uniform-1536 | 2 | 1.1368 / 0.9104 | 1.0642 / 0.9026 | 0.8759 / 0.7174 | FAILED |
| real-1536 | 0 | 1.1567 / 0.9473 | 1.0956 / 0.9375 | 0.8017 / 1.3171 | FAILED |
| real-1536 | 1 | 1.1330 / 0.9817 | 1.0823 / 0.9751 | 0.7664 / 1.4428 | FAILED |
| real-1536 | 2 | 1.1147 / 1.1927 | 1.0772 / 1.1445 | 0.8200 / 1.4142 | FAILED |

Combined QPS improves in all nine cells by 6–23%; combined p95 improves in eight and regresses 14.45% for real trial 2. High-dimensional maintenance still fails strict parity. Individual write, flush and combined samples and all quantiles are in the archive.

## Additional diagnostics; not replacement acceptance results

The primitive microbenchmark uses 8,192 rows, four payload fields, dimensions 128/1536, ten samples in each of three alternating pairs. Full output payload bytes and CRC agree. Mean duration A/B is 0.5634/0.5296/0.5473 at 128D and 0.7095/0.7249/0.7307 at 1536D.

To investigate mixed query regressions, 18 additional fresh workers ran the exact original mixed plans with wall, foreground-thread CPU and process CPU clocks. All 5,184 audits, 2,592 A/B ID/score/stats comparisons (25,920 bits), 18 reopen oracles and 18 leases passed. The instrumentation does not replace or change the original matrix.

| Corpus | Trial | Query wall A/B | Query thread CPU A/B | Flush wall A/B | Flush thread CPU A/B |
|---|---:|---:|---:|---:|---:|
| uniform-128 | 0 | 0.9832 | 0.9798 | 0.7427 | 0.7417 |
| uniform-128 | 1 | 0.8938 | 0.9241 | 0.7395 | 0.7363 |
| uniform-128 | 2 | 1.0185 | 1.0047 | 0.7638 | 0.7522 |
| uniform-1536 | 0 | 0.9813 | 0.9809 | 1.0726 | 0.8621 |
| uniform-1536 | 1 | 0.9571 | 0.9517 | 0.9495 | 0.8376 |
| uniform-1536 | 2 | 1.0178 | 1.0187 | 0.8087 | 0.8408 |
| real-1536 | 0 | 0.8854 | 0.9161 | 0.8321 | 0.8281 |
| real-1536 | 1 | 1.0014 | 0.9947 | 0.9160 | 0.8517 |
| real-1536 | 2 | 0.9848 | 0.9800 | 0.8669 | 0.8517 |

Foreground flush CPU falls in all nine pairs by approximately 14–26%, supporting removal of duplicate work. Query wall time increases in 11/36 diagnostic modes, foreground CPU in 8/36. Some tails increase without a corresponding foreground CPU increase; process CPU differs while queries execute, consistent with overlapping engine maintenance, but these clocks do not identify a specific lock or establish the cause of each regression. Uniform-1536 trial 0 also has a slower wall-time flush despite less CPU; it remains in the report.

Adoption is an engineering decision to retain a small, byte-equivalent reduction in repeated maintenance CPU, with material local write+flush gains. It is not a finding that all queries improve, a new tolerance, or acceptance of a failed cell. Query timing and named multi-run/reopen lifecycle work remain, as does unavailable sustained nonresident/memory-limit validation.

## Reproduction and artifact identity

Assessment (expected exit 1):

```sh
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-combined-cache-encoding/summarize-matrix.py
```

Timing/build/test drivers create fresh directories or exclusive logs. Recover them into a new output directory and preserve their recorded input hashes, package identities, environments, trials and command arrays; do not rerun writing drivers over existing evidence. The source-remapping wrapper and `-o pythonpath=` are required for saved-package child compilation/tests.

Python kernel SHA-256: `f33bdbf7734d2762450e9a5e9cb4234a46feee2a4b474907a9d6c3fb5ed2045d`.
Unchanged native worker SHA-256: `bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`.

Production-path revalidation: 10 targeted Mojo, 23 package/operations/paired-exact Python tests, C loader/client and the same three examples passed. These repeats are separate from the integration counts above.

[Immutable evidence archive](results/2026-10-04-combined-cache-encoding.json.gz), SHA-256 `d8a3383bec70e7fc19dda64788bb192f6d356437005c001f49e029abf96eaff9`; 581 text entries, 5,724,559 bytes. All embedded text hashes were verified after decompression. Full source snapshots, tests, failures, commands, raw samples and audit/diagnostic reports are included; large databases/binaries are represented by recorded hashes.
