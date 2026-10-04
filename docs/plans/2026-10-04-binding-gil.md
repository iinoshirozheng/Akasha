# Pin the Python collection while releasing the GIL for ANN

M5/M6 are unfinished. The final isolated candidate, **not adopted**, is under
`.build/2026-10-04-binding-gil-v2`; the first candidate and all its results remain
in `.build/2026-10-04-binding-gil`. Production stays at `cc15f37` / Python binary
`609aeb2b…`. The earlier HTTP measurement plan excluded GIL work from that
experiment; this follow-up tests a newly measured binding cost, with the user's
original authorization and unchanged service/resource/performance gates.

## Evidence and hypothesis

Current production HTTP phase instrumentation completed all three fixed corpora,
four filters and 1/2/4 clients: 4,020 valid responses, including 2,304 timed audits.
Each request has one worker call. Schema validation and response encoding are
small; concurrent worker waits are substantial. Those wall intervals alone do
not prove GIL causation and are not Qdrant performance samples.

A separate unchanged-binary observation records CPython `c_call`/`c_return`
boundaries for all/independent queries: 402 calls, all valid results. A second
Python thread records 5,790 heartbeat timestamps, with none inside the native
call interiors (50 µs margins). Source has no GIL-release scope. This supports
testing whether native search prevents the HTTP event loop from making progress;
it does not predict an end-to-end speedup.

Pinned Mojo 1.0.0 supplies `std.python._cpython.GILReleased`, implemented with
CPython SaveThread/RestoreThread, and existing `ArcPointer`. Official source:
<https://raw.githubusercontent.com/modular/modular/mojo/v1.0.0/mojo/stdlib/std/python/_cpython.mojo>.
The compiler remains the authority. No new package or custom threading primitive.

## Candidate boundary

1. `BoundCollection.inner` becomes `Optional[ArcPointer[PersistentCollection]]`.
   Constructors allocate one owner; existing methods dereference it. No durable
   format, Python API, C ABI or engine source changes.
2. `search_approx` and `search_dense_where` copy the owner under the GIL **before
   any Python input conversion**, because conversion can re-enter `close()`.
   The exact where branch also uses that owner. Only approximate calls release
   the GIL, after converting inputs into owned Mojo values.
   Result conversion to Python objects happens after reacquisition.
3. Keep the owner alive until after the scope. `close` may clear the Python
   handle while native work is active; it cannot free the pinned collection.
   Calls racing close may finish or report the documented closed error. The
   native collection writer lock still serializes ANN, writes and close.
4. No Python object access/destruction in the released scope, extra search
   workers, candidate-budget changes, request/response shortcuts or validation
   removal. Other public binding methods keep their current GIL behavior.

## Verification and decision

The original observation is the before evidence. New narrow tests cover all
three metrics, filtered/unfiltered and list/column results, errors followed by
valid calls, parallel result identity, and close/search races plus reopen. Race
tests do not claim a scheduler-guaranteed interleaving. They run against the saved
before and candidate packages with path/hash guards and `-o pythonpath=`.

Build only copied `after-src/bindings/python_module.mojo`. After narrow tests,
run the full saved-package Python suite with the existing Metal wrapper and
candidate source routing for child compiles. Core engine/C sources are unchanged;
do not claim new full Mojo/crash/C ABI/GPU gates from these tests.

Then repeat the diagnostic heartbeat/HTTP phases on the candidate and compare
all IDs/score bits. Run the original uninstrumented before/after/Qdrant HTTP
matrix and affected binding gates, keeping all samples and failures. No arbitrary
A/B no-regression condition replaces the user's per-cell Qdrant requirement.
Production promotion requires a justified improvement and correct lifecycle;
partial gains cannot mark M5/M6 complete. Linux/nonresident remains unverified.

## First candidate and discovered re-entry defect

V1 passed 22 targeted and 388 full Python tests, and the heartbeat observer found
Python progress inside native calls. Its HTTP run is **invalid as the intended
formal gate**: the launcher replaced Pixi's PATH without its Python bin, loading
miniconda Python 3.10 and FastAPI 0.122.0 instead of project Python 3.11 / FastAPI
0.141.1. All measurements remain. Their provisional comparison was 18→27/108,
with one pass→fail and 47 A/B timing regressions; those are not accepted current
runtime performance results. Qdrant's
uniform-128/trial-1/all Recall@10 was .9484375 at each client count; all three
failed quality comparisons remain, so matched quality is 105/108, not 108/108.
All 36,180 request audits are valid and 12,060 paired IDs/F32 bits agree.
The first assessment incorrectly asserted every quality cell must pass; it was
corrected to preserve and report the completed low-recall measurements.

Review then identified a callback gap before the owner copy. A custom vector
iterator calling `collection.close()` aborts both production and V1 at empty
`Optional.value()` (exit 133). V2 pins before conversion, including exact where.
Twelve subprocess regressions cover close from `__len__`/`__iter__`, approximate,
filtered approximate/exact, and list/column output: all twelve fail on production;
V2 passes all 34 targeted and 388 full Python tests. Both test launchers explicitly
include the Pixi bin; their evidence remains valid. V2's first heartbeat and failed
HTTP profile inherited the bad measurement launcher; they remain separate. The
corrected pipeline uses an absolute project Python executable, includes its bin
for children, checks interpreter and package versions, and writes fresh diagnostic
outputs. V2's fixed gates are recorded separately; V1's measurements do not count
as V2 performance evidence.

## Final decision

The corrected V2 pipeline completed all stages with the intended runtime. Warm
strict parity is 20→22/36, mixed queries 25→25/36 and durable write+flush 4→4/9;
warm/mixed matched recall is 36/36 for each version. HTTP is 24→28/108, matched
quality 105/108 because three Qdrant comparison cells fall below the fixed recall
threshold. There are three binding and six HTTP performance pass→fail cells, and
64/108 HTTP A/B timing regressions. All are retained. No cross-cell gain offsets
a failed gate. V2 improves thread progress but has not established a sufficient
end-to-end performance benefit for promotion; source/binary stay unchanged.

The conversion-close abort is independently reproducible on production. Address
that safety defect separately by rechecking the handle after Python conversions,
immediately before native access in the affected search methods. This needs no
GIL change or shared heap owner; retain the twelve failing subprocess regressions
and verify the minimal fix against them and the existing Python contracts.
