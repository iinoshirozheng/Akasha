# ADR 0002: Persist immutable segments

## Status

Accepted for the first milestone.

## Decision

Flush mutable state into checksummed immutable segments and publish them through an atomic manifest. Updates and deletes create newer versions and tombstones until compaction.
