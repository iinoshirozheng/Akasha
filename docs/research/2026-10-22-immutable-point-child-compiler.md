# Revalidate child Mojo compilation against the retained candidate

The retained deferred-ID package now passes a fresh **379-test Python suite**
with every project child compilation explicitly routed to its source. The
previous native import checks established which Python extension loaded; they
did **not** establish that subprocess Mojo compilers used the same candidate.
The five Python modules that invoke Mojo pass repository `src` paths, and the
prior retained validation driver did not rewrite them.

## Correction and verification

An isolated compiler wrapper follows the established
[production ownership validation](2026-10-14-production-result-ownership.md)
pattern. It rewrites project source paths to retained deferred-ID, records
original/effective arguments, working directory, compiler and source-manifest
identity, then executes the project-installed compiler. It does not add or
change target flags, suppress errors, or change the tests.

The successful suite has **15 child compiler invocations**: **14 use candidate
source**, and one generic-target probe imports only stdlib with no project
include. They cover Arrow C layout, mapped-file C ABI and generic ARM64 behavior,
unsupported ABI rejection, mapped borrow/constructor compile contracts, CRC
target instructions and compaction under a low descriptor limit. All 23 Python
test modules remain byte-identical to the retained evidence archive.

Four main/spawned Python processes independently verify the retained native
SHA-256 `64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`.
All **132 candidate source files**, package sources and native bytes remain
unchanged before/after validation. The compiler is **Mojo 1.0.0 (ed45d567)**.

A separate relative-include proof runs the existing
`test_mapped_numeric_values.mojo` fixture. Its private `mapped_numeric` module
exists only in the candidate. Direct compilation against production `src`
fails specifically because that module is missing; `-I src` through the wrapper
resolves to the candidate and all **six existing owner cases pass**. The audit
checks the exact effective command. These are repeated existing cases, not six
new coverage cases. This adds one routed invocation beyond the suite's 15.

The initial launch incorrectly used direct Python outside Pixi activation.
All 14 compiler-dependent tests failed because the compiler could not find
`std`; 365 other tests passed. That complete failure log is preserved. Running
the same driver through `rtk proxy pixi run python` fixes the environment and
the full suite passes **379/379**, with one pre-existing FastAPI deprecation
warning. Counts are not added across failed/successful runs.

## Scope and evidence

This closes the candidate-source ambiguity for the existing Python suite and
proves relative/absolute project include routing. It does not adopt the
candidate, close native Linux/capacity/performance gates, or change the latest
strict mixed **21/36** result. Production stays `a6822c3`.

Reproduce using a fresh evidence directory and the archived scripts:
`rtk proxy pixi run python <root>/validate.py`, followed by
`rtk proxy pixi run python <root>/check_relative.py`. The fixed retained source
archive/native identities must be present. All existing source/correctness
requirements remain in force.

The [verified archive](2026-10-22-immutable-point-child-compiler.json.gz)
contains **64 text artifacts, 103,004 bytes**, SHA-256
`7af7ac40dded50da83b4384f9f1baa8657476e06af921b674c9e3b6660729f8f`.
It preserves the wrapper/drivers, exact test/dependency sources, compiler
invocations, import identities, complete success/failure logs and prior wrapper
reference. The full 132-file candidate source chain is verified against its
existing archive. Archive-only replay independently reproduces all routing,
identity and outcome counts; all 64 artifact hashes verify.
