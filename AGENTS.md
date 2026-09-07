# AkashaDB Agent Instructions

## Repository context

AkashaDB is an experimental embedded document and vector database kernel. The core engine is written in Mojo, with Python bindings and services around it.

- `src/akasha/`: database kernel, query, index, compute, document, and storage code.
- `src/bindings/` and `python/akashadb/`: Mojo/Python boundary and Python package.
- `tests/`: Mojo, Python, crash-recovery, distributed, integration, and GPU tests.
- `formats/` and `docs/`: durable-format specifications, ADRs, operations, and plans.
- `reference/`: local reference implementations from established database and vector-search projects.

## Engineering decisions

- Before designing a non-trivial solution, inspect the current implementation, tests, documented contracts, existing dependencies, and relevant material under `reference/`. Consult current upstream documentation when local evidence is insufficient. Adopt proven patterns only when they fit AkashaDB's constraints; stop researching once there is enough evidence to choose and verify a design.
- Choose the simplest design that fully satisfies the current requirements and established invariants. Deliver the smallest end-to-end change that works, then add capabilities in independently working layers. Avoid speculative abstractions, configuration, and indirection.
- Keep components modular, responsibilities explicit, and durable state transitions easy to reason about. Do not introduce a knowingly temporary architecture when the actual required design is already clear.
- Prefer capabilities already provided by the project and its dependencies. Before adding a package or reimplementing common functionality, verify the existing APIs, documentation, and types. Use an established, maintained library only when it reduces total complexity or improves reliability.
- Default internal implementation work to forward-only: remove obsolete internal paths instead of adding compatibility layers or fallbacks. Existing public APIs, documented durable formats, fixtures, and compatibility tests are requirements; preserve them unless the task explicitly changes that contract, and update the contract and tests together when it does.

## Implementation workflow

- Derive success criteria from the user request, nearby tests, and documented contracts before editing. Ask only when a missing decision would materially change behavior, compatibility, or risk.
- Reuse existing patterns and helpers before creating new ones. Keep the change scoped; do not refactor unrelated code unless it is required to implement or validate the requested behavior safely.
- Add or update the narrowest tests that demonstrate changed behavior, including relevant failure and recovery paths. For persistence changes, test corruption, torn writes, restart behavior, and format compatibility when applicable.
- Run the smallest relevant validation first, then broaden validation in proportion to the change. If a required check cannot run, report the command, reason, and best available substitute.

## Mojo development

- Before writing or modifying `.mojo` files, load and follow the `mojo-syntax` skill instead of relying on pretrained Mojo knowledge.
- When Mojo syntax, standard-library APIs, ownership rules, or compiler behavior are uncertain, consult the live official documentation starting at <https://mojolang.org/llms.txt>.
- Check the project-installed version with `pixi run mojo --version` and prefer documentation that matches it. Do not blindly apply syntax from a newer Mojo release.
- Treat the project compiler as the final authority: generated Mojo must compile before the task is considered complete.

## Validation commands

- Targeted Mojo test: `pixi run mojo run -I src tests/mojo/<test_file>.mojo`
- All Mojo tests: `pixi run test-mojo`
- Python binding tests: `pixi run test-python`
- Standard CPU suite: `pixi run test`
- Build artifacts: `pixi run build`
- Crash-recovery suite: `pixi run test-crash`
- GPU tests: `pixi run test-gpu` only when GPU behavior changed and suitable hardware/tooling is available; this is an actual-device gate, not a portability test.
