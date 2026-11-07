# Lance JSON matcher audit

Run `pixi run python scripts/lance_json_matcher_reference.py` at the repo root.
The pinned original JSON reference matcher, JSONPath extractor, typed getters,
index inference and batch converter execute against real Arrow, DataFusion
ScalarValue and jsonb crates. Function-name/argument transport and unadorned error
carriers replace framework plumbing; this is not a DataFusion SQL planner run.

1,344 scenarios compare source recognition, actual indexed values and actual UDF
results, including literal keys versus JSONPath, numeric keys/array indices,
string quoting, strict learned types versus getter coercion, missing/null values,
objects/arrays, nonfinite floats, signed zero, Int64 maximum and Unicode strings.
All 144 Decimal/extension scalars from the pinned JSONB codec fixture are wrapped
in an object by original jsonb and checked against all six functions. Extensions
can train as Utf8 while the string getter errors; native training therefore
retains whether all indexed nonnull Utf8 values originated as actual strings.
Original consumer/converter panics from extreme Decimal/date formatting are
captured without changing their implementations; native tests require bounded
errors for them and exact messages for ordinary source errors.
Recognition alone can accept non-equivalent values. Native execution therefore
requires a separate proven-equivalent reference guard and retains every rejected
predicate for ordinary evaluation. Matching the source recognition helper does
not authorize replacing a predicate with an index result.

Sargable leaf null/prefix rules and bitmap parser setup were inspected, not
executed in this oracle. Their source/method hashes are distinguished in
sources.json. Whole-expression planning, literal coercion, snapshot selection,
residual execution and durable/public integration remain separate work.
