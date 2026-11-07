# JSON bitmap disk cache: first storage layer

Status: this first end-to-end storage layer is implemented and verified;
[evidence](../research/2026-11-08-json-bitmap-disk-cache-validation.md).
Subsequent lazy-posting and spill layers listed below remain open.

Persist the current bounded bitmap target through the existing non-authoritative
AKIC cache envelope. Keep manifest v6 as the catalog authority. Use a distinct
cache kind and versioned payload with exact column/path/learned type, string-getter
provenance, ordered scalar keys and sorted UInt64 posting lists (nulls separate).
This is Akasha storage, not Lance file compatibility or portable Roaring encoding.

Reuse atomic temporary-write/fsync/rename/directory-fsync publication. Creation
and explicit rebuild publish under collection writer exclusion; snapshots only
read. Cache identity includes dimension, accepted sequence and a checksum of the
definition plus ID-ordered source payloads. Exact definition checks protect
filename collisions. Changing data causes a miss; corrupt/missing caches rebuild
from authority. Cancellation/deadlines must not become swallowed build failures.

Load on first artifact demand, then share through the existing root registry.
Keep fixed learned type across misses/rebuilds. Test codec corruption/truncation,
all scalar types and bit preservation, real reopen hit, source-change miss,
corrupt-cache recovery, snapshot ownership and query/Arrow regressions.

Subsequent layers remain explicit: per-posting lazy mapped access with bounded
cache, source-aligned shard merge, external sort/spill. This layer does not claim
those capabilities or tune performance.
