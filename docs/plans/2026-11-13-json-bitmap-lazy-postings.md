# JSON bitmap lazy postings

Implement the next disk-index layer without changing cache payload v1 or public query semantics.

Reference: pinned Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`,
`rust/lance-index/src/scalar/bitmap.rs`, `load` and `load_bitmap`. Keep a resident
key directory, load matching postings on demand, and avoid cache access for
missing keys. Akasha retains its own encoding, nullable algebra and atomic publisher.

- Reuse the current decoder with borrowed and mapped readers; validate headers,
  ordered keys, coverage and all row ordinals before publishing the directory.
- Retain the mapped artifact owner and posting offset/count pairs. Decode no
  Roaring sets during mapped open; use a temporary row-coverage bitset instead.
- Share a synchronized LRU per mapped index, bounded by 128 entries and 8 MiB
  logical retained bytes. Oversized entries bypass retention. Return owned sets
  so eviction cannot invalidate active queries. No new package or public knobs.
- Route search, nulls, encoding, update and remap through the same posting accessors.
- Verify all scalar types, eviction by bytes and count, concurrent readers,
  cancellation, valid-CRC corruption, truncation, replace/unlink lifetime,
  collection reopen/fallback and Python/Arrow integration.

Full CRC and ordinal validation still scan the file at open. Source fingerprints
still scan current documents. This is lazy materialization, not bounded startup
I/O or a peak-RSS guarantee. External sort/spill and disk shard merge remain separate.

Completed and validated: [30 native / 205 Python tests](../research/2026-11-13-json-bitmap-lazy-postings-validation.md).
