# Q04f / D03c datetime validation

Date: 2026-10-30. Parent `51b1253`; Mojo `1.0.0 (ed45d567)` on macOS ARM64.
Plan: [datetime source port](../plans/2026-10-30-datetime-source-port.md).

## Implemented behavior

Native `DateTimeValue` ports Qdrant DateTimeWrapper's ordered parser attempts:
strict RFC3339, chrono's relaxed form, two offset formats, naive date/time with
seconds or minutes and date-only. The reachable chrono scanner/format branches
are specialized into fixed modes, with source numeric overflow, Unicode
whitespace, optional-fraction and offset rules. Date-only and naive values use
UTC. Signed years and chrono's full calendar range are preserved.

The calendar uses generated original YearFlags / Mdf ordinal tables and
NaiveDate's epoch arithmetic; UTC offset conversion checks the source date
range. No Python datetime, alternate calendar or regex date parser is involved.
The native type keeps source seconds/nanoseconds, including second 59 with
nanoseconds >= 1,000,000,000 for leap seconds. Fractional digits past nine are
discarded. `.timestamp()` returns integer microseconds; `from_timestamp()` uses
the source negative-time Euclidean decomposition and raises on invalid range.
Input datetime strings are bounded to 65,536 UTF-8 bytes.

`datetime` formulas validate constant strings eagerly, including empty queries
and short-circuited operands. `datetime_key` resolves a payload path/default
and parses its string lazily. Existing path flattening, missing/null distinction,
defaults, short circuits, arithmetic and decay behavior are retained. Timestamps
convert from i64 microseconds to F64 seconds before final F32 scoring, as in the
original evaluator. Python is input conversion only; Python/Arrow results come
from native queries. Stored values remain ordinary strings with no format change.

## Original-source oracle and provenance

`scripts/qdrant_datetime_reference.py` compiles Qdrant
`74f3e85b9473c62560006c043e13737ce6b48412`'s original DateTimeWrapper methods,
JSON-path parser, payload retriever and formula scorer with actual **chrono
0.4.45**, pinned by Qdrant Cargo.lock. Chrono revision is
`170338250e836976a211e64728ec956e45e78a39`; crate SHA256 is
`1aa79e62e7697b8e29b513a68abacf485adcd1fe8284a4316c5ae868e6633327`.
Metadata records nine Qdrant files and 19 extracted units, eleven chrono source/
license files, both lockfiles and the compiled scaffold/parser. Those hashes,
the archive and its VCS revision were checked independently. The original
chrono license is retained; Rust is an oracle dependency only.
The license keeps its upstream final blank line; a path-specific Git whitespace
attribute permits that line while preserving the exact source/license hash.

Transport/derive/OrderedFloat/provider/counter/MultiValue types are scaffold
adapters. Datetime parsing/timestamp and score bodies are original. The unused
geographic adapter is not exercised; geographic behavior has its own oracle.
Decay transport uses fixed parameters; prior scalar tests cover the full parser.

The generated Rust whitespace table/lookup is pinned separately. Its source
toolchain is 1.72.0, while the reference executable uses Homebrew rustc 1.92.0.
The extracted lookup matches the reference compiler over **every Unicode scalar**.
The local Unicode source file also matched the upstream file at Rust commit
`5680fa18feaa87f3ff04063800aec256c3d4b4be`; its full-file and unit hashes are pinned.
This is separate from the existing Unicode-17 alphanumeric parser port; the
generator records the two toolchain versions rather than conflating them.

| Fixture group | Original-source outcomes |
| --- | --- |
| Date strings / invalid JSON types | 20,861: 8,075 accepted, 12,786 expected errors |
| Integer microsecond timestamps | 315: 279 roundtrips, 36 out-of-range errors |
| Datetime formulas | 3,624: 1,431 exact F32 scores, 2,193 expected errors |

Coverage includes all year classes across a 400-year cycle, invalid calendar
components, signed/extreme years, source UTC limits, offset formats, relaxed
spacing, Unicode whitespace, missing seconds/timezone, leap seconds, long
fractions, negative timestamps, payload arrays/paths/defaults, lazy errors and
decay. Expected values are generated solely by original Rust implementations.

## Validation

Heavy builds/tests ran serially; logs are under `.build/datetime-validation/`.

| Command (all prefixed with `rtk proxy`) | Observed result |
| --- | --- |
| `python3 scripts/qdrant_datetime_reference.py` | Reference built and fixture groups above generated; all-scalar whitespace check passed |
| `pixi run mojo run -I src tests/mojo/test_datetime.mojo` | 5 passed |
| `pixi run mojo run -I src tests/mojo/test_formula.mojo` | 4 passed |
| `pixi run mojo run -I src tests/mojo/test_formula_payload.mojo` | 3 passed |
| `pixi run mojo run -I src tests/mojo/test_geo_formula.mojo` | 4 passed |
| `pixi run mojo run -I src tests/mojo/test_universal_query.mojo` | 5 passed |
| `pixi run build-python` | Passed |
| `pixi run env PYTHONPATH=python:. pytest tests/python/test_datetime_formula.py tests/python/test_geo_formula.py tests/python/test_formula_query.py tests/python/test_formula_paths.py tests/python/test_formula_payload.py -q --tb=short` | 1,013 passed, 2 existing warnings; 7.73 seconds |
| `pixi run env PYTHONPATH=python:. pytest tests/python -q --tb=short` | **3,172 passed, 1 skipped, 3 existing warnings**; 71.31 seconds |
| `git diff --cached --check` | Passed with the verbatim-license attribute above |

The five native modules contain **21 tests**. The new 35 public cases cover all
source formulas through point writes and Python/Arrow queries; constant and path
validation before candidate execution; real time-decay ordering, filters and
thresholds; payload updates, deletion, WAL-only/checkpoint reopen, nested queries,
retained Arrow output after close and query controls. Native tests retain an old
payload snapshot after writer deletion/close and reject forged invalid values.
The old rejection parameter for supported `datetime` was removed and replaced
with positive/source-driven coverage; no failing source inputs were dropped.

Initial compile failures were missing serde Deserializer in the Rust scaffold,
an inferred fixed Array where the native test required List, an ambiguous Mojo
String length call and explicit ownership transfer on generated Arrays. These
were corrected before the final source/native/binding tests. No runtime source
comparison failure occurred in this slice.

## Remaining scope

This is native datetime parsing and formula integration, not complete D03/Q04.
Datetime range/typed indexes, geographic/nested filters and indexes, full formula
conditions, typed-index retrieval, sampling/feedback, C ABI and REST/gRPC exposure
remain open. Rich Arrow payload columns and all remaining Lance/SQL/transactions/
UI/security/cluster/operations tasks remain in the master ledger.

No durable format, storage/recovery, C ABI or GPU implementation changed, so their
separate suites were not repeated. Native Linux remains deferred. M5/M6 and
recommendation recall failures remain recorded; optimization has not resumed.
