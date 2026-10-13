# Mapped legacy live ownership — 2026-10-14

**Unadopted.** Same-batch strict speed falls **21/36→12/36 mixed** and
**23/36→17/36 warm**. Mixed has eleven pass→fail and two fail→pass cells;
warm has six pass→fail cells. Both phases retain 36/36 quality before and after,
with identical IDs, Float32 score bits, traversal statistics and execution choices.
Write plus flush remains 3/9. Production engine `6d01819` and its binaries are
unchanged; M5/M6 remain unfinished.

The isolated kernel-inline follow-up maps and validates each legacy checkpoint
before committing its manifest, then replaces only current dense owners while
preserving slots, accepted sequences, sparse fields and payloads. A shared
heap-stable MemTable gives foreground and background compaction the same live
authority. Compaction validates its mapped output before commit and preserves
updates newer than its capture. Retired rows and detached read runs remain owned
until the caller leaves the writer lock; snapshots retain their exact old files.
Public APIs and durable formats are unchanged. Typed PointStore live compaction
rebasing is still incomplete and is not certified by this legacy implementation.

The first flush-only candidate failed existing reclamation: its live rows retained
retired files. The compaction follow-up fixes that behavior. Its live reclamation
fixture now calls the live wrapper and releases the returned owners outside the
writer lock, retaining the same file-existence assertions; this is an adapted test,
not a claim that the original disk-only fixture passed unchanged. Nine private
MemTable field uses in source/tests were adjusted for the shared Arc. A failed
List-subscript move compilation is retained; the final code uses established
immutable field-owner cloning.

The new output-fault test covers corrupted bytes, a mismatched expected checksum
and a missing output. Each failure preserves manifest bytes and current owners,
releases pins and the source lock, removes the rejected output, and permits a
successful retry and reopen. The same corruption case fails as expected on the
frozen parent, which did not inspect persisted output at this boundary.

Current-source validation passes **151 distinct Mojo cases, 23 crash cases,
359 Python tests and C ABI**. Selected Mojo coverage includes actual Metal,
Arrow/typed exports, failure/retry, snapshot and file lifetime, background
publication, batch/named collections and HNSW/generation delta. Source hashes
match every counted run and the built binaries. Earlier compiler failures,
stale-source runs and the flush-only regression are preserved but not counted.
This is not a full CPU, Linux or capacity certification.

Candidate directory: `.build/m5-resume/mapped-live-compaction`.
Python binary SHA-256:
`f87a62ddfab701d85838aea963a45ee3e758daad9c0f9cb90b0e4e498b724cb9`.
C binary SHA-256:
`3381452238db8b81cd80dcef89cd1315199d5f6df432f2fb509e76983aaa3b2a`.

Each performance phase uses 27 serial workers, with three rotating
production/candidate/Qdrant triples per corpus. Workloads, oracles, filters, ef,
timing and mixed plans are unchanged. Every cell requires Recall@10 ≥ .95,
QPS ≥ Qdrant and p95 ≤ Qdrant; no exclusions or offsets are applied. Mixed's
exit 1 records its failed strict gate; all workers succeeded. Warm's driver
completed successfully but its per-cell results still fail acceptance.

Warm full-exact QPS after/before is .783/.788/.798 for uniform-128 and
.881/.925/.926 for uniform-1536. These are same-batch comparisons only.
Mixed correlated/independent uniform-128 QPS is .202–.418 of production.
The candidate resets every read run at each flush, so the following capture
rebuilds the entire indexed base. This code path is a concrete next diagnostic
target; the current benchmark alone does not isolate its contribution.

Next, retain immutable read indexes while publishing only changed dense owners
at flush, with explicit tests for snapshots, sealed heads and owner lifetime.
Continue from a fresh isolated copy; do not mutate these frozen sources or use
earlier owner capacity results to certify a new binary. Existing warm regressions,
typed live compaction and sustained nonresident/native Linux gates remain open.

[Complete sources, tests, raw trials and per-cell performance summary](2026-10-14-mapped-live-compaction.json.gz)
contain 8,373 files, 33,053,701 compressed bytes, SHA-256
`5e45d5cdceb7995e3cb173f2898ac2b5610c017f4c732b153563c1e7ace59d42`.
Archive integrity and all embedded hashes were verified. It includes both failed
flush-only and complete live-compaction candidates. Binaries and databases are
excluded and identified by hashes. `performance-summary.json` lists every
transition and all failing cells; raw samples remain in the phase reports.
