# Publish dense compaction owners without whole-row clones — 2026-10-14

**Unadopted.** In this candidate's own fixed batch, mixed speed is
**29/36→26/36**, with four pass→fail and one fail→pass cells. Warm speed is
**20/36→14/36**, with six pass→fail cells. Both phases retain 36/36 quality;
all IDs, Float32 score bits, traversal statistics and execution decisions match.
Write plus flush remains 3/9. These totals must not be subtracted from previous
batches to claim improvement. Production engine `6d01819` is unchanged; M5/M6
remain unfinished.

The isolated candidate starts from the
[unlocked preparation implementation](2026-10-14-mapped-compaction-prepare.md).
Two engine files change. A concrete DenseOwnerReplacement list holds the point
slot, dense-field ordinal, new immutable PointField and previous PointField.
Current ID/version/tombstone/shape checks precede manifest commit. Publication
replaces only the existing default dense field and retains previous numeric
owners until outside writer. It no longer clones complete rows or their vector
descriptor lists during compaction staging/exchange. The obsolete whole-row
exchange path is removed. Flush retains its existing row preparation for read
runs, sharing the same validation helper. Public APIs and formats are unchanged.

The new sparse-only control passes on both parent and candidate. After output
preparation, a sparse update advances collection sequence without changing the
legacy dense row sequence. Compaction preserves that new sparse owner, payload
address, document version and slot. Old snapshot/row values remain readable,
and their last release permits the retired source file to disappear. A later
flush/reopen retains the new sparse result. This is a preserved-behavior
optimization, not a claim of a newly fixed logical defect.

Current-source validation passes **79 selected Mojo cases, 23 crash cases,
359 Python tests and C ABI**. It covers MemTable invariants, preparation/output
failure, retry, cancellation/conflict, background publication, old-owner lifetime,
outside-lock reclamation, close, backup, legacy/named collections and durable
publication order. Every counted source snapshot matches the rebuilt binaries;
the child compiler wrapper targets this candidate. No new full CPU, Metal,
Linux or capacity gate is claimed. Typed live compaction remains incomplete.

Candidate: `.build/m5-resume/mapped-compaction-fields`.
Python binary SHA-256:
`e2083f5021f588c7e719fd819f516eb21e9538f161f146db7b14103903724a13`.
C binary SHA-256:
`08bf32c80e92514741f512c391deddc5503cb9933492dbb6fc7abc532153e28a`.

Each performance phase includes all 27 serial workers, with three rotating
production/candidate/Qdrant triples per unchanged corpus. Plans, oracle, filters,
ef and timing are fixed. Every cell still requires Recall@10 ≥ .95,
QPS ≥ Qdrant and p95 ≤ Qdrant. Mixed exit 1 is its failed strict gate;
all workers succeed. Warm driver completion does not certify its failed gate.
Full-exact warm QPS after/before is .803/.772/.808 for uniform-128 and
.983/.958/.991 for uniform-1536. All failures and slow samples are retained.

| Phase | Transition | Corpus | Trial | Mode | QPS after/before | p95 after/before |
|---|---|---|---:|---|---:|---:|
| mixed | fail→pass | uniform-128 | 0 | selective | .894 | .438 |
| mixed | pass→fail | uniform-1536 | 1 | selective | .695 | 1.598 |
| mixed | pass→fail | uniform-1536 | 2 | selective | .861 | 1.310 |
| mixed | pass→fail | real-1536 | 2 | all | .946 | 1.232 |
| mixed | pass→fail | real-1536 | 2 | correlated | .960 | 1.146 |
| warm | pass→fail | uniform-128 | 0 | independent | .733 | 1.443 |
| warm | pass→fail | uniform-128 | 0 | selective | .859 | 1.049 |
| warm | pass→fail | uniform-128 | 1 | selective | .804 | 1.407 |
| warm | pass→fail | uniform-1536 | 1 | selective | .876 | 1.225 |
| warm | pass→fail | real-1536 | 1 | selective | .847 | 1.228 |
| warm | pass→fail | real-1536 | 2 | selective | .844 | 1.375 |

This freezes the legacy live-ownership branch as a validated implementation
base, not an adopted engine. The remaining typed PointStore authority must be
shared with live compaction without losing newer writes or releasing file owners
under writer. Complete that layer before certifying new capacity/nonresident
results. Warm mapped-read regressions remain independently unresolved; do not
repeat rejected reader variants unchanged or waive any strict cell requirement.

[Complete sources, controls, validation and raw matrices](2026-10-14-mapped-compaction-fields.json.gz)
contain 4,282 files, 25,775,210 compressed bytes, SHA-256
`23bba150844b14c50c39cca968720f915708ad4cd61bd7234a3036e2097a4b0a`.
Archive integrity and every embedded hash were verified. Binaries and copied
databases are excluded and identified by hashes. The per-cell summary includes
every transition and all failed cells in addition to the raw samples.
