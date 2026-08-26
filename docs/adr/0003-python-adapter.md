# ADR 0003: Keep Python as an adapter

## Status

Accepted and implemented in Phase 8.

## Decision

Expose a narrow batch-oriented Mojo binding. Python and FastAPI may translate requests, but query planning, indexing, and persistence remain in the Mojo kernel.

The implementation uses a compiled `PythonModuleBuilder` extension whose bound
type owns `PersistentCollection`. Python dataclasses, HTTP schemas, and copying
Arrow-compatible columns translate values only; all mutation, recovery,
filtering, dense/sparse scoring, planning, and fusion calls cross into Mojo.
