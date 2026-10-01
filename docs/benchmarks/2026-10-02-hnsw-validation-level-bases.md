# Rejected prefix-base lookup during HNSW validation

The candidate replaced the dictionary of owned `(slot, level)` groups with one
UInt32 prefix base per node. Consecutive node levels produce the same edge keys;
all structure, capacity, target-level and bidirectional checks stayed in place.
The previously accepted [checked adjacency ranges](2026-10-02-hnsw-validation-ranges.md)
remain in production. The prefix-base candidate was reverted.

Three alternating pairs per corpus each ran eight native complete validations,
with the first pass retained as warmup. Most trial medians improved by 2–4%, but
one uniform 1536D trial slowed by 4% and one real-data trial by 3%. These stage
results did not establish a consistent benefit for the public reopen operation.

| Public cached reopen | Before median ms | Candidate median ms | Pairs |
|---|---:|---:|---:|
| Uniform 128D | 97.191 | 95.554 | 3 |
| Uniform 1536D | 204.962 | 203.646 | 3 |
| Real 1536D, original trials | 215.160 | 219.387 | 3 |
| Real 1536D, all original and follow-up trials | 214.616 | 216.623 | 8 |

The initial real-data regression prompted five additional fixed trials. All
original trials remain included, producing four before/after and four
after/before orders. The real-data paired candidate/before median is **1.01057**,
with full range **0.97233–1.03234**. This is a small noisy regression, not evidence
of a public latency improvement. No further sampling was used to choose a winner.

All 28 public worker processes verify the loaded binary hash. All **896 exact
oracle checks** pass, and **896 ANN result lists** retain identical IDs and
scores. Each pair uses identical closed cache-populated data. Runs are serial
without overlapping builds, tests or compression. OS cache is present; there is
no controlled eviction or memory limit, and no cold/non-resident claim.

Candidate validation passed **109 Mojo tests in 11 files, nine crash tests in
two files, all 339 Python tests**, and the rebuilt C ABI client. Production
sources were then checked byte-for-byte against the saved accepted baseline,
the saved Python binary restored, and C rebuilt and checked. The ten link tests
pass on the restored implementation. The new unequal-node-level regression is
retained: a reverse edge at another level cannot satisfy bidirectional validity.

Validation edge-tape counts and capacity are unchanged. The reported auxiliary
reserved bytes cover only the two edge arrays, excluding metadata lookup storage;
these measurements therefore do not establish total scratch-memory savings.

The [evidence archive](results/2026-10-02-hnsw-validation-level-bases.json.gz)
contains original and follow-up raw trials, scripts, both source versions,
patches, validation output and restoration evidence (479,954 bytes; SHA-256
`26a32554fa42296a695b8fa68d4e37b47100ef7b3450db34f1f7cf673b49a6bd`).
The Qdrant performance and final delivery gates remain open.
