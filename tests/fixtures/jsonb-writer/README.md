# RawJsonb compact/pretty writer source oracle

Regenerate with `pixi run python scripts/jsonb_writer_reference.py`.
`sources.json` pins jsonb 0.5.6 (databend, no arbitrary_precision), serde_json
1.0.151 and its numerical/calendar dependencies. The generator verifies all
seven archives and 231 Rust source files, checks the newly used ethnum/jiff
license files against their archives, and records generator/scaffold/input/
output/lock hashes. Runtime conversion stays in Mojo; Rust is test-only.

The Rust adapter calls the original `RawJsonb::to_string` and
`to_pretty_string`, cross-checking each successful output against direct serde
serialization outside the panic catcher. It never uses `Value::Display` for
JSON expectations. Source-valid binary bodies with panicking calendar/offset
formatting are recorded as `panic: true`; Mojo/Python report errors for them.
Malformed binary is covered by the checked codec boundary, not this oracle's
raw fallback path.

There are 29,003 unique bodies: 28,901 compact/pretty output pairs and 102 source
panics. Inputs reuse the codec's typed/current/legacy values and both text
profiles; add every decimal scale byte, integer/cast bounds and random wide
decimals, Gregorian cycles/BCE/epoch/range edges, timestamps/offset seconds and
clamps, interval signed minima, all ASCII controls plus Unicode, and a unique
unsorted raw-key object. This is differential coverage, not exhaustive type
enumeration. Native tests additionally check depth/node/body limits and maximum
control-character escaping expansion. Public Python tests use every source row
and verify persisted values after WAL/checkpoint reopen.
