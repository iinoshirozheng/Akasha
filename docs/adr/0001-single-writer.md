# ADR 0001: Start with a single writer

## Status

Accepted for the first milestone.

## Decision

Serialize writes through one engine-owned writer while allowing concurrent snapshot reads. This keeps WAL ordering and recovery testable before introducing multi-writer coordination.
