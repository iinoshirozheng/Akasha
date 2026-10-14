# Reuse checkpoint writers for length-prefixed payloads

Direct payload encoding removes about **5.6–6.7 ms from flush medians** in the
fixed mixed matrix. All nine flush QPS/p95 pairs and all nine combined write+flush
QPS/p95 pairs improve. Combined strict passes rise **3 → 5 / 9**, including two
real-1536 cells. The candidate remains isolated: warm real-1536 all trial 2 changes
pass→fail, other existing query/write failures remain, and M5/M6 are incomplete.

The parent is the frozen [live-query-lock candidate](2026-10-14-live-query-lock.md),
including its unadopted checkpoint-copy improvements and recorded failures.
Four source files change relative to it. `BinaryWriter` gains a current position
and a bounds-checked little-endian UInt32 patch. The codec appends its existing
payload-v1 body into a supplied writer and patches the preceding length. The
public owned `encode_payload` API uses the same body. Authoritative fingerprinting
uses its existing capacity-preserving CRC drain; metadata cache encoding writes
directly into final output. Neither allocates a separate encoded payload per row.

Field order, type/value bits, UTF8 bytes, count/name/string checks and the 16 MiB
single-payload limit remain unchanged. The limit excludes the length prefix and
earlier records. This bound also makes the former metadata UInt32 overflow check
redundant. Callers discard the local writer on encoding error; the append helper
does not promise rollback of partial output. No partial record is published.
No new dependency, persistent encoded cache, query change or format migration is
introduced. Local RocksDB byte-builder and Qdrant payload-storage references are
retained with the existing Akasha contracts; their different serializers are not
substituted for payload v1.

Five new cases check independent scalar-reference bytes across 16 string sizes,
all payload kinds and embedded UTF8/NUL, consecutive records, independent Python
struct metadata golden bytes, 16 MiB accounting, stable writer capacity through
64 CRC drains, and patch bounds including Int.MIN/Int.MAX. The parent fails the
four-case compile probe because it lacks the new helper/writer API; the metadata
golden case is appended before candidate validation. The exact parent probe is
retained separately. Existing independent fingerprint CRC fixtures also pass.

Fresh validation passes **103 Mojo cases in 17 files**, **15 crash-state cases in
four files**, **369 Python cases**, and C ABI compilation/execution. Codec, WAL
and segment v1 compatibility, point codec/store/migration, persisted caches and
checkpoint/batch recovery are covered. Python has three existing warnings and no
skips; shared-library builds have no warnings. A missing build-output parent
directory stopped the harness after all Mojo/crash tests had passed, before any
compiler invocation. The failure is retained; creating the directory allowed
build/Python/C verification to continue without repeating successful suites.

All **54 serial native workers** complete with unchanged plans, corpora, filters,
ef values, query timing, oracles and rotating triples. Warm takes 44.34 s, mixed
65.54 s. Quality passes 36/36 for each version in each phase. IDs, Float32 bits,
statistics and execution decisions match exactly; all lease/reopen checks pass.
All 18 overlay/metadata payload pairs are byte-identical, with valid envelope and
inner snapshot CRCs. Mixed returns its expected strict-gate failure after all
nine triples, not an incomplete-run status.

| Phase | Strict speed before → after | Pass → fail | Fail → pass |
| --- | ---: | ---: | ---: |
| Warm queries | 20 → 21 / 36 | 1 | 2 |
| Mixed queries | 28 → 28 / 36 | 0 | 0 |
| Mixed write+flush | 3 → 5 / 9 | 0 | 2 |

Flush QPS after/before by trial:

| Corpus | Trial 0 | Trial 1 | Trial 2 |
| --- | ---: | ---: | ---: |
| Uniform 128 | 1.6350 | 1.5513 | 1.6494 |
| Uniform 1536 | 1.3713 | 1.3580 | 1.3301 |
| Real 1536 | 1.3277 | 1.3195 | 1.3118 |

Combined write+flush QPS improves 15.2–38.8%; p95 ratios are .7498–.9040. Real-1536
trials 1 and 2 newly pass both Qdrant gates. Real trial 0 still misses p95 (ratio
1.0583), and all three uniform-1536 combined cells still fail. Individual update
latencies do not establish durability parity and are not used to waive the
combined gate. Warm real-1536 all trial 2 remains a failed transition; its cause
is not assigned without measurement.

The [archive](2026-10-14-payload-writer-reuse.json.gz) contains **833 files,
3,960,874 bytes**, including full sources/diffs, exact tests and parent failure,
the harness failure, build identities, C/Python results, all raw workers and
latencies, byte audits and verified references to parent evidence and plans.
Every embedded hash is verified. Root source and production Python/C binaries
remain unchanged. No fresh Linux, capacity, HTTP, full crash-kill or GPU acceptance
is claimed.

- Python SHA-256: `1157fa40b85087e3fcc6b9c0411864c6b07e5da17ab8c4c4c7e54d23e8ca8a53`.
- C library SHA-256: `1b01cd185dbafbe70b494b2a0b56f4f8f41dab27db5684e44c805ce81af8ba67`.
- Archive SHA-256: `be0b45016d6b213a9b63c28c96af7b9c7285990428cc14b61bb3709347f2e399`.

Next investigate large-buffer CRC instruction dependency cost using zlib's
established three-stream combination, preserving the portable implementation,
streaming registers, protected-page bounds and every persisted checksum byte.
The earlier zlib microbenchmark already proves its large-buffer advantage;
runtime linkage is a separate packaging contract and is not silently added.
