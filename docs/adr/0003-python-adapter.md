# ADR 0003: Keep Python as an adapter

## Status

Accepted for the first milestone.

## Decision

Expose a narrow batch-oriented Mojo binding. Python and FastAPI may translate requests, but query planning, indexing, and persistence remain in the Mojo kernel.
