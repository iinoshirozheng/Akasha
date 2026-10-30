# Original Qdrant / chrono datetime reference

Regenerate with `rtk proxy python3 scripts/qdrant_datetime_reference.py`.
Requires the pinned local Qdrant checkout, Cargo versions in `Cargo.lock`, and
the Rust source whitespace unit matching the generator's fixed SHA256. Builds
are offline and locked. The generator recreates its base rich-formula scaffold;
it does not require a pre-existing `.build` scaffold.

Qdrant revision: `74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).
Chrono 0.4.45: `170338250e836976a211e64728ec956e45e78a39` (MIT OR Apache-2.0).
The dependency archive checksum matches Qdrant Cargo.lock, and extracted files
are checked against that archive. License notices are retained under
`docs/upstream/licenses/`; provenance is in `datetime.json` and the port registry.

The oracle compiles 19 extracted Qdrant units plus the original JSON-path parser,
with its actual chrono dependency. Scaffolding adapts derive/transport, date
wrapper declaration, OrderedFloat, payload provider, counters and MultiValue.
The original date parse/timestamp and numeric evaluator bodies are unchanged.
Unused geographic adapters are outside this oracle; decay transport uses fixed
parameters, with general decay parsing covered by the earlier scalar oracle.

- 20,861 date/type inputs: 8,075 accepted, 12,786 errors.
- 315 microsecond timestamps: 279 roundtrips, 36 out-of-range errors.
- 3,624 formulas: 1,431 F32 scores, 2,193 expected errors.

Coverage includes all year classes across a 400-year cycle, signed/extreme years,
invalid months/days, leap seconds, fractions beyond nine digits, negative epoch
values, timezone/UTC range boundaries, relaxed/naive/date-only grammar, Unicode
whitespace, payload paths/arrays/defaults, lazy errors and decay expressions.
The generator converts the actual literal chrono calendar/Rust whitespace tables
to Mojo. Rust whitespace source (toolchain 1.72.0) matches the active reference
compiler (1.92.0) over all Unicode scalar values; this is separate from the
earlier Unicode-17 alphanumeric source port.

No Python datetime/calendar algorithm generates expected values. This does not
verify typed datetime indexes, range filters, C ABI or full REST/gRPC protocols.
