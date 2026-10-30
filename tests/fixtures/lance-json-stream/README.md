# Lance JSON stream oracle

Run `pixi run python scripts/lance_json_stream_reference.py` at the repo root.
Original pinned Lance methods execute prefix-only inference, default Utf8,
whole-batch validation, conversion and the lazy reconstructed/converted streams.
The projection adapter calls the original JSON UDF extractor; Arrow/jsonb/futures
are actual frozen crates. Error carriers preserve inner messages without upstream
transport/location decoration. No DataFusion executor or external sort is claimed.

786 scenarios cover null/empty prefixes, batch/type order, fixed rebuild/update
types, mixed values, nonfinite floats, arrays/objects, paths and delayed errors.
Polled-batch counters show that inference stops at its first useful prefix;
the remainder is consumed lazily by conversion. The fixture also records original
row IDs and row addresses. Native bitmap tests verify ID/value correspondence;
arbitrary Arrow passthrough columns are not a native stream API in this slice.

Native construction/update finishes only after the complete input succeeds.
Partial reference conversion outputs preceding errors remain in the fixture;
the native trainer discards staged keys on errors, as no index may be published.
Source hashes, original method hashes, crates, compiler and lock are recorded
in sources.json. This does not prove planner, spilling or durable lifecycle.
