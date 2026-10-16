# Delta candidate admission before preliminary scoring

When a scanned delta's admitted population fits its candidate breadth, every
admitted ID reaches authoritative reranking. Preliminary graph scores cannot
remove any ID in that case. The retained implementation omits those redundant
scores while preserving source/filter admission, candidate breadth, final score
arithmetic and finite-value validation. It changes neither planner thresholds,
ef selection, graph construction nor durable formats.

Fresh native acceptance remains **FAILED**: warm matched quality 36/36,
strict speed 6/36; mixed matched quality 33/36, strict speed
12/36; combined write+flush 3/9. This is a measured reduction
in work, not completion of M5/M6.

## Evidence and implementation

The [native Qdrant operation counts](2026-10-16-qdrant-native-work.md) show
that Akasha's matched-ef real correlated query performs about 1,621 vector
evaluations versus Qdrant's 872. Required authority reranking accounts for
461 of Akasha's evaluations. The pinned upstream revision remains
`21db2f3ff95d50de3a2b88a741312c056fd1762d`; its unquantized scorer reads current
vector storage directly. Akasha cannot generally reuse graph scores because
graph vectors can differ from current authority and score arithmetic varies
by representation. This optimization instead removes preliminary scoring
only when it provably cannot affect candidate admission.

The scan keeps at most breadth+1 pending slot/ID items. On overflow it scores
that prefix, then streams remaining admitted rows through the existing heap.
If no overflow occurs it returns all admitted IDs for the existing authority
rerank. The private delta helper now returns IDs, because callers discarded
its preliminary scores. A graph-search delta still uses the unchanged graph
algorithm and copies its result IDs. Filter/current-source checks and physical
history scan limits remain in place. The overflow path retains its previous
distance count and heap cutoff, including stable ties.

Prototype A uses the bounded prefix for every scan. Retained prototype B also
uses the existing current-source count for unfiltered scans: when that count
already exceeds breadth, it starts the original heap immediately. Filtered
cardinality is not assumed from the unfiltered count. This internal compile-time
specialization adds no public configuration. A and B have identical results
and actual distance work in the recorded corpus.

Five saved filtered ANN cells omit about 205 preliminary distances per query:
both uniform corpora's correlated/independent filters and real correlated.
Real independent ef=128 still overflows, so its preliminary scoring remains.
Every omitted preliminary score is still represented by an authority rerank;
no graph-score identity or finite-value exemption is assumed.

## Paired measurements and tradeoffs

Each prototype has three alternating baseline/candidate pairs per corpus,
using the accepted bitmap trial-0 databases, frozen ef and identical queries.
Saved workers execute 31 passes over all 67 queries (including warmup query
identities), separately from the formal 64-query acceptance. All 36 paired
cells preserve result digests, score bits and recall. All statistics match
except the accounted reduction in preliminary distances: zero or exactly the
delta candidate count of a scan.

Each prototype also has 18 serial mixed workers cloning the same baseline
databases and deterministic plans. All 5,184 responses preserve IDs, F32 score
bits, recall, oracle and execution decisions; statistics differ only by the
same accounted distance reduction. All 18 reopen checks and 18 Arrow leases
pass. The diagnostic mixed driver captures score bits outside the timed search
interval in both versions. Fresh native acceptance uses the normal driver.
No builds, tests or compression overlap timing.

Retained B medians, after/before (greater QPS and smaller p95 are better):

| Corpus | Filter | Saved QPS / p95 | Mixed QPS / p95 |
| --- | --- | ---: | ---: |
| uniform-128 | all | 0.999 / 0.996 | 0.991 / 1.012 |
| uniform-128 | correlated | 1.035 / 0.998 | 1.026 / 1.086 |
| uniform-128 | independent | 1.029 / 0.997 | 1.021 / 0.957 |
| uniform-128 | selective | 1.008 / 0.985 | 0.963 / 1.031 |
| uniform-1536 | all | 1.000 / 0.999 | 0.993 / 0.976 |
| uniform-1536 | correlated | 1.062 / 0.950 | 1.028 / 1.021 |
| uniform-1536 | independent | 1.073 / 0.935 | 1.055 / 0.971 |
| uniform-1536 | selective | 1.010 / 0.981 | 0.972 / 0.765 |
| real-1536 | all | 0.984 / 1.000 | 1.074 / 0.895 |
| real-1536 | correlated | 1.117 / 0.890 | 1.111 / 0.859 |
| real-1536 | independent | 0.992 / 1.009 | 1.044 / 0.896 |
| real-1536 | selective | 0.999 / 1.011 | 1.030 / 1.021 |


Real correlated QPS improves about 11% in both saved and mixed measurements.
That does not make every cell faster: uniform-128 mixed correlated p95 rises
8.6%; its all/selective QPS medians fall, as do uniform-1536 mixed all/selective
and real saved all/independent/selective. Individual regressions are retained
in the archive. A phase audit groups reduced-score, scored-delta, graph-delta
and exact queries; it does not isolate a common cause for the low-dimensional
tail regression. The extra ID copy on the non-scan delta path is a possible
cost, not an established explanation. B is retained for its proven work
elimination and real filtered gains; these regressions remain open requirements.

Prototype A is superseded, with its complete timings and failures retained:

| Corpus | Filter | Saved QPS / p95 | Mixed QPS / p95 |
| --- | --- | ---: | ---: |
| uniform-128 | all | 0.996 / 1.007 | 1.018 / 0.950 |
| uniform-128 | correlated | 1.042 / 0.960 | 1.025 / 1.082 |
| uniform-128 | independent | 1.044 / 0.944 | 1.029 / 1.073 |
| uniform-128 | selective | 1.015 / 0.968 | 0.951 / 1.168 |
| uniform-1536 | all | 1.004 / 0.991 | 1.020 / 0.946 |
| uniform-1536 | correlated | 1.074 / 0.937 | 1.065 / 0.980 |
| uniform-1536 | independent | 1.075 / 0.933 | 1.056 / 0.997 |
| uniform-1536 | selective | 0.998 / 1.015 | 1.110 / 0.604 |
| real-1536 | all | 0.978 / 1.026 | 0.998 / 1.007 |
| real-1536 | correlated | 1.130 / 0.877 | 1.040 / 1.063 |
| real-1536 | independent | 1.006 / 0.998 | 0.987 / 1.044 |
| real-1536 | selective | 1.003 / 1.005 | 1.009 / 1.034 |


## Correctness and public validation

New tests cover Dot/L2/cosine, zero/under/equal/over-breadth populations,
filtered/unfiltered admission, exact final F32 bits, deliberately divergent
graph/authority values and required nonfinite-authority rejection. A filtered
out invalid row remains excluded. Existing compact/owned/mapped, replacement,
deletion, reinsertion, history bound, tie, invalid query and identity coverage
is retained. Assertions now distinguish zero preliminary work from nonzero
authority scoring. The new work-count tests fail against the parent.

Prototype A passes 116 distinct relevant Mojo cases across 12 files after
correcting stale preliminary-count expectations and an explicitly recorded
test fixture metric. B reruns 45 targeted cases across five files, both
98-fixture source-search paths and its Python build. A's other related evidence
applies to the shared admission algorithm; it is not reported as a fresh full
B suite. Neither source-search fixture count claims performance parity.

Public B validation passes the unchanged fixed quality suite: Dot
.9541666667, L2 .95, cosine .9583333333; construction work growth 3.4405554.
The first Python/distributed run passes 384 tests, skips one and fails three
stale counter assertions. After changing only that test file to assert zero
preliminary work and 95/23 authority candidates, all three pass. Thus 387 unique
cases have passing results; the initial failures and three existing warnings
remain recorded. Rebuilt C client, three rebuilt/running examples and both
quality smokes pass. No new full Mojo, crash, GPU or Linux run is claimed.

Parent source: `7f2fe8e79c3d90149a2cd9c96762a432211882cf`.
Baseline Python SHA-256:
`df71664362253188ef32828dc9d28f315a97eee2a82d76fe0fca43c0396839bb`.
Retained B Python SHA-256:
`ed1c16821d39ebafc29a7ee8d85928322c2b0d968166b7137f8f93e9179c2d3f`.

## Fresh native acceptance

Three fresh serial trials per corpus use N=8192, Dot/F32, K=10, 64 measured
queries and the unchanged symmetric ef grid
10/16/24/32/40/48/64/96/128/256/512/1024. Each engine independently chooses its
smallest recall-passing ef, without consulting timing. Reports verify the
candidate binary and successful workers/reopens. Mixed acceptance interleaves
nine queries with eight-point replacements and flush for 32 blocks, using
frozen warm ef. This is serial foreground interleaving, not concurrent load.
All 5184 query audits, 18 reopen exact checks and 9 retained
Arrow leases pass. Combined write+flush measures each block's summed duration.

Akasha passes all 36 mixed recall cells; Qdrant passes 33/36. Failed matched-quality cells receive no speed comparison and no post-hoc ef retuning. Failures: qdrant real-1536/correlated trial 0: 0.9458333333; qdrant real-1536/correlated trial 1: 0.9458333333; qdrant real-1536/correlated trial 2: 0.9458333333.

Ratios below are Akasha/Qdrant medians. Each strict cell requires recall,
QPS >= Qdrant and p95 <= Qdrant; decisions use unrounded ratios. Separate fresh
graph snapshots are not paired causal comparisons with older acceptance runs.

| Corpus | Filter | Warm QPS / p95 | Pass | Mixed QPS / p95 | Pass |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.512 / 1.900 | 0/3 | 0.814 / 1.098 | 0/3 |
| uniform-128 | correlated | 0.580 / 1.644 | 0/3 | 0.900 / 0.946 | 0/3 |
| uniform-128 | independent | 0.570 / 1.673 | 0/3 | 0.961 / 0.895 | 0/3 |
| uniform-128 | selective | 1.013 / 1.130 | 1/3 | 1.389 / 0.641 | 3/3 |
| uniform-1536 | all | 1.092 / 0.918 | 3/3 | 1.106 / 0.953 | 2/3 |
| uniform-1536 | correlated | 0.838 / 1.110 | 0/3 | 0.772 / 1.408 | 0/3 |
| uniform-1536 | independent | 0.871 / 1.024 | 0/3 | 0.802 / 1.350 | 0/3 |
| uniform-1536 | selective | 0.969 / 0.907 | 0/3 | 0.972 / 1.162 | 1/3 |
| real-1536 | all | 0.979 / 0.973 | 1/3 | 1.317 / 0.608 | 3/3 |
| real-1536 | correlated | 0.549 / 1.570 | 0/3 | N/A (quality failed) | 0/3 |
| real-1536 | independent | 0.814 / 1.154 | 0/3 | 0.965 / 0.885 | 0/3 |
| real-1536 | selective | 0.908 / 1.100 | 1/3 | 1.407 / 0.621 | 3/3 |


Failed speed cells and remaining native Linux, concurrent-client, sustained
nonresident, type, capacity and lifecycle requirements remain open. Existing
concurrency evidence predates this candidate. This resident macOS ARM64 run
does not satisfy those gates. No push authorization is inferred.

## Frozen evidence

[Complete evidence](results/2026-10-16-delta-admission-first.json.gz) contains
619 files (12,247,887 bytes), including both prototypes,
all failed/corrected checks, source/test snapshots, final patch, paired/fresh
reports, work-count audits and drivers. Databases and binaries are identified
rather than embedded. Input database inventory is pinned by the existing
concurrent-current archive, while retained specs/oracles and deterministic plan
metadata permit regeneration. Every embedded file hash verifies. Archive SHA-256:
`1f21e8ed5cb1b67889aacb3c570344472d4f59e28ecc6811b9d01f97ce33ceac`.
