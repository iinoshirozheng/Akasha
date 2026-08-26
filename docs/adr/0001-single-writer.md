# ADR 0001: Start with a single writer

## Status

Accepted and enforced in Phase 5.

## Decision

Serialize writes through one engine-owned writer while allowing concurrent snapshot reads. This keeps WAL ordering and recovery testable before introducing multi-writer coordination.

Collection open acquires a non-blocking operating-system advisory lock on a
stable `collection.lock` file. The lock is held for the owner lifetime and is
released by `close()` or RAII. This prevents two processes or two live handles
from independently allocating the same next WAL sequence.
